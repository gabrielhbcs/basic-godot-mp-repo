class_name VoipSpeaker
extends Node
## Plays back one remote player's Opus voice stream through an AudioStreamPlayer.
##
## Transport-agnostic: feed every packet belonging to this speaker's sender into
## receive_packet(). The heavy lifting (jitter buffering, out-of-order reordering,
## Opus FEC loss concealment, clock-drift compensation via pitch_scale
## time-warping) is a faithful port of the twovoip addon's reference speaker —
## deliberately reused rather than reimplemented, it is far more robust than a
## naive packet-count jitter buffer.
##
## Attach under any AudioStreamPlayer / AudioStreamPlayer2D / AudioStreamPlayer3D
## (or point audio_player_path at one) — 2D/3D players give positional voice.

signal stream_started
signal stream_ended

## The AudioStreamPlayer(2D/3D) to play through. Empty = use the parent node.
@export var audio_player_path: NodePath
@export var config: VoipConfig
@export var debug_logging: bool = false

## Extra volume applied on top of config.playback_volume_db, e.g. a per-player
## preference (VoipNetwork.set_peer_volume_db). Unlike config.playback_volume_db —
## which is only read when a new stream starts — this applies immediately, including
## mid-burst, since it's driven by a live UI control rather than a static resource.
var volume_offset_db: float = 0.0: set = set_volume_offset_db

const OPEN_BRACE := 123  # "{"
const CLOSE_BRACE := 125  # "}"
## Frames arriving more than this many positions ahead force the queue to flush.
const OUT_OF_ORDER_QUEUE_LEN := 4
## Frames batched before playback insertion begins at stream start.
const INITIAL_BATCH := 2
## Treated as "silent" for the distance fade — quiet enough to be inaudible without
## using -INF, which upsets some volume_db math.
const MIN_DISTANCE_DB := -80.0

var _player: Node
var _stream: AudioStreamOpus
var _playback: AudioStreamPlaybackOpus
var _output_latency: float = AudioServer.get_output_latency()

var _chunk_prefix_len: int = 2
var _stream_index: int = 0
var _in_stream: bool = false
var _next_frame_index: int = 0
var _opus_frame_size: int = 960
var _reorder_queue: Array = []
var _reorder_queue_count: int = 0

var _paused_on_mark: bool = false
var _pause_reached: bool = false
var _prev_skips: int = 0
var _pitch_scale: float = 1.0
var _running_lag_minimum: float = -1.0
var _sinewave_test: bool = false

var _distance_fade_db: float = 0.0
var _local_listener: Node = null

## Resolved once in _ready() and reused in _exit_tree() — walking the tree again
## at exit is unnecessary and _resolve_peer_id()'s result can't change mid-lifetime.
var _registered_peer_id: int = -1

func _ready():
	if config == null:
		config = VoipConfig.new()
	_player = _resolve_audio_player()
	assert(_player != null and _player.has_method("set_stream"), "VoipSpeaker: no AudioStreamPlayer found (parent or audio_player_path)")
	_stream = AudioStreamOpus.new()
	_player.set_stream(_stream)

	# Self-registers rather than being told by the owner — keeps the owning player
	# script (e.g. player.gd) free of any VOIP-specific code. Convention: the
	# player's root node is named str(peer_id) (see GameManager._spawn_player).
	_registered_peer_id = _resolve_peer_id()
	if _registered_peer_id != -1:
		VoipNetwork.register_speaker(_registered_peer_id, self)

func _exit_tree():
	if _registered_peer_id != -1:
		VoipNetwork.unregister_speaker(_registered_peer_id, self)

func _resolve_peer_id() -> int:
	var node: Node = self
	while node:
		if node.name.is_valid_int():
			return node.name.to_int()
		node = node.get_parent()
	push_warning("VoipSpeaker: no ancestor named as a peer_id (integer node name) found under %s — this speaker will never receive voice packets." % get_path())
	return -1

func _resolve_audio_player() -> Node:
	if not audio_player_path.is_empty():
		return get_node(audio_player_path)
	var parent := get_parent()
	if parent and parent.has_method("findaudioplayer"):
		return parent.findaudioplayer()
	return parent

## Feed every packet from this speaker's sender here: JSON header/footer packets
## and 2-byte-prefixed Opus frames alike — the format is self-describing.
func receive_packet(packet: PackedByteArray):
	if _stream == null or len(packet) <= 3:
		return
	if packet[0] == OPEN_BRACE and packet[-1] == CLOSE_BRACE:
		var header = JSON.parse_string(packet.get_string_from_ascii())
		if header != null:
			_handle_json_packet(header)
	else:
		_handle_frame_packet(packet)

