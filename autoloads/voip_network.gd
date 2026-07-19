extends Node
## VOIP transport layer: the only VOIP piece that knows about multiplayer.
##
## Owns the local VoipMicrophone and relays its packets client -> server -> peers
## over the same server-authoritative RPC model as the rest of the template.
## VoipSpeaker nodes self-register per peer (see voip_speaker.gd's
## _resolve_peer_id) and receive every packet addressed to their sender.
##
## Channel choices: stream header/footer packets travel reliably (a lost header
## stalls an entire talk burst), Opus frames travel unreliably (a lost frame is
## concealed by the speaker's FEC).
##
## Swap this file out (or its RPCs) to move the whole VOIP stack onto a
## different transport — microphone and speakers are transport-agnostic.

## Local mic state, re-exposed for UI (mute indicators, level meters).
signal mute_changed(muted: bool)
signal transmitting_changed(transmitting: bool)

## Local listening preferences changed (see set_peer_muted / set_peer_volume_db).
signal peer_muted_changed(peer_id: int, muted: bool)
signal peer_volume_changed(peer_id: int, volume_db: float)

## Path to the design-time default VoipConfig, editable via Project Settings
## instead of editing this autoload — a game can point this at its own resource
## without touching code. Self-registers into ProjectSettings on first run.
const DEFAULT_CONFIG_SETTING := "voip/default_config_path"
const DEFAULT_CONFIG_PATH := "res://voip/default_voip_config.tres"

## The live, runtime config every VoipMicrophone/VoipSpeaker in this project
## shares — never the design-time resource itself. Settings changes mutate this
## instance directly (see SettingsManager); the .tres on disk is only ever read
## once, at startup, via duplicate() — never written back to.
var config: VoipConfig
var microphone: VoipMicrophone

## Route your own voice back to your own speaker through the full network path.
## Lets one instance test the pipeline end-to-end, at the cost of hearing
## yourself with the full buffering latency. Testing only.
var hear_self: bool = false

## Server-only. Set by the game to gate who receives whose voice (e.g. proximity
## culling). Signature: (listener_id: int, sender_id: int) -> bool. Left unset
## (the default, an invalid Callable), everyone hears everyone — current behaviour.
## VoipNetwork never inspects positions or any other world state itself; the game
## supplies the answer so this file stays ignorant of what a "distance" even is.
var voice_relevance: Callable

var _speakers: Dictionary = {}  # peer_id -> VoipSpeaker

## Local-only listening preferences, keyed by remote peer_id. Never sent over the
## network — muting/adjusting someone is entirely a local decision, so this needs
## no RPCs. Applied at _deliver_to_speaker(), the single point every incoming
## packet (from any transport path) passes through before reaching a speaker.
var _peer_muted: Dictionary = {}      # peer_id -> true (absence = not muted)
var _peer_volume_db: Dictionary = {}  # peer_id -> float (absence = 0.0 offset)

# Server only: sender_id -> {"header": Dictionary, "last_frame": int, "heard_by": {peer_id: true}}.
# "heard_by" tracks who has already received this burst's header (naturally, or via a
# relevance-transition replay — see _ensure_header_replayed) so mid-stream joiners/
# proximity-entrants and repeat-frame recipients aren't confused for each other.
var _active_streams: Dictionary = {}

func _ready():
	config = _load_default_config().duplicate()
	microphone = VoipMicrophone.new()
	microphone.name = "Microphone"
	microphone.config = config
	microphone.header_ready.connect(_on_mic_control_packet)
	microphone.footer_ready.connect(_on_mic_control_packet)
	microphone.frame_ready.connect(_on_mic_frame_packet)
	microphone.mute_changed.connect(_on_mute_changed)
	microphone.transmitting_changed.connect(transmitting_changed.emit)
	add_child(microphone)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	# Optional, like the EventBus peek in _on_mute_changed: a project without
	# EventBus (or without the reconnect-identity feature) still gets a fully
	# working VoipNetwork, just without preferences surviving a peer_id change.
	var event_bus := get_node_or_null("/root/EventBus")
	if event_bus and event_bus.has_signal("peer_identity_migrated"):
		event_bus.peer_identity_migrated.connect(_on_peer_identity_migrated)

