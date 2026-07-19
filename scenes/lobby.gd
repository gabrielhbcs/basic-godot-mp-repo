extends Control
## Lobby UI: player list, connection status, settings launcher, and local mic
## controls. Ready-up/countdown/match lifecycle lives in MatchState (session/);
## per-peer voice controls live in VoicePanel; kick/ban controls live in
## AdminPanel — this file wires those together and reacts to their signals, but
## doesn't own their internal logic. See each file's own doc for why.

@export_category("UI References")
@export var status_label: Label
@export var mic_button: CheckButton
@export var mic_volume_bar: ProgressBar
@export var player_list: ItemList
@export var voice_panel: VoicePanel
@export var admin_panel: AdminPanel
@export var manage_bans_button: Button
@export var ban_list_panel: BanListPanel
@export var match_state: MatchState
@export var settings_button: Button
@export var settings_menu: Control
@export var ready_button: Button
@export var leave_button: Button
@export var lobby_ui: Control
@export var game_container: Node
@export var level_spawner: MultiplayerSpawner

## peer_id currently selected in player_list, driving voice_panel/admin_panel.
## -1 = nothing selected (or the local player, who can't meaningfully
## mute/kick/ban themselves).
var _selected_peer_id: int = -1

## peer_ids that just arrived via a reconnect (EventBus.peer_identity_migrated),
## so _on_player_data_updated's normal "connected" message — which also fires for
## a migrated id, since the server broadcasts update_profile for them too — gets
## suppressed once in favor of the "reconnected" message already posted.
var _recently_migrated_ids: Dictionary = {}

## Cached once in _ready() — the only point in this file where the connection is
## GUARANTEED active (you can't reach the Lobby scene without one) — rather than
## re-querying multiplayer.is_server() from every handler. That call internally
## needs get_unique_id(), which errors once the ENet peer goes inactive (mid
## reconnect, or after a drop) — exactly the situation several of these handlers
## exist to react to, so re-querying it live is unsafe by construction, not just
## unlikely. Your ROLE (host vs. client) never changes across a reconnect — only
## your peer_id does — so one cached value is correct for the life of this scene.
var _is_host: bool = false

func _ready():
	print("Room _ready() started.")
	if ready_button: ready_button.pressed.connect(_on_ready_pressed)
	if leave_button: leave_button.pressed.connect(_on_leave_pressed)
	if mic_button:
		mic_button.toggled.connect(_on_mic_toggled)
		mic_button.set_pressed_no_signal(not VoipNetwork.microphone.muted)
		VoipNetwork.mute_changed.connect(_on_voip_mute_changed)

	if player_list:
		player_list.item_selected.connect(_on_player_list_item_selected)
		player_list.empty_clicked.connect(func(_pos, _idx): _select_peer(-1))
	if settings_button and settings_menu:
		settings_button.pressed.connect(func(): settings_menu.visible = true)

	if match_state:
		match_state.ready_state_changed.connect(_on_ready_state_changed)
		match_state.start_rejected.connect(_on_start_rejected)
		match_state.countdown_tick.connect(_on_countdown_tick)
		match_state.countdown_cancelled.connect(_on_countdown_cancelled)
		match_state.match_starting.connect(_on_match_starting)
		match_state.match_ended.connect(_on_match_ended_state)

	if level_spawner: level_spawner.add_spawnable_scene("res://scenes/game.tscn")

	EventBus.player_connected.connect(_on_player_connected)
	EventBus.player_disconnected.connect(_on_player_disconnected)
	EventBus.connection_failed.connect(_on_connection_failed)
	EventBus.server_disconnected.connect(_on_server_disconnected)
	EventBus.player_data_updated.connect(_on_player_data_updated)
	EventBus.match_ended.connect(_on_match_ended_requested)
	EventBus.connection_state_changed.connect(_on_connection_state_changed)
	EventBus.peer_identity_migrated.connect(_on_peer_identity_migrated)

	_refresh_player_list()

	# status_label/ready_button change repeatedly based on game state (not just
	# once at load), so — unlike the rest of this scene's static text — they're
	# resolved with explicit tr() at every assignment site rather than relying on
	# the key+retranslate_tree() pattern; nothing else re-evaluates their CURRENT
	# state-derived value on a language switch (see localization.gd's doc for why
	# that pattern doesn't fit dynamic text). A pure language switch won't
	# retroactively relabel these until the next state change naturally does —
	# a narrow, documented limitation, not a functional gap.
	_is_host = multiplayer.is_server()  # safe here — see _is_host's doc
	if _is_host:
		if status_label: status_label.text = tr("STATUS_HOSTING")
		if ready_button: ready_button.text = tr("START_GAME")
		if manage_bans_button and ban_list_panel:
			manage_bans_button.visible = true
			manage_bans_button.pressed.connect(ban_list_panel.open)
	else:
		if status_label: status_label.text = tr("STATUS_CONNECTED")
		if ready_button: ready_button.text = tr("READY_UP")
		_on_connection_state_changed(NetworkManager.state)

	Localization.retranslate_tree(self)

