extends Node
## Player identity: profiles, and the version/identity handshake new connections
## go through (see client_hello). Owns the persistent per-install client_uuid that
## lets a reconnecting client be recognized as the same player rather than a new
## one — NetworkManager only manages the transport-level reconnect attempt itself.

## How long a disconnected player's identity is held for a possible reconnect
## before being treated as a permanent departure. Server only.
const RECONNECT_GRACE_SEC := 60.0

# Expandable dictionary for the local player
var local_profile: Dictionary = {
	"name": "Player"
}

## Persistent per-install identity, generated once and kept in user://. Lets the
## server recognize "this is the same player as peer X who just dropped" even
## though ENet always assigns a reconnecting client a brand-new peer_id.
var client_uuid: String = ""

# Stores all connected players (peer_id -> Dictionary), kept in sync on every client
var players: Dictionary = {}

# Server only: bookkeeping for reconnect detection.
var _uuid_to_peer: Dictionary = {}       # uuid -> currently-connected peer_id
var _peer_to_uuid: Dictionary = {}       # peer_id -> uuid, inverse of the above
var _recent_departures: Dictionary = {}  # uuid -> {"profile": Dictionary, "peer_id": int, "left_at_msec": int}
var _departure_sweep_timer: Timer

func _ready():
	client_uuid = _load_or_create_client_uuid()
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)

	_departure_sweep_timer = Timer.new()
	_departure_sweep_timer.wait_time = 15.0
	_departure_sweep_timer.autostart = true
	_departure_sweep_timer.timeout.connect(_sweep_expired_departures)
	add_child(_departure_sweep_timer)

func host_setup():
	players[1] = local_profile.duplicate()
	_peer_to_uuid[1] = client_uuid
	_uuid_to_peer[client_uuid] = 1
	EventBus.player_data_updated.emit(1)

func _on_peer_disconnected(id: int):
	if multiplayer.is_server() and _peer_to_uuid.has(id):
		var uuid: String = _peer_to_uuid[id]
		_recent_departures[uuid] = {
			"profile": players.get(id, {}).duplicate(),
			"peer_id": id,
			"left_at_msec": Time.get_ticks_msec(),
		}
		_uuid_to_peer.erase(uuid)
		_peer_to_uuid.erase(id)
	players.erase(id)

func _on_connected_to_server():
	# First and only thing we send: version + persistent identity + profile, all
	# together, so the server can validate the version before trusting anything else.
	client_hello.rpc_id(1, NetworkManager.PROTOCOL_VERSION, client_uuid, local_profile)

@rpc("any_peer", "call_remote", "reliable")
func client_hello(client_version: int, uuid: String, profile: Dictionary):
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()

	if client_version != NetworkManager.PROTOCOL_VERSION:
		NetworkManager.reject_handshake(sender, "Protocol version mismatch (server=%d, client=%d)" % [NetworkManager.PROTOCOL_VERSION, client_version])
		return
	if uuid.is_empty():
		NetworkManager.reject_handshake(sender, "Missing client identity")
		return
	if NetworkManager.is_banned(uuid, NetworkManager.get_peer_ip(sender)):
		NetworkManager.reject_handshake(sender, "You are banned from this server.")
		return
	if _uuid_to_peer.has(uuid):
		# Not real security (uuid is client-supplied, unauthenticated) — just a
		# sanity guard against an accidental double-launch reusing the same id.
		NetworkManager.reject_handshake(sender, "This client is already connected")
		return

	var reconnected_from_peer: int = -1
	_prune_if_expired(uuid)
	if _recent_departures.has(uuid):
		# Reconnect: restore the old identity wholesale rather than trusting
		# whatever profile the client just sent (keeps the established name).
		var departure: Dictionary = _recent_departures[uuid]
		profile = departure["profile"]
		reconnected_from_peer = departure["peer_id"]
		_recent_departures.erase(uuid)
	else:
		# Fresh join: sanitize + de-duplicate the name as before.
		if not profile.has("name") or profile["name"].is_empty():
			profile["name"] = "Player " + str(sender)
		var base_name = profile["name"]
		var suffix = 1
		var name_exists = true
		while name_exists:
			name_exists = false
			for p_id in players:
				if players[p_id].has("name") and players[p_id]["name"] == profile["name"]:
					name_exists = true
					break
			if name_exists:
				suffix += 1
				profile["name"] = base_name + " " + str(suffix)

	players[sender] = profile
	_uuid_to_peer[uuid] = sender
	_peer_to_uuid[sender] = uuid

	NetworkManager.accept_handshake(sender)

	# Broadcast this profile to everyone, and catch the (re)joining client up on
	# everyone else's.
	update_profile.rpc(sender, profile)
	for existing_id in players:
		if existing_id != sender:
			update_profile.rpc_id(sender, existing_id, players[existing_id])

	if reconnected_from_peer != -1:
		# Tell every client (including ourselves, via call_local) that old_id is now
		# new_id, so peer_id-keyed local state (VOIP mute/volume, UI selection,
		# ready status) gets migrated instead of silently orphaned.
		_broadcast_identity_migration.rpc(reconnected_from_peer, sender)

@rpc("authority", "call_local", "reliable")
func update_profile(id: int, profile: Dictionary):
	players[id] = profile
	EventBus.player_data_updated.emit(id)

@rpc("authority", "call_local", "reliable")
func _broadcast_identity_migration(old_id: int, new_id: int):
	EventBus.peer_identity_migrated.emit(old_id, new_id)

## Server only. "" if peer_id isn't currently connected/tracked. Used by
## NetworkManager.is_admin() and ban_peer() — moderation needs the stable identity
## behind a peer_id, not the peer_id itself, since peer_ids are ephemeral.
func get_peer_uuid(peer_id: int) -> String:
	return _peer_to_uuid.get(peer_id, "")

func _prune_if_expired(uuid: String):
	if not _recent_departures.has(uuid):
		return
	var age_sec: float = (Time.get_ticks_msec() - _recent_departures[uuid]["left_at_msec"]) / 1000.0
	if age_sec > RECONNECT_GRACE_SEC:
		_recent_departures.erase(uuid)

func _sweep_expired_departures():
	for uuid in _recent_departures.keys():
		_prune_if_expired(uuid)

# --- Persistent client identity -----------------------------------------------

func _load_or_create_client_uuid() -> String:
	# Testing hook: two instances launched from the same machine/install share the
	# same user:// dir and would otherwise send the same uuid, tripping the
	# duplicate-connection guard in client_hello(). Pass --client-uuid=<anything>
	# on the command line to give a local test instance its own identity instead
	# (e.g. run one instance normally and a second with --client-uuid=test2).
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--client-uuid="):
			return arg.trim_prefix("--client-uuid=")

	var path := "user://client_identity.cfg"
	var cfg := ConfigFile.new()
	if cfg.load(path) == OK:
		var existing: String = cfg.get_value("client", "uuid", "")
		if not existing.is_empty():
			return existing
	var uuid := _generate_uuid_v4()
	cfg.set_value("client", "uuid", uuid)
	var err := cfg.save(path)
	if err != OK:
		push_warning("PlayerManager: failed to persist client identity (error %d) — a new id will be generated next launch, so reconnect-identity restoration won't survive a restart." % err)
	return uuid

func _generate_uuid_v4() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0F) | 0x40  # version 4
	bytes[8] = (bytes[8] & 0x3F) | 0x80  # variant 10xx
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]
