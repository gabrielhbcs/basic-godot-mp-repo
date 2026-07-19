class_name AdminPanel
extends HBoxContainer
## Kick/ban controls for whichever peer_id is currently selected. Purely UI + a
## network request to the server — no netcode/ready-state coupling, no
## enforcement logic of its own (NetworkManager.kick_peer/ban_peer re-check
## admin rights server-side regardless of what this panel shows).
##
## Button *visibility* here is host-only, deliberately more conservative than
## actual authorization: a client can't see the server's admin_uuids list, so a
## non-host dedicated-server admin won't see these enabled even though
## NetworkManager.is_admin() would let their request through server-side. See
## that function's doc for the full reasoning and the known gap this leaves.

@export var kick_button: Button
@export var ban_button: Button

var _selected_peer_id: int = -1

func _ready():
	if kick_button:
		kick_button.pressed.connect(_on_kick_pressed)
	if ban_button:
		ban_button.pressed.connect(_on_ban_pressed)
	set_selected_peer(-1)

func set_selected_peer(peer_id: int):
	_selected_peer_id = peer_id
	# Reachable from a raw list click via Lobby._select_peer, which can fire at any
	# time including mid disconnect/reconnect — go through the safe wrapper rather
	# than multiplayer.get_unique_id() directly (see NetworkManager.get_local_peer_id).
	var can_moderate := peer_id != -1 and NetworkManager.get_local_peer_id() == 1
	if kick_button:
		kick_button.disabled = not can_moderate
	if ban_button:
		ban_button.disabled = not can_moderate

func _on_kick_pressed():
	# A translation KEY, not resolved text — the kicked player's client resolves
	# it in THEIR OWN locale (see NetworkManager._send_kicked), since sending
	# already-translated text would show it in the kicker's language instead.
	if _selected_peer_id == -1:
		return
	if multiplayer.is_server():
		# Can't rpc_id(1, ...) targeting ourselves — Godot refuses a "call_remote"
		# RPC aimed at your own peer id outright. Only the host ever reaches this
		# branch today (see set_selected_peer's can_moderate gate); a non-host
		# admin would fall through to the RPC below instead.
		NetworkManager.kick_peer(_selected_peer_id, "KICK_REASON_REMOVED", multiplayer.get_unique_id())
	else:
		NetworkManager._request_kick.rpc_id(1, _selected_peer_id, "KICK_REASON_REMOVED")

func _on_ban_pressed():
	if _selected_peer_id == -1:
		return
	if multiplayer.is_server():
		NetworkManager.ban_peer(_selected_peer_id, "KICK_REASON_BANNED", multiplayer.get_unique_id())
	else:
		NetworkManager._request_ban.rpc_id(1, _selected_peer_id, "KICK_REASON_BANNED")