func _process(_delta):
	if mic_volume_bar:
		# Smooth out the visual volume using lerp so it doesn't jump instantly
		mic_volume_bar.value = lerpf(mic_volume_bar.value, VoipNetwork.microphone.level, 10.0 * _delta)

func _on_mic_toggled(toggled_on: bool):
	# Button pressed = mic live, so the mute flag is the inverse.
	VoipNetwork.microphone.muted = not toggled_on

func _on_voip_mute_changed(muted: bool):
	if mic_button and mic_button.button_pressed == muted:
		mic_button.set_pressed_no_signal(not muted)

# --- Player list selection ----------------------------------------------------
# Lobby owns *which* peer_id is selected; VoicePanel/AdminPanel each react
# independently to that selection without needing to know about each other.

func _on_player_list_item_selected(index: int):
	_select_peer(player_list.get_item_metadata(index))

func _select_peer(peer_id: int):
	# Can't usefully mute/kick/ban yourself — you don't receive your own voice
	# packets (barring VoipNetwork.hear_self, a testing-only flag), and the
	# server already refuses a self-targeted kick/ban regardless. Reachable from
	# a raw list click, which the player can do at any time (including mid
	# disconnect/reconnect), so this goes through the safe wrapper rather than
	# multiplayer.get_unique_id() directly.
	if peer_id == NetworkManager.get_local_peer_id():
		peer_id = -1
	_selected_peer_id = peer_id
	if voice_panel:
		voice_panel.set_selected_peer(peer_id)
	if admin_panel:
		admin_panel.set_selected_peer(peer_id)

func _on_player_connected(id: int):
	_refresh_player_list()

func _on_player_disconnected(id: int):
	var player_name = get_player_name(id)
	if player_list:
		for i in range(player_list.item_count):
			if player_list.get_item_metadata(i) == id:
				player_list.remove_item(i)
				break
	if _selected_peer_id == id:
		_select_peer(-1)
	EventBus.system_message_received.emit("\n[color=gray][i]" + (tr("MSG_PLAYER_LEFT") % player_name) + "[/i][/color]")

func _on_connection_failed():
	EventBus.system_message_received.emit("\n[color=red][i]" + tr("MSG_CONNECT_FAILED") + "[/i][/color]")
	# No scene change here — NetworkManager will retry automatically (see
	# _on_connection_state_changed); we only leave once it gives up (state FAILED).

func _on_server_disconnected():
	EventBus.system_message_received.emit("\n[color=red][i]" + tr("MSG_RECONNECTING") + "[/i][/color]")
	# Same: navigation is driven by connection_state_changed reaching FAILED.

## Drives the status label and is the *only* place Lobby navigates away on
## connection loss — it waits for NetworkManager to exhaust its reconnect
## attempts (state FAILED) rather than bailing on the first drop.
func _on_connection_state_changed(new_state: int):
	if _is_host:
		return  # host's status_label stays "Hosting (Server)" regardless
	if status_label:
		match new_state:
			NetworkManager.ConnectionState.CONNECTING:
				status_label.text = tr("STATUS_CONNECTING")
			NetworkManager.ConnectionState.CONNECTED:
				status_label.text = tr("STATUS_CONNECTED")
			NetworkManager.ConnectionState.RECONNECTING:
				status_label.text = tr("STATUS_RECONNECTING")
			NetworkManager.ConnectionState.FAILED:
				status_label.text = tr("STATUS_FAILED")
			NetworkManager.ConnectionState.DISCONNECTED:
				status_label.text = tr("STATUS_DISCONNECTED")
	if new_state == NetworkManager.ConnectionState.FAILED:
		EventBus.system_message_received.emit("\n[color=red][i]" + tr("MSG_RECONNECT_FAILED") + "[/i][/color]")
		get_tree().change_scene_to_file("res://scenes/server_browser.tscn")

## A peer reconnected under a new peer_id (see EventBus.peer_identity_migrated).
## Carry the local, peer_id-keyed state that would otherwise be silently orphaned.
func _on_peer_identity_migrated(old_id: int, new_id: int):
	if match_state:
		match_state.migrate_peer(old_id, new_id)
	if _selected_peer_id == old_id:
		_select_peer(new_id)
	_recently_migrated_ids[new_id] = true
	_refresh_player_list()
	EventBus.system_message_received.emit("\n[color=gray][i]" + (tr("MSG_PLAYER_RECONNECTED") % get_player_name(new_id)) + "[/i][/color]")

