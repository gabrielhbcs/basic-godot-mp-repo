extends CharacterBody2D

@export_category("Movement Settings")
@export var speed: float = 300.0
@export var interpolation_speed: float = 15.0

@onready var sprite = $Sprite2D
@onready var rollback: RollbackController = $RollbackController

var peer_id: int

# --- ANIMATION DATA ---
var anim_timer: float = 0.0
var anim_fps: float = 12.0

# --- INTERPOLATION DATA (remote dummies only) ---
@export var sync_position := Vector2.ZERO

func _ready():
	peer_id = str(name).to_int()

	if multiplayer.is_server():
		sync_position = position
	else:
		position = sync_position

	# Generate a unique, consistent color for every player based on their ID!
	var rng = RandomNumberGenerator.new()
	rng.seed = peer_id

	# Hue is random, Saturation and Value are high so the colors are vibrant
	sprite.modulate = Color.from_hsv(rng.randf(), 0.8, 1.0)

	add_to_group("players")

	rollback.owner_peer_id = peer_id
	rollback.gather_input = _gather_input
	rollback.apply_input = _apply_input
	rollback.sanitize_input = _sanitize_input

	if peer_id == multiplayer.get_unique_id():
		add_to_group("local_player")
		rollback.role = RollbackController.Role.LOCAL_PREDICTED
	elif multiplayer.is_server():
		rollback.role = RollbackController.Role.SERVER_AUTHORITY
	else:
		rollback.role = RollbackController.Role.REMOTE_DUMMY

func _process(delta):
	_update_animation(delta)

func _physics_process(delta):
	if rollback.role == RollbackController.Role.REMOTE_DUMMY:
		_process_dummy_player(delta)

func _update_animation(delta):
	anim_timer += delta
	if anim_timer >= 1.0 / anim_fps:
		anim_timer -= 1.0 / anim_fps

		var is_moving = false
		var facing_left = sprite.flip_h

		# Runs every frame via _process regardless of connection state, so this can't
		# call multiplayer.is_server()/get_unique_id() directly (unsafe mid-reconnect).
		# rollback.role was cached once in _ready() and never changes for this node.
		if rollback.role == RollbackController.Role.LOCAL_PREDICTED or rollback.role == RollbackController.Role.SERVER_AUTHORITY:
			is_moving = velocity.length_squared() > 10
			if is_moving: facing_left = velocity.x < 0
		else:
			# For remote dummy players, detect movement via interpolation distance
			var dist = position.distance_to(sync_position)
			is_moving = dist > 2.0
			if is_moving: facing_left = (sync_position.x - position.x) < 0

		sprite.flip_h = facing_left

		# Row 1 is idle (0-5), Row 2 is walking (8-15)
		if is_moving:
			sprite.frame = wrapi(sprite.frame + 1, 8, 16)
		else:
			# If transitioning from walk to idle, reset frame into idle range
			if sprite.frame >= 6: sprite.frame = 0
			sprite.frame = wrapi(sprite.frame + 1, 0, 6)

# ==========================================
# Input contract for RollbackController — this is the ONLY place in this file
# that knows what "input" means. Swap these three functions to change what the
# player can do (add jump, aim, abilities, ...) without touching netcode at all.
# ==========================================

func _gather_input() -> Dictionary:
	var dir := Vector2.ZERO
	if Input.is_action_pressed("move_up") or Input.is_action_pressed("ui_up"): dir.y -= 1
	if Input.is_action_pressed("move_down") or Input.is_action_pressed("ui_down"): dir.y += 1
	if Input.is_action_pressed("move_left") or Input.is_action_pressed("ui_left"): dir.x -= 1
	if Input.is_action_pressed("move_right") or Input.is_action_pressed("ui_right"): dir.x += 1
	return {"dir": dir.normalized()}

func _apply_input(input: Dictionary, _delta: float) -> void:
	var dir: Vector2 = input.get("dir", Vector2.ZERO)
	velocity = dir * speed
	move_and_slide()
	# Runs every physics frame regardless of connection state — same reasoning as
	# _update_animation above, use the cached role instead of multiplayer.is_server().
	if rollback.role == RollbackController.Role.SERVER_AUTHORITY:
		sync_position = position

func _sanitize_input(input: Dictionary) -> Dictionary:
	# Never trust client-provided direction magnitude - clamp it so a modified
	# client can't send an oversized vector to move faster than intended (speed hack).
	var dir: Vector2 = input.get("dir", Vector2.ZERO)
	if dir.length() > 1.0:
		dir = dir.normalized()
	input["dir"] = dir
	return input

# ==========================================
# Remote dummy interpolation (not part of rollback — this player isn't predicted
# or reconciled at all locally, just smoothed toward the last known sync_position)
# ==========================================
func _process_dummy_player(delta):
	if position.distance_to(sync_position) > 100:
		position = sync_position
	else:
		position = position.lerp(sync_position, interpolation_speed * delta)
