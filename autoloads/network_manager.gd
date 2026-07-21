extends Node

const DEFAULT_PORT = 7000
const DEFAULT_SERVER_IP = "127.0.0.1"
const MAX_PLAYERS = 32

## Bump whenever an RPC signature changes anywhere in the project (VOIP packet
## shape, PlayerManager's hello payload, netcode input frames, etc.) — a client
## and server on different versions must refuse each other rather than desync in
## confusing ways. Checked during the handshake in PlayerManager.client_hello().
## v2: player.gd's input/reconciliation RPCs moved onto a new RollbackController
## child node (see netcode/rollback_controller.gd) — different node path, so an
## old build's RPC calls would silently fail to find their target on a new build.
## v3: lobby.gd's ready/countdown/match-lifecycle RPCs moved onto a new MatchState
## child node (see session/match_state.gd) — same reasoning, different node path.
const PROTOCOL_VERSION := 3

const HANDSHAKE_TIMEOUT_SEC := 5.0
const MAX_RECONNECT_ATTEMPTS := 5
const RECONNECT_BASE_DELAY_SEC := 1.0
const RECONNECT_MAX_DELAY_SEC := 16.0

enum ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING, FAILED }

## See EventBus.connection_state_changed. UI should drive off this rather than the
## older connection_failed/server_disconnected signals, which still fire (kept for
## logging/chat-message purposes) but no longer drive navigation — see lobby.gd.
var state: ConnectionState = ConnectionState.DISCONNECTED: set = _set_state

var multiplayer_peer := ENetMultiplayerPeer.new()

var udp_broadcaster := PacketPeerUDP.new()
var broadcast_timer: Timer
var _host_display_name: String = "Dedicated Server"

## Re-exposed for UI (e.g. a HUD ping label) — same pattern as VoipNetwork's
## mute_changed/transmitting_changed. This file only measures the round trip;
## it never builds or touches a Control itself.
signal ping_updated(ms: int)

var current_ping: int = 0
var ping_timer: Timer

var _last_join_address: String = DEFAULT_SERVER_IP
var _last_join_port: int = DEFAULT_PORT
var _reconnect_attempts: int = 0
## Set by leave_game() so a deliberate disconnect never triggers the reconnect loop.
var _user_initiated_disconnect: bool = false
## Set when the server explicitly rejects our handshake (wrong version, etc).
## Unlike a dropped connection, retrying can never fix this — same client, same
## version, every time — so it skips straight to FAILED instead of burning through
## the whole backoff schedule for a guaranteed-repeat rejection.
var _rejected_by_server: bool = false
## Set when the server kicks/bans us. Same reasoning as _rejected_by_server:
## auto-reconnecting after a kick would defeat the point of kicking someone.
var _kicked_by_server: bool = false
## Set when the host deliberately leaves (see NetworkManager.leave_game's
## _send_host_left broadcast). Same reasoning as _rejected_by_server/
## _kicked_by_server: the server isn't coming back, so retrying is pointless —
## skip straight to FAILED instead of burning through the whole backoff.
var _host_left_deliberately: bool = false

## Server only: peer_id -> deadline (Time.get_ticks_msec()) for completing the
## version/identity handshake (PlayerManager.client_hello). A peer that never
## calls it — wrong build, or just hostile — gets dropped rather than left in limbo.
var _pending_handshake: Dictionary = {}

# --- Moderation ---------------------------------------------------------------
# Kick/ban admission is enforced here (server-only) but *requested* over RPC by
# any client, since the button that triggers it lives in someone's Lobby UI, not
# necessarily the server's own instance — see _request_kick/_request_ban.

const ADMIN_LIST_PATH := "user://server_admins.cfg"
const BAN_LIST_PATH := "user://bans.cfg"
## Dedicated-server-only config, plain "key=value" lines (comments start with #).
## Just "name" for now — read once at auto-host time in _ready(), so a change
## needs a restart to take effect, same as ADMIN_LIST_PATH/BAN_LIST_PATH.
##
## Deliberately NOT under user:// like the two paths above: this one is meant to
## be hand-edited by whoever's running the dedicated server, right next to the
## binary they downloaded — not buried in a per-OS AppData folder they'd have to
## go hunting for. _server_properties_path() resolves it relative to the running
## executable instead of a fixed constant.
func _server_properties_path() -> String:
	return OS.get_executable_path().get_base_dir().path_join("server.properties")