func _load_default_config() -> VoipConfig:
	# Registers the setting in memory so it works this run regardless; doesn't call
	# ProjectSettings.save() (that would rewrite project.godot as a side effect of
	# just running the game). To make the setting show up in the editor's Project
	# Settings UI permanently, open it there once and save — purely a convenience,
	# not required for this to function correctly either way.
	if not ProjectSettings.has_setting(DEFAULT_CONFIG_SETTING):
		ProjectSettings.set_setting(DEFAULT_CONFIG_SETTING, DEFAULT_CONFIG_PATH)
		ProjectSettings.set_initial_value(DEFAULT_CONFIG_SETTING, DEFAULT_CONFIG_PATH)
	var path: String = ProjectSettings.get_setting(DEFAULT_CONFIG_SETTING, DEFAULT_CONFIG_PATH)
	var res := load(path) if ResourceLoader.exists(path) else null
	if res is VoipConfig:
		return res
	push_warning("VoipNetwork: %s (%s) is not a VoipConfig — using a blank default instead." % [DEFAULT_CONFIG_SETTING, path])
	return VoipConfig.new()

func _process(_delta):
	# Capture only while actually connected (or hosting) — no point encoding
	# voice nobody can hear, and it keeps the mic released in the menus.
	microphone.capture_enabled = NetworkManager.is_connected_to_session()

func _unhandled_input(event):
	if InputMap.has_action(config.mute_toggle_action) and event.is_action_pressed(config.mute_toggle_action):
		microphone.toggle_mute()

## UI hook (LoginMenu's device dropdown). Safe to call at any time.
func set_input_device(device_name: String):
	microphone.set_input_device(device_name)

# --- Speaker registry -------------------------------------------------------

func register_speaker(peer_id: int, speaker: VoipSpeaker):
	# Share the ONE live config instance rather than letting the speaker fall back
	# to its own default (VoipSpeaker._ready() does `if config == null: config =
	# VoipConfig.new()`) — otherwise a project-wide VoipConfig, or a runtime
	# settings change, would silently never reach any speaker.
	speaker.config = config
	_speakers[peer_id] = speaker
	# Carry a previously-set volume preference over to a (re)spawned speaker for
	# this peer — e.g. respawning mid-match shouldn't reset someone's volume.
	if _peer_volume_db.has(peer_id):
		speaker.volume_offset_db = _peer_volume_db[peer_id]

func unregister_speaker(peer_id: int, speaker: VoipSpeaker):
	# Guard against a respawned player having already re-registered this id.
	if _speakers.get(peer_id) == speaker:
		_speakers.erase(peer_id)

# --- Local listening preferences (mute / volume) -----------------------------
# Purely local: no RPCs, no server involvement. Whether *I* hear *you* is my
# decision alone, so none of this touches the network.

func set_peer_muted(peer_id: int, muted: bool):
	if muted:
		_peer_muted[peer_id] = true
	else:
		_peer_muted.erase(peer_id)
	peer_muted_changed.emit(peer_id, muted)

func is_peer_muted(peer_id: int) -> bool:
	return _peer_muted.get(peer_id, false)

## volume_db is an offset added to VoipConfig.playback_volume_db, not an absolute
## value — 0.0 means "no adjustment". Applies immediately even mid-burst (unlike
## VoipConfig.playback_volume_db, which only takes effect at the next stream start).
func set_peer_volume_db(peer_id: int, volume_db: float):
	if is_zero_approx(volume_db):
		_peer_volume_db.erase(peer_id)
	else:
		_peer_volume_db[peer_id] = volume_db
	var speaker: VoipSpeaker = _speakers.get(peer_id)
	if speaker:
		speaker.volume_offset_db = volume_db
	peer_volume_changed.emit(peer_id, volume_db)