## Call when the sender vanished mid-stream (disconnect) so playback runs out
## instead of waiting forever for a footer.
func end_stream():
	if _in_stream:
		_log("externally ending the stream at cutout")
		receive_packet(JSON.stringify({"talkingtimeend": -1}).to_ascii_buffer())

## Diagnostic: replace decoded audio with a 440Hz tone through the exact same
## playback path (upstream's recommended way to isolate rate/pitch problems).
func set_sinewave_test(enabled: bool):
	_sinewave_test = enabled
	if _playback:
		_playback.set_sinewave_frames(int(_stream.opus_sample_rate / 440) if enabled else 0, 0.05)

## Loudness of what's currently playing (0-1) — drive "who is speaking" UI here.
func get_output_level() -> float:
	return _playback.get_chunk_max() if _playback else 0.0

func _handle_json_packet(header: Dictionary):
	_log("voice stream json packet ", header)
	if header.has("talkingtimestart"):
		_configure_stream(int(header["opussamplerate"]), int(header.get("opuschannels", 2)))
		_chunk_prefix_len = int(header["lenchunkprefix"])
		assert(_chunk_prefix_len == 2, "VoipSpeaker only supports 2-byte chunk prefixes")
		_stream_index = int(header["opusstreamcount"])
		_opus_frame_size = int(header["opusframesize"])
		_next_frame_index = 0
		if header.get("opusframecount", 0) != 0:
			# Joined mid-stream: the relay re-sent the header with the current count.
			_log("mid-speech header, starting at frame ", header["opusframecount"])
			_next_frame_index = int(header["opusframecount"]) + 1
		_reorder_queue.clear()
		for i in range(OUT_OF_ORDER_QUEUE_LEN):
			_reorder_queue.push_back(null)
		_reorder_queue_count = 0
		_running_lag_minimum = -1.0
		_in_stream = true
		stream_started.emit()

	elif header.has("talkingtimeend"):
		# A footer can arrive with no playback ever created: VoipNetwork synthesizes a
		# cutoff for a peer that drops mid-stream (_on_peer_disconnected), and that
		# reaches speakers which never saw this stream's header — e.g. a player who
		# spawned after the burst began. _playback only exists after _configure_stream().
		if _playback == null:
			_in_stream = false
			return
		if _paused_on_mark and _playback.queue_length_frames() == 0:
			_playback.mark_end_opus_stream(true)
		_playback.mark_end_opus_stream(false)
		_paused_on_mark = true
		_pause_reached = false
		_log("stream ended, minimum buffered lag was ", _running_lag_minimum, "s (target ", _effective_lag_target(), "s)")
		_in_stream = false
		stream_ended.emit()

func _configure_stream(sample_rate: int, channel_count: int):
	if _player.playing and _stream.opus_sample_rate == sample_rate and _stream.opus_channels == channel_count:
		return
	_stream.opus_sample_rate = sample_rate
	_stream.opus_channels = channel_count
	_apply_volume()
	if _player is AudioStreamPlayer2D or _player is AudioStreamPlayer3D:
		_player.max_distance = config.max_distance
		# 0 = no built-in falloff. VoipSpeaker drives the actual distance fade itself
		# (see _update_distance_fade) so it can plateau at full volume out to
		# fade_start_distance instead of fading from any distance > 0.
		_player.attenuation = 0.0
	_player.play()  # creates a fresh playback, which starts paused on a mark
	_playback = _player.get_stream_playback()
	set_sinewave_test(_sinewave_test)
	_paused_on_mark = true
	_pause_reached = false

func set_volume_offset_db(value: float):
	volume_offset_db = value
	_apply_volume()  # takes effect immediately, even mid-burst — see the property doc

func _apply_volume():
	if _player:
		_player.volume_db = config.playback_volume_db + volume_offset_db + _distance_fade_db

## Plateau-then-fade distance curve: full volume out to fade_start_distance, fading
## to silent by max_distance. Runs every physics frame regardless of talk state, so
## volume is already correct the instant a burst starts rather than snapping.
func _update_distance_fade():
	if not (_player is AudioStreamPlayer2D or _player is AudioStreamPlayer3D):
		return
	var listener := _get_local_listener()
	if listener == null:
		return
	var dist: float = listener.global_position.distance_to(_player.global_position)
	var new_fade_db := _compute_fade_db(dist)
	if not is_equal_approx(new_fade_db, _distance_fade_db):
		_distance_fade_db = new_fade_db
		_apply_volume()

func _compute_fade_db(dist: float) -> float:
	if dist <= config.fade_start_distance or config.max_distance <= config.fade_start_distance:
		return 0.0
	if dist >= config.max_distance:
		return MIN_DISTANCE_DB
	var t := (dist - config.fade_start_distance) / (config.max_distance - config.fade_start_distance)
	t = pow(t, maxf(config.attenuation, 0.01))
	return lerpf(0.0, MIN_DISTANCE_DB, t)

