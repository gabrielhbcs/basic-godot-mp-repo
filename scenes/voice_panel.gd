class_name VoicePanel
extends HBoxContainer
## Per-peer voice mute/volume controls for whichever peer_id is currently
## selected (see set_selected_peer). Purely local UI + VoipNetwork calls — no
## netcode, no ready-state, no admin logic. Attach to a container with a
## CheckButton child "PeerMuteButton" and an HSlider child "PeerVolumeSlider"
## (matching lobby.tscn's PeerVoiceControls), or point the two exports at them.

@export var mute_button: CheckButton
@export var volume_slider: HSlider

var _selected_peer_id: int = -1

func _ready():
	if mute_button:
		mute_button.toggled.connect(_on_mute_toggled)
	if volume_slider:
		volume_slider.value_changed.connect(_on_volume_changed)
	set_selected_peer(-1)

## -1 = nothing selected; disables both controls. The caller (lobby.gd) already
## excludes the local player's own id — see its _select_peer for why.
func set_selected_peer(peer_id: int):
	_selected_peer_id = peer_id
	var has_selection := peer_id != -1
	if mute_button:
		mute_button.disabled = not has_selection
		mute_button.set_pressed_no_signal(has_selection and VoipNetwork.is_peer_muted(peer_id))
	if volume_slider:
		volume_slider.editable = has_selection
		volume_slider.set_value_no_signal(VoipNetwork.get_peer_volume_db(peer_id) if has_selection else 0.0)

func _on_mute_toggled(toggled_on: bool):
	if _selected_peer_id != -1:
		VoipNetwork.set_peer_muted(_selected_peer_id, toggled_on)

func _on_volume_changed(value: float):
	if _selected_peer_id != -1:
		VoipNetwork.set_peer_volume_db(_selected_peer_id, value)
