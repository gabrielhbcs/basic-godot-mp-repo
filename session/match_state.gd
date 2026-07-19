class_name MatchState
extends Node
## Server-authoritative ready-up / countdown / match-lifecycle state machine.
##
## Emits signals only — no UI references, no chat/system messages, no scene
## loading. Mirrors this template's voip/netcode pattern: one focused node
## owning a slice of multiplayer state and its own RPCs, decoupled from whatever
## UI (or none) observes it. A lobby scene with a totally different look, or a
## game with no lobby UI at all, can drive the same ready/countdown flow by just
## listening to these signals instead of copying this logic.
##
## Attach as a child of the lobby scene (same RPC-addressing requirement as
## RollbackController under Player: the node's path must match across every
## peer, which it does here since lobby.tscn loads identically everywhere).

## UI refresh + optional "so-and-so is ready" message.
signal ready_state_changed(peer_id: int, is_ready: bool)
## Ready was pressed but not everyone is ready yet.
signal start_rejected
signal countdown_tick(seconds_left: int)
signal countdown_cancelled
## Countdown hit zero — server should now spawn the match scene.
signal match_starting
## Match ended and ready state has been reset — every peer gets this uniformly.
signal match_ended

var players_ready: Dictionary = {}
var countdown_active: bool = false
var is_local_ready: bool = false

func _ready():
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _on_peer_disconnected(id: int):
	if multiplayer.is_server():
		players_ready.erase(id)
		if countdown_active:
			cancel_countdown.rpc()

## Called by the owning scene when a reconnect migrates a peer_id (see
## EventBus.peer_identity_migrated) — carries ready status over to the new id,
## same as every other peer_id-keyed state in this template.
func migrate_peer(old_id: int, new_id: int):
	if multiplayer.is_server() and players_ready.has(old_id):
		players_ready[new_id] = players_ready[old_id]
		players_ready.erase(old_id)

## Call from a Ready-Up button press.
func request_ready_toggle():
	if multiplayer.is_server():
		if countdown_active:
			cancel_countdown.rpc()
		elif _are_all_clients_ready():
			_start_countdown.rpc()
		else:
			start_rejected.emit()
	else:
		is_local_ready = !is_local_ready
		send_ready_state.rpc_id(1, is_local_ready)

func _are_all_clients_ready() -> bool:
	for peer in multiplayer.get_peers():
		if not players_ready.get(peer, false):
			return false
	return true

@rpc("any_peer", "call_local")
func send_ready_state(is_ready: bool):
	if not multiplayer.is_server(): return
	var sender = multiplayer.get_remote_sender_id()
	players_ready[sender] = is_ready
	broadcast_player_ready.rpc(sender, is_ready)
	if not is_ready and countdown_active:
		cancel_countdown.rpc()

@rpc("authority", "call_local")
func broadcast_player_ready(id: int, is_ready: bool):
	ready_state_changed.emit(id, is_ready)

@rpc("authority", "call_local")
func _start_countdown():
	countdown_active = true
	for i in range(3, 0, -1):
		if not countdown_active: return
		countdown_tick.emit(i)
		await get_tree().create_timer(1.0).timeout
	if not countdown_active: return
	if multiplayer.is_server():
		match_starting.emit()

@rpc("authority", "call_local")
func cancel_countdown():
	countdown_active = false
	countdown_cancelled.emit()

## Server calls this (via .rpc(), so it also runs locally) when a match ends —
## resets ready state everywhere and lets every peer react uniformly.
@rpc("authority", "call_local")
func end_match():
	if multiplayer.is_server():
		for id in players_ready:
			players_ready[id] = false
		for id in PlayerManager.players:
			broadcast_player_ready.rpc(id, false)
	else:
		is_local_ready = false
	match_ended.emit()