## The listener is always the local player, whoever is running this client — cached
## and re-resolved if it becomes invalid (e.g. after a respawn creates a new node).
## Typed Node (not Node2D) so this stays valid for a Node3D-based game too — both
## expose global_position, just accessed dynamically here rather than statically.
func _get_local_listener() -> Node:
	if _local_listener == null or not is_instance_valid(_local_listener):
		var local_players := get_tree().get_nodes_in_group("local_player")
		_local_listener = local_players[0] if not local_players.is_empty() else null
	return _local_listener

func _handle_frame_packet(packet: PackedByteArray):
	if _playback == null:
		return
	if packet[1] & 128 != (_stream_index % 2) * 128:
		_log("dropping frame with stale stream parity")
		return

	var frame_index: int = packet[0] + (packet[1] & 127) * 256
	var offset: int = frame_index - _next_frame_index
	if offset < 0:
		if offset < -30000:
			# 15-bit counter wrapped (~10 minutes of continuous speech).
			_log("frame counter wraparound at ", frame_index)
			_next_frame_index = frame_index
			offset = 0
		else:
			_log("late frame ignored (", offset, ")")
			return

	# Frame landed beyond the reorder window: flush the queue forward, using
	# Opus FEC off the next valid packet to conceal any gaps left behind.
	while offset >= OUT_OF_ORDER_QUEUE_LEN:
		if _reorder_queue[0] != null:
			_playback.push_opus_packet(_reorder_queue[0], _chunk_prefix_len, 0)
			_reorder_queue_count -= 1
		else:
			var fec_source: PackedByteArray = packet
			for i in range(1, OUT_OF_ORDER_QUEUE_LEN):
				if _reorder_queue[i] != null:
					fec_source = _reorder_queue[i]
					break
			_playback.push_opus_packet(fec_source, _chunk_prefix_len, 1)
		_reorder_queue.pop_front()
		_reorder_queue.push_back(null)
		offset -= 1
		_next_frame_index += 1

	_reorder_queue[offset] = packet
	_reorder_queue_count += 1
	while _reorder_queue[0] != null and _next_frame_index + _reorder_queue_count >= INITIAL_BATCH:
		if _opus_frame_size > _playback.available_space_frames():
			_log("playback segment space filled up")
			break
		_playback.push_opus_packet(_reorder_queue.pop_front(), _chunk_prefix_len, 0)
		_reorder_queue.push_back(null)
		_next_frame_index += 1
		_reorder_queue_count -= 1

	if _paused_on_mark:
		_unpause_when_buffer_ready()

func _effective_lag_target() -> float:
	return config.buffer_lag_target

func _unpause_when_buffer_ready():
	var buffered_time: float = _output_latency + _playback.queue_length_frames() * 1.0 / _stream.opus_sample_rate
	if buffered_time > _effective_lag_target():
		_playback.mark_end_opus_stream(true)
		_paused_on_mark = false
		_running_lag_minimum = buffered_time

func _physics_process(_delta):
	# Independent of talk state — keeps volume correct for the instant a burst
	# starts, rather than snapping to the right level after the first frame.
	_update_distance_fade()

	if _playback == null:
		return
	var queued_frames: int = _playback.queue_length_frames()
	if not _pause_reached and queued_frames == 0:
		_pause_reached = true
		var skips: int = _playback.get_skips(false)
		_log("skips during playback: ", skips - _prev_skips)
		_prev_skips = skips

	# Continuous clock-drift compensation: nudge pitch_scale to time-warp
	# playback back toward the target buffered latency.
	var buffered_time: float = _output_latency + queued_frames * 1.0 / _stream.opus_sample_rate
	if not _paused_on_mark:
		_running_lag_minimum = buffered_time
		if _pitch_scale == 1.0:
			if abs(buffered_time - _effective_lag_target()) > config.buffer_lag_tolerance:
				_set_pitch_scale(0.7 if buffered_time < _effective_lag_target() else 1.4)
		elif (_pitch_scale < 1.0) == (buffered_time > _effective_lag_target()):
			_set_pitch_scale(1.0)

func _set_pitch_scale(pitch_scale: float):
	if pitch_scale != _pitch_scale:
		_player.pitch_scale = pitch_scale
		_pitch_scale = pitch_scale
		_log("drift compensation pitch_scale -> ", pitch_scale)

func _log(arg1: Variant, arg2: Variant = "", arg3: Variant = "", arg4: Variant = "", arg5: Variant = ""):
	if debug_logging:
		prints("[VoipSpeaker:%s]" % get_parent().name, arg1, arg2, arg3, arg4, arg5)
