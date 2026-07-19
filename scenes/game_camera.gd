extends Camera2D
class_name GameCamera

@export_category("Target Tracking")
@export var target_group: String = "local_player"
@export var lerp_speed: float = 8.0
@export var look_ahead_factor: float = 0.2
@export var look_ahead_speed: float = 2.0

@export_category("Zoom Settings")
@export var enable_zoom_control: bool = true
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0
@export var zoom_speed: float = 10.0
@export var zoom_step: float = 0.1

var target: Node2D = null
var target_zoom: float = 1.0
var _shake_intensity: float = 0.0
var _shake_duration: float = 0.0

func _ready() -> void:
	# Add to a group so other systems can find the camera (e.g. to trigger shake or change zoom)
	add_to_group("game_camera")
	
	# Listen to tree changes to auto-detect when a local player is spawned/added
	get_tree().node_added.connect(_on_node_added)
	
	_find_target()
	
	# Set target_zoom to current zoom on startup
	target_zoom = zoom.x
	
	# Centering behavior
	if is_instance_valid(target):
		global_position = target.global_position

func _process(delta: float) -> void:
	_handle_zoom(delta)
	
	# Calculate target position
	var target_pos = global_position
	if is_instance_valid(target):
		target_pos = target.global_position
		
		# Optional look-ahead based on target velocity (if it's a CharacterBody2D or has velocity)
		if look_ahead_factor > 0.0 and "velocity" in target:
			var velocity = target.get("velocity")
			if velocity is Vector2:
				target_pos += velocity * look_ahead_factor
	else:
		_find_target()
	
	# Smooth movement
	global_position = global_position.lerp(target_pos, lerp_speed * delta)
	
	# Camera shake
	_handle_shake(delta)

func _handle_zoom(delta: float) -> void:
	if not enable_zoom_control:
		return
		
	# Smoothly interpolate zoom
	zoom = zoom.lerp(Vector2(target_zoom, target_zoom), zoom_speed * delta)

func _unhandled_input(event: InputEvent) -> void:
	if not enable_zoom_control:
		return
		
	if event is InputEventMouseButton and event.is_pressed():
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			target_zoom = min(target_zoom + zoom_step, max_zoom)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			target_zoom = max(target_zoom - zoom_step, min_zoom)

func _handle_shake(delta: float) -> void:
	if _shake_duration > 0:
		_shake_duration -= delta
		var offset_pos = Vector2(
			randf_range(-_shake_intensity, _shake_intensity),
			randf_range(-_shake_intensity, _shake_intensity)
		)
		offset = offset_pos
		if _shake_duration <= 0:
			offset = Vector2.ZERO
	else:
		offset = Vector2.ZERO

# Public API for screen shake - any script can call this
# e.g., get_tree().call_group("game_camera", "shake", 10.0, 0.3)
func shake(intensity: float, duration: float) -> void:
	_shake_intensity = intensity
	_shake_duration = duration

func _find_target() -> void:
	var targets = get_tree().get_nodes_in_group(target_group)
	if targets.size() > 0:
		target = targets[0] as Node2D

func _on_node_added(node: Node) -> void:
	if node.is_in_group(target_group) and node is Node2D:
		target = node
