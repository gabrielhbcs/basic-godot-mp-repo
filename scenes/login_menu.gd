extends Control

@export_category("UI References")
@export var name_input: LineEdit
@export var continue_btn: Button
@export var mic_option: OptionButton
@export var settings_button: Button
@export var settings_menu: Control

func _ready():
	if continue_btn:
		continue_btn.pressed.connect(_on_continue)

	if mic_option:
		_populate_mic_list()
		mic_option.item_selected.connect(_on_mic_selected)

	if settings_button and settings_menu:
		settings_button.pressed.connect(func(): settings_menu.visible = true)

	Localization.retranslate_tree(self)

func _populate_mic_list():
	mic_option.clear()
	var devices = AudioServer.get_input_device_list()
	var current_device = AudioServer.input_device
	var selected_index = 0
	for i in range(devices.size()):
		mic_option.add_item(devices[i])
		if devices[i] == current_device:
			selected_index = i
	if devices.size() > 0:
		mic_option.select(selected_index)

func _on_mic_selected(index: int):
	VoipNetwork.set_input_device(mic_option.get_item_text(index))

func _on_continue():
	if not name_input: return
	var nick = name_input.text.strip_edges()
	if nick.is_empty():
		nick = "Player" + str(randi() % 1000)

	PlayerManager.local_profile["name"] = nick
	get_tree().change_scene_to_file("res://scenes/server_browser.tscn")
