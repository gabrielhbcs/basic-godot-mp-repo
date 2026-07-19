extends Node2D
class_name GameManager

## Server-side VOIP proximity cutoff (px) — a bandwidth optimization only, NOT the
## thing that makes voice fade with distance. Past this range the server simply
## stops sending packets at all, which is an audible hard cut, not a fade. The
## actual perceptual fade is VoipConfig.max_distance (Godot's built-in
## AudioStreamPlayer2D attenuation, already applied by VoipSpeaker). Keep this
## comfortably LARGER than that so the server cutoff is never reached before the
## client's own falloff curve has already faded voice down to near-silent —
## otherwise the player hears the exact "audio just stops" symptom this margin
## exists to prevent. Default leaves 1000px of margin over VoipConfig's default
## max_distance (2000px).
@export var max_voice_distance: float = 3000.0

@onready var player_spawn_container = $Players
@onready var player_scene = preload("res://scenes/player.tscn")
@onready var end_button = $CanvasLayer/EndMatchButton

func _ready():
	Localization.retranslate_tree(self)

	# Security: Only the server is allowed to spawn players
	if not multiplayer.is_server():
		end_button.hide()
		return

	end_button.pressed.connect(_on_end_pressed)

	# Listen for disconnects so we can clean up their avatars mid-match
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	# Proximity-cull voice on the server so out-of-range peers never even receive
	# the packets, instead of receiving-and-discarding them client-side. VoipNetwork
	# stays ignorant of positions/world state — we hand it this callback instead.
	if max_voice_distance < VoipNetwork.config.max_distance:
		push_warning("GameManager.max_voice_distance (%s) is smaller than VoipConfig.max_distance (%s) — voice will hard-cut audibly instead of fading. Raise max_voice_distance above VoipConfig.max_distance." % [max_voice_distance, VoipNetwork.config.max_distance])
	VoipNetwork.voice_relevance = _is_voice_relevant

	# Spawn a player for the host
	_spawn_player(1)

	# Spawn a player for every connected client
	for peer_id in multiplayer.get_peers():
		_spawn_player(peer_id)

func _exit_tree():
	# Don't leave VoipNetwork holding a Callable bound to this (about to be freed)
	# instance — a match ending nulls out game_container's children (lobby.gd's
	# MatchState.end_match()), and a stale bound Callable would error the next
	# time it's called.
	if VoipNetwork.voice_relevance.is_valid() and VoipNetwork.voice_relevance.get_object() == self:
		VoipNetwork.voice_relevance = Callable()

func _is_voice_relevant(listener_id: int, speaker_id: int) -> bool:
	var listener_node := player_spawn_container.get_node_or_null(str(listener_id))
	var speaker_node := player_spawn_container.get_node_or_null(str(speaker_id))
	if listener_node == null or speaker_node == null:
		return true  # can't yet locate one of them (e.g. mid-spawn) — fail open
	return listener_node.position.distance_to(speaker_node.position) <= max_voice_distance

func _spawn_player(id: int):
	var player = player_scene.instantiate()
	# Naming the node after the peer ID is critical so the Player script knows who owns it
	player.name = str(id)
	
	# Randomize spawn position slightly so they don't overlap perfectly
	var random_offset = Vector2(randf_range(-50, 50), randf_range(-50, 50))
	player.position = Vector2(500, 300) + random_offset
	
	player_spawn_container.add_child(player)

# --- Match Management ---

func _on_peer_disconnected(id: int):
	# When a player leaves mid-game, the server must delete their Node.
	# The MultiplayerSpawner will automatically replicate this deletion to all clients.
	var player_node = player_spawn_container.get_node_or_null(str(id))
	if player_node:
		player_node.queue_free()
		print("GameManager: Despawned player ", id)

func _on_end_pressed():
	EventBus.match_ended.emit()