func get_peer_volume_db(peer_id: int) -> float:
	return _peer_volume_db.get(peer_id, 0.0)

## A reconnecting peer was assigned a new peer_id (see EventBus.peer_identity_migrated).
## Carry local preferences about them over rather than silently losing them.
func _on_peer_identity_migrated(old_id: int, new_id: int):
	if _peer_muted.has(old_id):
		_peer_muted[new_id] = true
		_peer_muted.erase(old_id)
	if _peer_volume_db.has(old_id):
		_peer_volume_db[new_id] = _peer_volume_db[old_id]
		_peer_volume_db.erase(old_id)
		var speaker: VoipSpeaker = _speakers.get(new_id)
		if speaker:
			speaker.volume_offset_db = _peer_volume_db[new_id]

# --- Outgoing (local mic -> network) ----------------------------------------

func _on_mic_control_packet(json_packet: Dictionary):
	# Not an RPC handler — this is a direct signal from VoipMicrophone, which also
	# fires when _process() above flips capture_enabled to false right as the
	# connection drops (e.g. the synthesized footer on disconnect). The peer can
	# already be inactive by that point, so check before touching multiplayer.*.
	# Nobody to send to anyway once disconnected.
	if not NetworkManager.is_connected_to_session():
		return
	var bytes := JSON.stringify(json_packet).to_ascii_buffer()
	if multiplayer.is_server():
		_server_distribute_control(multiplayer.get_unique_id(), json_packet, bytes)
	else:
		_relay_control.rpc_id(1, bytes)

func _on_mic_frame_packet(packet: PackedByteArray, frame_index: int):
	# Same reasoning as _on_mic_control_packet above.
	if not NetworkManager.is_connected_to_session():
		return
	if multiplayer.is_server():
		_server_distribute_frame(multiplayer.get_unique_id(), frame_index, packet)
	else:
		_relay_frame.rpc_id(1, packet)

func _on_mute_changed(muted: bool):
	mute_changed.emit(muted)
	# Optional chat feedback — only if the project has the EventBus autoload.
	var event_bus := get_node_or_null("/root/EventBus")
	if event_bus and event_bus.has_signal("system_message_received"):
		# Same optionality logic applied to tr(): if this project has no
		# Localization autoload, tr() just returns the key string unresolved —
		# degrades to plain English rather than erroring.
		var msg_key := "MSG_MIC_MUTED" if muted else "MSG_MIC_UNMUTED"
		event_bus.system_message_received.emit("\n[color=yellow][b]" + tr(msg_key) + "[/b][/color]")

# --- Server relay ------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _relay_control(bytes: PackedByteArray):
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var json_packet = JSON.parse_string(bytes.get_string_from_ascii())
	if json_packet == null:
		return
	_server_distribute_control(sender, json_packet, bytes)

@rpc("any_peer", "call_remote", "unreliable")
func _relay_frame(bytes: PackedByteArray):
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Frame index lives in the 2-byte chunk prefix; track it so mid-stream
	# joiners can be handed a header with an up-to-date frame count.
	if len(bytes) >= 2 and _active_streams.has(sender):
		_active_streams[sender]["last_frame"] = bytes[0] + (bytes[1] & 127) * 256
	_server_distribute_frame(sender, _active_streams.get(sender, {}).get("last_frame", 0), bytes)

func _server_distribute_control(sender: int, json_packet: Dictionary, bytes: PackedByteArray):
	if json_packet.has("talkingtimestart"):
		_active_streams[sender] = {"header": json_packet, "last_frame": 0, "heard_by": {}}
	elif json_packet.has("talkingtimeend"):
		_active_streams.erase(sender)
	for listener in _listener_candidates():
		if not _should_hear(listener, sender):
			continue
		if _active_streams.has(sender):
			_active_streams[sender]["heard_by"][listener] = true
		_deliver(listener, sender, bytes, false)

func _server_distribute_frame(sender: int, frame_index: int, bytes: PackedByteArray):
	if _active_streams.has(sender):
		_active_streams[sender]["last_frame"] = frame_index
	for listener in _listener_candidates():
		if not _should_hear(listener, sender):
			continue
		_ensure_header_replayed(listener, sender)
		_deliver(listener, sender, bytes, true)