## Dedicated-server admins, by persistent client_uuid (see PlayerManager). The
## host (peer_id 1) is always implicitly an admin in a player-hosted game — this
## list exists for the headless/dedicated-server path, which auto-hosts with no
## host player (see _ready() below), so admin rights need to be granted some other
## way. Populated from ADMIN_LIST_PATH; edit that file and restart to change it —
## there's no in-game UI for granting admin, deliberately, to avoid a compromised
## admin account being able to mint more admins.
var admin_uuids: Array = []
var _banned_uuids: Dictionary = {}  # uuid -> true
var _banned_ips: Dictionary = {}    # ip -> true

func _ready() -> void:
	# Connect Godot's built-in multiplayer signals to our EventBus
	multiplayer.peer_connected.connect(_on_player_connected)
	multiplayer.peer_disconnected.connect(_on_player_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	# Setup Ping Timer
	ping_timer = Timer.new()
	ping_timer.wait_time = 1.0
	ping_timer.autostart = true
	ping_timer.timeout.connect(_on_ping_timer)
	add_child(ping_timer)

	_load_admin_uuids()
	_load_bans()

	if OS.has_feature("headless"):
		var props := _load_server_properties()
		if host_game(DEFAULT_PORT, props.get("name", "Server")): # Auto-host on startup!
			# Node-targeted RPCs (ChatUI, MatchState, LevelSpawner — anything living
			# under Lobby.tscn) are resolved by scene tree PATH on the receiving
			# side. Clients get there via server_browser.gd's Create/Join handlers
			# changing scene; the headless auto-host path skipped that entirely,
			# so the server had no Lobby/ChatUI/etc. node for those RPCs to find.
			# Deferred: called from _ready(), before the engine's own initial-scene
			# setup finishes — changing scene immediately here would race it.
			get_tree().call_deferred("change_scene_to_file", "res://scenes/lobby.tscn")

## Safe to call from anywhere, anytime — unlike multiplayer.is_server()/
## get_unique_id(), which both error loudly if the underlying ENetMultiplayerPeer
## exists but isn't currently active (mid-connect, mid-reconnect, or just
## dropped). Godot also installs a default OfflineMultiplayerPeer when nothing
## else is set, which reports CONNECTION_CONNECTED despite not being a real
## connection — has_multiplayer_peer() alone doesn't catch that, so this checks
## the peer type too. Any code that wants to react to connection state changes
## (including states like RECONNECTING/FAILED/DISCONNECTED, where the peer is
## NOT active) must go through this before touching multiplayer.is_server() or
## multiplayer.get_unique_id() directly.
func is_connected_to_session() -> bool:
	return multiplayer.has_multiplayer_peer() \
			and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer \
			and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

## -1 if not currently connected, else the real multiplayer.get_unique_id().
## Prefer this over calling get_unique_id() directly anywhere that might run
## while disconnected/reconnecting (e.g. a signal handler reacting to
## connection_state_changed, or a UI callback the player can trigger at any time).
func get_local_peer_id() -> int:
	return multiplayer.get_unique_id() if is_connected_to_session() else -1

## True once the current FAILED state already has a specific, user-facing
## reason behind it (kicked, banned, rejected, or the host left deliberately)
## — i.e. an EventBus.system_alert already went out explaining why. Callers
## reacting to a FAILED state (e.g. Lobby's own "could not reconnect" alert)
## should check this first so the player isn't shown two modals back to back
## for the same disconnect.
func has_explained_failure() -> bool:
	return _rejected_by_server or _kicked_by_server or _host_left_deliberately

func _process(_delta):
	var connected := is_connected_to_session()

	if connected and multiplayer.is_server() and not _pending_handshake.is_empty():
		_check_handshake_timeouts()

func _set_state(new_state: ConnectionState):
	if state == new_state:
		return
	# Caught here, not at the RECONNECTING->CONNECTED transition's two call
	# sites (_send_handshake_accepted / host's own path never reconnects) —
	# one place is enough since state is the only thing both paths agree on.
	if state == ConnectionState.RECONNECTING and new_state == ConnectionState.CONNECTED:
		EventBus.system_alert_clear.emit()
	state = new_state
	EventBus.connection_state_changed.emit(state)

func _on_ping_timer():
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED or multiplayer.is_server():
		return
	# Client asks server for ping
	_ping_request.rpc_id(1, Time.get_ticks_msec())

@rpc("any_peer", "call_remote")
func _ping_request(client_time: int):
	# Server instantly returns ping
	var sender = multiplayer.get_remote_sender_id()
	_ping_response.rpc_id(sender, client_time)

@rpc("authority", "call_remote")
func _ping_response(client_time: int):
	current_ping = Time.get_ticks_msec() - client_time
	ping_updated.emit(current_ping)

func host_game(port: int = DEFAULT_PORT, host_name: String = "Server") -> bool:
	print("Starting Server")
	PlayerManager.reset_session_state()
	_host_display_name = host_name
	multiplayer_peer = ENetMultiplayerPeer.new() # MUST create a new peer to prevent reuse errors!
	var error = multiplayer_peer.create_server(port, MAX_PLAYERS)
	if error != OK:
		printerr("Cannot host server: ", error)
		return false
	multiplayer.multiplayer_peer = multiplayer_peer
	state = ConnectionState.CONNECTED  # the host never handshakes with itself

	# Start LAN UDP Broadcasting
	udp_broadcaster.set_broadcast_enabled(true)
	udp_broadcaster.set_dest_address("255.255.255.255", 7001)

	broadcast_timer = Timer.new()
	broadcast_timer.wait_time = 1.0
	broadcast_timer.autostart = true
	broadcast_timer.timeout.connect(_on_broadcast_timer)
	add_child(broadcast_timer)
	print("Hosting on ", IP.get_local_addresses()[0], ":", port)
	return true

func _on_broadcast_timer():
	if not multiplayer.is_server(): return
	if OS.has_feature("headless"):
		udp_broadcaster.put_packet(_host_display_name.to_utf8_buffer())
	else:
		udp_broadcaster.put_packet((_host_display_name + "'s Room").to_utf8_buffer())

## User-facing entry point: resets reconnect bookkeeping and remembers the address
## for any future automatic reconnect attempts. Internal retries call _connect_to()
## directly instead, so they don't reset _reconnect_attempts.
func join_game(address: String = DEFAULT_SERVER_IP, port: int = DEFAULT_PORT) -> bool:
	PlayerManager.reset_session_state()
	_last_join_address = address
	_last_join_port = port
	_reconnect_attempts = 0
	_user_initiated_disconnect = false
	_rejected_by_server = false
	_kicked_by_server = false
	_host_left_deliberately = false
	return _connect_to(address, port, ConnectionState.CONNECTING)

func _connect_to(address: String, port: int, entering_state: ConnectionState) -> bool:
	multiplayer_peer = ENetMultiplayerPeer.new() # MUST create a new peer to prevent reuse errors!
	var error = multiplayer_peer.create_client(address, port)
	if error != OK:
		printerr("Cannot join server: ", error)
		return false
	multiplayer.multiplayer_peer = multiplayer_peer
	state = entering_state
	print("Joining ", address, ":", port)
	return true

func leave_game() -> void:
	_user_initiated_disconnect = true
	_pending_handshake.clear()
	if is_instance_valid(broadcast_timer):
		broadcast_timer.queue_free()

	if is_connected_to_session() and multiplayer.is_server():
		# The host leaving takes the whole session down with it — tell every
		# connected client this is deliberate before the socket closes, so they
		# head straight back to the server browser instead of burning through
		# NetworkManager's reconnect backoff against a server that isn't coming
		# back. Same 0.3s-before-close reasoning as kick_peer()'s
		# _send_kicked/disconnect_peer pair: give the reliable RPC a moment to
		# actually reach clients first.
		_send_host_left.rpc()
		await get_tree().create_timer(0.3).timeout

	if multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	state = ConnectionState.DISCONNECTED
	print("Left the game")

## Broadcast-only (no call_local — the host itself is leaving, it doesn't need
## its own notice), so this only ever runs on the clients.
@rpc("authority", "call_remote", "reliable")
func _send_host_left():
	_host_left_deliberately = true
	EventBus.system_alert.emit(tr("MSG_HOST_LEFT"))
	# The transport disconnect (server_disconnected) follows shortly after this;
	# _maybe_reconnect() will see _host_left_deliberately and skip straight to
	# FAILED instead of retrying against a server that's gone for good.

# --- Handshake (version + identity) ------------------------------------------
# The version/identity payload itself is owned by PlayerManager.client_hello(),
# since it needs the profile/uuid in hand to decide accept vs reject. This file
# just owns the RPC plumbing and the timeout policy — see PROTOCOL_VERSION above.

## Server only. Accepts a peer's handshake: clears their timeout and confirms
## acceptance back to them (which flips their local `state` to CONNECTED).
func accept_handshake(peer_id: int):
	_pending_handshake.erase(peer_id)
	_send_handshake_accepted.rpc_id(peer_id)

## Server only. Rejects a peer's handshake with a reason, then drops them once the
## reliable rejection RPC has had a moment to actually reach them.
func reject_handshake(peer_id: int, reason: String):
	_pending_handshake.erase(peer_id)
	_send_handshake_rejected.rpc_id(peer_id, reason)
	await get_tree().create_timer(0.3).timeout
	if multiplayer_peer is ENetMultiplayerPeer:
		multiplayer_peer.disconnect_peer(peer_id)

func _check_handshake_timeouts():
	var now := Time.get_ticks_msec()
	for peer_id in _pending_handshake.keys():
		if now >= _pending_handshake[peer_id]:
			push_warning("NetworkManager: peer %d never completed the handshake in time, dropping" % peer_id)
			_pending_handshake.erase(peer_id)
			if multiplayer_peer is ENetMultiplayerPeer:
				multiplayer_peer.disconnect_peer(peer_id)

@rpc("authority", "call_remote", "reliable")
func _send_handshake_accepted():
	_reconnect_attempts = 0
	state = ConnectionState.CONNECTED

@rpc("authority", "call_remote", "reliable")
func _send_handshake_rejected(reason: String):
	push_warning("NetworkManager: handshake rejected by server: ", reason)
	_rejected_by_server = true
	EventBus.connection_failed.emit()
	# reason is a raw developer-facing diagnostic (protocol mismatch, banned,
	# duplicate connection — see PlayerManager.client_hello), not a translation
	# key, so it's shown as-is rather than through tr(). Goes through the modal,
	# not chat: the scene changes away (server_browser/login) right after this,
	# same reasoning as _send_kicked below.
	EventBus.system_alert.emit(reason)
	# The server disconnects us shortly after sending this — _maybe_reconnect()
	# will see _rejected_by_server and skip straight to FAILED rather than retry.

# --- Signal Handlers ---

func _on_player_connected(id: int) -> void:
	print("Network: Player connected: ", id)
	if multiplayer.is_server():
		_pending_handshake[id] = Time.get_ticks_msec() + HANDSHAKE_TIMEOUT_SEC * 1000.0
	EventBus.player_connected.emit(id)

func _on_player_disconnected(id: int) -> void:
	print("Network: Player disconnected: ", id)
	_pending_handshake.erase(id)
	EventBus.player_disconnected.emit(id)

func _on_connected_ok() -> void:
	# Low-level ENet connection only — state stays CONNECTING/RECONNECTING until
	# the application-level handshake (PlayerManager.client_hello) is accepted.
	print("Network: transport connected, awaiting handshake")
	EventBus.player_connected.emit(multiplayer.get_unique_id())

func _on_connected_fail() -> void:
	print("Network: Failed to connect")
	EventBus.connection_failed.emit()
	_maybe_reconnect()

func _on_server_disconnected() -> void:
	print("Network: Server disconnected")
	EventBus.server_disconnected.emit()
	_maybe_reconnect()

func _maybe_reconnect():
	if _user_initiated_disconnect:
		state = ConnectionState.DISCONNECTED
		return
	if _rejected_by_server or _kicked_by_server or _host_left_deliberately:
		# Retrying would just get rejected/kicked again, or dial a server that's
		# gone for good, every time.
		push_warning("NetworkManager: not retrying — server rejected us, kicked us, or the host left")
		state = ConnectionState.FAILED
		return
	if _reconnect_attempts >= MAX_RECONNECT_ATTEMPTS:
		push_warning("NetworkManager: giving up after %d reconnect attempts" % _reconnect_attempts)
		state = ConnectionState.FAILED
		return
	_reconnect_attempts += 1
	state = ConnectionState.RECONNECTING
	var delay: float = minf(RECONNECT_BASE_DELAY_SEC * pow(2.0, _reconnect_attempts - 1), RECONNECT_MAX_DELAY_SEC)
	print("Network: reconnecting in ", delay, "s (attempt ", _reconnect_attempts, "/", MAX_RECONNECT_ATTEMPTS, ")")
	await get_tree().create_timer(delay).timeout
	if _user_initiated_disconnect:
		return  # the user backed out (e.g. hit Leave) while we were waiting
	_connect_to(_last_join_address, _last_join_port, ConnectionState.RECONNECTING)

# --- Moderation: kick / ban ---------------------------------------------------

## True if peer_id may kick/ban: the host (peer_id 1) in a player-hosted game, or
## any peer whose persistent identity is in admin_uuids (for dedicated servers,
## which have no host player — see _ready()). This is the actual enforcement
## point; UI should still avoid *offering* kick/ban to non-admins, but must not
## be trusted as the real gate — lobby.gd only checks "am I peer 1" locally for
## button visibility, since a client can't see the server's admin_uuids list.
func is_admin(peer_id: int) -> bool:
	if peer_id == 1:
		return true
	var uuid := PlayerManager.get_peer_uuid(peer_id)
	return not uuid.is_empty() and uuid in admin_uuids

func is_banned(uuid: String, ip: String) -> bool:
	return (not uuid.is_empty() and _banned_uuids.has(uuid)) or (not ip.is_empty() and _banned_ips.has(ip))

## Server-authoritative removal, no persistence. Safe to call directly server-side
## (e.g. a future console command); remote callers go through _request_kick.
func kick_peer(peer_id: int, reason: String, requested_by: int) -> bool:
	if not multiplayer.is_server():
		return false
	if not is_admin(requested_by):
		push_warning("NetworkManager: peer %d attempted to kick without admin rights" % requested_by)
		return false
	if peer_id == 1 or peer_id == requested_by:
		return false  # can't kick the server itself, or yourself
	_send_kicked.rpc_id(peer_id, reason)
	await get_tree().create_timer(0.3).timeout
	if multiplayer_peer is ENetMultiplayerPeer:
		# now=true (immediate/forced disconnect) was tried here to close the
		# rejoin race described below, but it doesn't reliably fire
		# peer_disconnected at all — multiplayer.get_peers() can keep reporting
		# the kicked id forever, which breaks VOIP (and anything else iterating
		# connected peers) permanently instead of just narrowing a rare race.
		# A graceful disconnect (still) leaves the reconnect-during-teardown
		# race PlayerManager._dedupe_name() guards against, but that's a much
		# smaller cost than a zombie peer_id that never gets cleaned up.
		multiplayer_peer.disconnect_peer(peer_id)
	return true

## Same as kick_peer, but also records the peer's identity so a future handshake
## from them is rejected outright. Neither uuid nor IP alone is a solid ban key —
## uuid is client-supplied and forgeable, IPs are shared and rotate — so both are
## recorded and the limits accepted (see docs/known-limitations.md).
func ban_peer(peer_id: int, reason: String, requested_by: int) -> bool:
	if not multiplayer.is_server():
		return false
	if not is_admin(requested_by):
		push_warning("NetworkManager: peer %d attempted to ban without admin rights" % requested_by)
		return false
	if peer_id == 1 or peer_id == requested_by:
		return false

	var uuid := PlayerManager.get_peer_uuid(peer_id)
	if not uuid.is_empty():
		_banned_uuids[uuid] = true
	var ip := get_peer_ip(peer_id)
	if not ip.is_empty():
		_banned_ips[ip] = true
	_save_bans()

	return await kick_peer(peer_id, reason, requested_by)

func unban_uuid(uuid: String):
	if _banned_uuids.erase(uuid):
		_save_bans()

func unban_ip(ip: String):
	if _banned_ips.erase(ip):
		_save_bans()

## Snapshots for a ban-management UI. Server-authoritative data (this dictionary
## is only ever populated on the machine actually running as server), so this is
## meaningless to call from a plain client — same assumption BanListPanel makes
## by only showing its button to the host.
func get_banned_uuids() -> Array:
	return _banned_uuids.keys()

func get_banned_ips() -> Array:
	return _banned_ips.keys()

## "" if peer_id isn't currently connected or we're not using ENet.
func get_peer_ip(peer_id: int) -> String:
	if multiplayer_peer is ENetMultiplayerPeer:
		var enet_peer: ENetPacketPeer = multiplayer_peer.get_peer(peer_id)
		if enet_peer:
			return enet_peer.get_remote_address()
	return ""

## Remote entry point: any connected client can call this (e.g. Lobby's Kick
## button), targeting the server — kick_peer() re-checks is_admin() itself, so a
## non-admin calling this directly (bypassing the UI gate) is still refused.
## The host does NOT go through this RPC: Godot refuses a "call_remote" RPC
## targeting your own peer id outright (ERR_INVALID_PARAMETER), so the host calls
## kick_peer()/ban_peer() directly instead — see AdminPanel's kick/ban handlers.
@rpc("any_peer", "call_remote", "reliable")
func _request_kick(peer_id: int, reason: String):
	if not multiplayer.is_server():
		return
	kick_peer(peer_id, reason, multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable")
func _request_ban(peer_id: int, reason: String):
	if not multiplayer.is_server():
		return
	ban_peer(peer_id, reason, multiplayer.get_remote_sender_id())

@rpc("authority", "call_remote", "reliable")
func _send_kicked(reason: String):
	_kicked_by_server = true
	# reason is a translation KEY sent over the wire (see lobby.gd's kick/ban
	# handlers), resolved HERE in the receiving client's own locale — sending
	# pre-translated text would show it in the kicker's language instead.
	var message := tr("MSG_KICKED") % tr(reason)
	# Modal, not just chat: Lobby is about to change scene back to
	# server_browser (see Lobby._on_connection_state_changed), which would
	# destroy the chat log this message just got posted to before the player
	# has a chance to read it.
	EventBus.system_alert.emit(message)
	EventBus.system_message_received.emit("\n[color=red][b]" + message + "[/b][/color]")
	# The server disconnects us shortly after sending this; _maybe_reconnect()
	# will see _kicked_by_server and not try to rejoin.

func _load_admin_uuids():
	admin_uuids.clear()
	var cfg := ConfigFile.new()
	if cfg.load(ADMIN_LIST_PATH) == OK:
		admin_uuids = cfg.get_value("admins", "uuids", [])

## Plain "key=value" lines rather than ConfigFile's [section] format — a
## dedicated-server admin editing one "name=" line shouldn't need to know Godot's
## config syntax. Creates a starter file with the default commented in if none
## exists yet, same first-run experience as ADMIN_LIST_PATH/BAN_LIST_PATH.
func _load_server_properties() -> Dictionary:
	var path := _server_properties_path()
	if not FileAccess.file_exists(path):
		_write_default_server_properties(path)
	var props := {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return props
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq == -1:
			continue
		props[line.substr(0, eq).strip_edges()] = line.substr(eq + 1).strip_edges()
	return props

func _write_default_server_properties(path: String):
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("NetworkManager: failed to create default server.properties at %s (error %d)" % [path, FileAccess.get_open_error()])
		return
	file.store_line("# Dedicated server config. Edit, then restart the server to apply.")
	file.store_line("name=Server")

func _load_bans():
	_banned_uuids.clear()
	_banned_ips.clear()
	var cfg := ConfigFile.new()
	if cfg.load(BAN_LIST_PATH) == OK:
		for uuid in cfg.get_value("bans", "uuids", []):
			_banned_uuids[uuid] = true
		for ip in cfg.get_value("bans", "ips", []):
			_banned_ips[ip] = true

func _save_bans():
	var cfg := ConfigFile.new()
	cfg.set_value("bans", "uuids", _banned_uuids.keys())
	cfg.set_value("bans", "ips", _banned_ips.keys())
	var err := cfg.save(BAN_LIST_PATH)
	if err != OK:
		push_warning("NetworkManager: failed to persist ban list (error %d)" % err)