func _on_leave_pressed():
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://scenes/server_browser.tscn")

func get_player_name(id: int) -> String:
	if PlayerManager.players.has(id):
		return PlayerManager.players[id]["name"]
	return tr("MSG_PLAYER_FALLBACK_NAME") % id

func _on_player_data_updated(id: int):
	_refresh_player_list()
	if _recently_migrated_ids.has(id):
		# Already announced as "reconnected" by _on_peer_identity_migrated — the
		# server's profile broadcast for a migrated id still fires this signal,
		# but a second "connected" message right after would be redundant.
		_recently_migrated_ids.erase(id)
		return
	if id != NetworkManager.get_local_peer_id() and id != 1:
		EventBus.system_message_received.emit("\n[color=gray][i]" + (tr("MSG_PLAYER_CONNECTED") % get_player_name(id)) + "[/i][/color]")

func _refresh_player_list():
	if not player_list: return
	player_list.clear()
	var players_ready: Dictionary = match_state.players_ready if match_state else {}
	var local_id := NetworkManager.get_local_peer_id()
	for id in PlayerManager.players:
		var text = get_player_name(id)
		if id == local_id:
			text += tr("LIST_YOU_SUFFIX")
		if players_ready.get(id, false):
			text += tr("LIST_READY_SUFFIX")
		var idx = player_list.add_item(text)
		player_list.set_item_metadata(idx, id)
		if id == _selected_peer_id:
			player_list.select(idx)

# --- MatchState wiring ----------------------------------------------------------
# MatchState only emits signals (see session/match_state.gd) — everything below
# translates those into UI updates and chat/system messages.

func _on_ready_pressed():
	if not match_state:
		return
	match_state.request_ready_toggle()
	# Optimistic, immediate update — matches the original's behavior of not
	# waiting for a server round-trip before the button reflects the new state.
	# request_ready_toggle() updates match_state.is_local_ready synchronously
	# before this line runs, even though the server hasn't confirmed yet.
	if not _is_host and ready_button:
		ready_button.text = tr("CANCEL_READY") if match_state.is_local_ready else tr("READY_UP")

func _on_ready_state_changed(id: int, is_ready: bool):
	_refresh_player_list()
	var name_text = get_player_name(id)
	var msg_key := "MSG_PLAYER_READY" if is_ready else "MSG_PLAYER_NOT_READY"
	EventBus.system_message_received.emit("\n[color=gray][i]" + (tr(msg_key) % name_text) + "[/i][/color]")
	# ready_button's own text is NOT updated here — see _on_ready_pressed(), which
	# updates it optimistically the instant the local player presses it, without
	# waiting for this round-trip echo from the server.

func _on_start_rejected():
	EventBus.system_message_received.emit("\n[color=red][i]" + tr("MSG_CANNOT_START") + "[/i][/color]")

func _on_countdown_tick(seconds_left: int):
	EventBus.system_message_received.emit("\n[color=yellow][b]" + (tr("MSG_COUNTDOWN") % seconds_left) + "[/b][/color]")
	if _is_host and ready_button:
		ready_button.text = tr("CANCEL_START")

func _on_countdown_cancelled():
	EventBus.system_message_received.emit("\n[color=red][i]" + tr("MSG_START_CANCELLED") + "[/i][/color]")
	if _is_host and ready_button:
		ready_button.text = tr("START_GAME")

## Countdown hit zero. Only the server actually spawns game.tscn — game_container
## is watched by a MultiplayerSpawner (see level_spawner in _ready()), which
## replicates the spawn to every client automatically; a client instantiating it
## too would create a second, unreplicated copy. lobby_ui.hide() is
## (asymmetrically, matching pre-existing behavior) also server-only.
func _on_match_starting():
	if _is_host:
		var game_scene = load("res://scenes/game.tscn").instantiate()
		if game_container: game_container.add_child(game_scene)
		if lobby_ui: lobby_ui.hide()

func _on_match_ended_requested():
	if _is_host and match_state:
		match_state.end_match.rpc()

## MatchState.end_match ran (on every peer, via call_local). Same spawner-driven
## asymmetry as _on_match_starting(): only the server frees game_container's
## children (the spawner replicates the despawn), but lobby_ui.show() and the
## chat message run on everyone.
func _on_match_ended_state():
	if _is_host:
		if game_container:
			for child in game_container.get_children():
				child.queue_free()
		if ready_button: ready_button.text = tr("START_GAME")
	else:
		if ready_button: ready_button.text = tr("READY_UP")

	if lobby_ui: lobby_ui.show()
	EventBus.system_message_received.emit("\n[color=yellow][b]" + tr("MSG_MATCH_ENDED") + "[/b][/color]")