## Every id that could conceivably be listening: every connected peer, plus the
## server's own local playback. multiplayer.get_unique_id() is always 1 here since
## only the server ever reaches these functions (guarded by is_server() upstream).
func _listener_candidates() -> Array:
	var listeners := multiplayer.get_peers()
	listeners.append(multiplayer.get_unique_id())
	return listeners

func _should_hear(listener: int, sender: int) -> bool:
	if listener == sender and not hear_self:
		return false
	if voice_relevance.is_valid() and not voice_relevance.call(listener, sender):
		return false
	return true

## A listener who just became relevant mid-burst (e.g. walked into proximity range)
## never saw this stream's header and would otherwise hear nothing until the next
## burst starts — the frame packets alone carry no stream context. Replay the header
## once, exactly like a peer that connects mid-stream (see _on_peer_connected), the
## first time such a listener is about to receive a frame.
func _ensure_header_replayed(listener: int, sender: int):
	if not _active_streams.has(sender):
		return
	var stream: Dictionary = _active_streams[sender]
	if stream["heard_by"].get(listener, false):
		return
	stream["heard_by"][listener] = true
	var replay: Dictionary = stream["header"].duplicate()
	replay["opusframecount"] = stream["last_frame"]
	_deliver(listener, sender, JSON.stringify(replay).to_ascii_buffer(), false)

func _deliver(listener: int, sender: int, bytes: PackedByteArray, unreliable: bool):
	if listener == multiplayer.get_unique_id():
		_deliver_to_speaker(sender, bytes)
	elif unreliable:
		_client_receive_frame.rpc_id(listener, sender, bytes)
	else:
		_client_receive_control.rpc_id(listener, sender, bytes)

# --- Incoming (network -> speakers) ------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _client_receive_control(sender: int, bytes: PackedByteArray):
	if sender != multiplayer.get_unique_id() or hear_self:
		_deliver_to_speaker(sender, bytes)

@rpc("authority", "call_remote", "unreliable")
func _client_receive_frame(sender: int, bytes: PackedByteArray):
	if sender != multiplayer.get_unique_id() or hear_self:
		_deliver_to_speaker(sender, bytes)

func _deliver_to_speaker(sender: int, bytes: PackedByteArray):
	if is_peer_muted(sender):
		return
	var speaker: VoipSpeaker = _speakers.get(sender)
	if speaker:
		speaker.receive_packet(bytes)

# --- Peer lifecycle -----------------------------------------------------------

func _on_peer_connected(peer_id: int):
	if not multiplayer.is_server():
		return
	# Anyone mid-sentence when this peer joined: re-send their stream header
	# with the current frame count so the new peer can lock onto the stream.
	# Skip senders this new peer isn't relevant to (e.g. out of proximity range) —
	# no point handing them a header for a stream they won't receive frames of.
	for sender in _active_streams:
		if not _should_hear(peer_id, sender):
			continue
		var stream: Dictionary = _active_streams[sender]
		stream["heard_by"][peer_id] = true
		var replay: Dictionary = stream["header"].duplicate()
		replay["opusframecount"] = stream["last_frame"]
		_client_receive_control.rpc_id(peer_id, sender, JSON.stringify(replay).to_ascii_buffer())

func _on_peer_disconnected(peer_id: int):
	if multiplayer.is_server() and _active_streams.has(peer_id):
		# Sender vanished mid-stream: synthesize the footer they never sent.
		_active_streams.erase(peer_id)
		var cutoff := JSON.stringify({"talkingtimeend": -1}).to_ascii_buffer()
		for peer in multiplayer.get_peers():
			if peer != peer_id:
				_client_receive_control.rpc_id(peer, peer_id, cutoff)
		_deliver_to_speaker(peer_id, cutoff)
	var speaker: VoipSpeaker = _speakers.get(peer_id)
	if speaker:
		speaker.end_stream()
