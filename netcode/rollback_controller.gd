class_name RollbackController
extends Node
## Server-authoritative tick-based input prediction/reconciliation, generic over
## what "input" means. This node knows about ticks, RPC transport, and Node2D
## position — never what a direction, a jump, or an ability means. That's supplied
## by the owner via three callbacks (see below), matching the reference wiring in
## player.gd.
##
## Netcode/VOIP mirror each other deliberately in this template: VoipNetwork is
## the one file that knows multiplayer exists for voice, and VoipMicrophone/
## VoipSpeaker are transport-agnostic. Here, RollbackController is the one node
## that knows about ticks/RPCs/reconciliation, and gather_input/apply_input make
## it game-input-agnostic — swap what those two callbacks do, and this file never
## changes.
##
## Usage: add as a child of a CharacterBody2D-like Node2D (owner_body is inferred
## from get_parent()), assign gather_input/apply_input/sanitize_input and
## owner_peer_id, then set role once identity is known — see player.gd.

## Local-player prediction: called once per physics tick to capture this tick's
## input. func() -> Dictionary. "tick" is added automatically before sending —
## don't put it in the returned Dictionary yourself.
var gather_input: Callable

## Applies one input frame to the owner (move_and_slide() or equivalent). Called
## both during live prediction and during reconciliation replay, so it must be a
## pure function of (owner's current state, input, delta) with no side effects
## beyond moving the owner — replaying it multiple times with the same inputs must
## always land at the same position.
## func(input: Dictionary, delta: float) -> void
var apply_input: Callable

## Server-side only: sanitize/clamp untrusted client input before it's ever
## applied or queued (e.g. clamp an oversized direction vector — a modified client
## could otherwise claim to move faster than intended). func(Dictionary) -> Dictionary.
## Left unset, input is trusted as-is — a warning is printed once to make that
## an explicit, visible choice rather than a silent gap.
var sanitize_input: Callable

## Which peer this controller's input belongs to. Set once, before the first tick.
var owner_peer_id: int = -1

enum Role {
	NONE,             ## Not yet configured — no-ops.
	LOCAL_PREDICTED,  ## This is the local player: predict, send input, reconcile.
	SERVER_AUTHORITY, ## Server processing a remote client's queued input.
	REMOTE_DUMMY,     ## Someone else's player on a non-authoritative client — this
	                  ## controller does nothing; the owner interpolates separately.
}
var role: Role = Role.NONE

## Large gap between predicted and server-authoritative position snaps instantly
## (client desynced — lag spike, packet loss); small gaps get smoothed in over a
## couple frames so tiny corrections aren't visible pops.
@export var rollback_snap_threshold: float = 3.0
## Bounded per tick so a client flooding input RPCs (accidental lag-spike replay,
## or deliberate) can't force multiple move steps in one server frame.
const MAX_INPUTS_PER_TICK: int = 6
## Hard cap so a misbehaving/malicious client can't grow the queue unbounded.
const MAX_QUEUED_INPUTS: int = 30

var current_tick: int = 0
var pending_inputs: Array = []       # local-predicted client only
var server_input_queue: Array = []   # server only

var _owner_body: Node2D
var _warned_no_sanitizer: bool = false

func _ready():
	_owner_body = get_parent() as Node2D
	assert(_owner_body != null, "RollbackController must be a child of a Node2D")

func _physics_process(delta: float):
	match role:
		Role.LOCAL_PREDICTED:
			_tick_local_predicted(delta)
		Role.SERVER_AUTHORITY:
			_tick_server_authority()
		Role.REMOTE_DUMMY, Role.NONE:
			pass  # owner handles remote interpolation itself, if any

func _tick_local_predicted(delta: float):
	current_tick += 1
	var input_data: Dictionary = gather_input.call()
	input_data["tick"] = current_tick
	apply_input.call(input_data, delta)

	if not multiplayer.is_server():
		# The host's own local player has full authority already and never needs
		# to round-trip an RPC to itself, so only real clients predict+buffer.
		pending_inputs.append(input_data)
		_send_input_to_server.rpc_id(1, input_data)

func _tick_server_authority():
	var processed := 0
	while not server_input_queue.is_empty() and processed < MAX_INPUTS_PER_TICK:
		var input_data: Dictionary = server_input_queue.pop_front()
		apply_input.call(input_data, get_physics_process_delta_time())
		_send_auth_state.rpc_id(owner_peer_id, {"tick": input_data.get("tick", 0), "pos": _owner_body.position})
		processed += 1

@rpc("any_peer", "call_remote", "unreliable")
func _send_input_to_server(input_data: Dictionary):
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != owner_peer_id:
		return

	if sanitize_input.is_valid():
		input_data = sanitize_input.call(input_data)
	elif not _warned_no_sanitizer:
		_warned_no_sanitizer = true
		push_warning("RollbackController: no sanitize_input set for peer %d — trusting client input as-is." % owner_peer_id)

	server_input_queue.append(input_data)
	if server_input_queue.size() > MAX_QUEUED_INPUTS:
		server_input_queue.pop_front()  # drop the oldest rather than let a flood pile up unbounded

@rpc("authority", "call_remote", "unreliable")
func _send_auth_state(state: Dictionary):
	var auth_tick = state["tick"]
	var auth_pos: Vector2 = state["pos"]

	var unacknowledged: Array = []
	for p in pending_inputs:
		if p["tick"] > auth_tick:
			unacknowledged.append(p)
	pending_inputs = unacknowledged

	var original_pos: Vector2 = _owner_body.position
	_owner_body.position = auth_pos

	for p in pending_inputs:
		apply_input.call(p, get_physics_process_delta_time())

	var predicted_pos: Vector2 = _owner_body.position

	if original_pos.distance_to(predicted_pos) > rollback_snap_threshold:
		_owner_body.position = predicted_pos
	else:
		_owner_body.position = original_pos.lerp(predicted_pos, 0.2)
