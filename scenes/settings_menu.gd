extends Control
## Self-contained settings overlay. Instantiate as a child of any scene (LoginMenu,
## Lobby, ...) and toggle .visible off a button — this scene never navigates away
## from its parent, so opening it never disrupts an active game/lobby session.
##
## Tab contents are built at runtime rather than hand-authored in the .tscn: audio
## buses and remappable input actions aren't known at scene-design time (a game
## can add more of either without touching this file), so both tabs just reflect
## whatever SettingsManager/AudioServer/InputMap report.
##
## Translation note: everywhere a Control.text/placeholder_text is set (whether in
## the .tscn or here in script) the value is a KEY from Localization.STRINGS, not
## literal English — Godot auto-translates Control.text on assignment regardless
## of source, no explicit tr() needed there. tr() IS called explicitly for the two
## cases that aren't a Control.text property: OptionButton item labels and
## TabContainer tab titles.

@onready var audio_tab: VBoxContainer = $Panel/VBox/Tabs/Audio
@onready var video_tab: VBoxContainer = $Panel/VBox/Tabs/Video
@onready var input_tab: VBoxContainer = $Panel/VBox/Tabs/Input
@onready var voice_tab: VBoxContainer = $Panel/VBox/Tabs/Voice
@onready var tabs: TabContainer = $Panel/VBox/Tabs
@onready var quit_button: Button = $Panel/VBox/BottomBar/QuitButton
@onready var close_button: Button = $Panel/VBox/BottomBar/CloseButton

var _rebinding_action: StringName = &""
var _rebind_button: Button = null

# Voice tab controls, built at runtime; kept here so _on_apply_voice_pressed can read them.
var _device_option: OptionButton
var _activation_option: OptionButton
var _vox_slider: HSlider
var _gain_slider: HSlider
var _denoise_check: CheckBox

func _ready():
	close_button.pressed.connect(hide)
	quit_button.pressed.connect(_on_quit_pressed)
	# Raw keys, not tr()-resolved here — Localization.retranslate_tree() (called by
	# our parent scene's own _ready(), since we're instantiated as a child) is what
	# actually resolves these, and re-resolves them again on every live language
	# switch. Pre-resolving here would cache the English text as the "key" on first
	# sight and silently break every subsequent switch — see retranslate_tree()'s doc.
	tabs.set_tab_title(0, "SETTINGS_TAB_AUDIO")
	tabs.set_tab_title(1, "SETTINGS_TAB_VIDEO")
	tabs.set_tab_title(2, "SETTINGS_TAB_INPUT")
	tabs.set_tab_title(3, "SETTINGS_TAB_VOICE")
	_build_audio_tab()
	_build_video_tab()
	_build_input_tab()
	_build_voice_tab()

func _unhandled_input(event: InputEvent):
	if _rebinding_action == &"":
		return
	if (event is InputEventKey and event.pressed and not event.echo) \
			or (event is InputEventMouseButton and event.pressed):
		SettingsManager.rebind_action(_rebinding_action, event)
		if _rebind_button:
			_rebind_button.text = _format_events(SettingsManager.get_action_events(_rebinding_action))
		_rebinding_action = &""
		_rebind_button = null
		get_viewport().set_input_as_handled()

## Cleanly leaves any active connection before quitting, so the server (if any)
## sees a proper disconnect rather than a timeout.
func _on_quit_pressed():
	if multiplayer.has_multiplayer_peer() and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		NetworkManager.leave_game()
	get_tree().quit()

# --- Audio ---------------------------------------------------------------------

func _build_audio_tab():
	for i in range(AudioServer.bus_count):
		var bus_name := AudioServer.get_bus_name(i)
		var slider := HSlider.new()
		slider.min_value = -40.0
		slider.max_value = 6.0
		slider.step = 0.5
		slider.value = SettingsManager.get_bus_volume_db(bus_name)
		# drag_ended fires once on release, not per-tick — bus volume has no
		# encoder-rebuild cost like voice settings do, but there's still no reason
		# to hammer ConfigFile.save() on every pixel of slider movement.
		slider.drag_ended.connect(func(_changed): SettingsManager.set_bus_volume_db(bus_name, slider.value))
		# Bus names are project-defined identifiers (e.g. "Master"), not part of
		# the translation table — retranslate_tree() only touches recognized
		# keys, so this is shown as-is with no special-casing needed here.
		audio_tab.add_child(_labeled(bus_name, slider))

# --- Video -----------------------------------------------------------------------

func _build_video_tab():
	var fullscreen_check := CheckBox.new()
	fullscreen_check.text = "SETTINGS_FULLSCREEN"
	fullscreen_check.button_pressed = SettingsManager.get_fullscreen()
	fullscreen_check.toggled.connect(SettingsManager.set_fullscreen)
	video_tab.add_child(fullscreen_check)

	var language_option := OptionButton.new()
	# Reflects whatever locale files actually loaded this run (see
	# Localization.get_available_locales()'s doc) — not a hardcoded list, so a
	# language becomes selectable the moment its file is dropped in, and quietly
	# stops appearing if that file is removed, with no code change either way.
	var locale_codes := Localization.get_available_locales().keys()
	for locale in locale_codes:
		# Each locale's own display name comes from ITS OWN file, so the dropdown
		# always shows entries in their own language rather than in whatever
		# locale happens to be currently active.
		language_option.add_item(Localization.get_available_locales()[locale])
	if locale_codes.is_empty():
		language_option.disabled = true  # nothing loaded — see Localization's fail-safe doc
	else:
		var current_index: int = locale_codes.find(SettingsManager.get_locale())
		if current_index != -1:
			language_option.select(current_index)
		language_option.item_selected.connect(func(index: int): SettingsManager.set_locale(locale_codes[index]))
	video_tab.add_child(_labeled("SETTINGS_LANGUAGE", language_option))

# --- Input -----------------------------------------------------------------------

func _build_input_tab():
	for action in SettingsManager.REMAPPABLE_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var row := HBoxContainer.new()

		var label := Label.new()
		# Action names are InputMap identifiers, not part of the translation
		# table — a project wanting translated action labels would add keys for
		# them and swap this line for label.text = "ACTION_" + String(action).upper().
		label.text = String(action)
		label.custom_minimum_size.x = 160
		row.add_child(label)

		var bind_button := Button.new()
		bind_button.text = _format_events(SettingsManager.get_action_events(action))
		bind_button.custom_minimum_size.x = 140
		bind_button.pressed.connect(_start_rebind.bind(action, bind_button))
		row.add_child(bind_button)

		var reset_button := Button.new()
		reset_button.text = "SETTINGS_RESET"
		reset_button.pressed.connect(func():
			SettingsManager.reset_action_to_default(action)
			bind_button.text = _format_events(SettingsManager.get_action_events(action))
		)
		row.add_child(reset_button)

		input_tab.add_child(row)

func _start_rebind(action: StringName, button: Button):
	_rebinding_action = action
	_rebind_button = button
	button.text = "SETTINGS_PRESS_A_KEY"

## Key names (InputEvent.as_text()) come from the OS/hardware, not the
## translation table — only the "(unbound)" fallback needs translating.
##
## Returns already-resolved text (explicit tr()), not a raw key, unlike
## everywhere else in this file — this result is mixed content (sometimes a
## real key name, sometimes the "unbound" message) assigned outside
## retranslate_tree()'s sweep (from _unhandled_input on a live rebind, from the
## Reset button's callback), so it can't use the key-then-retranslate pattern.
## Known, narrow, accepted limitation: an action showing "(unbound)" won't
## retroactively relabel on a pure language switch — only on its next rebind —
## same class of gap as lobby.gd's status_label/ready_button, and just as rare
## in practice (every REMAPPABLE_ACTIONS entry ships with a default binding).
func _format_events(events: Array) -> String:
	if events.is_empty():
		return tr("SETTINGS_UNBOUND")
	var parts: Array = []
	for e in events:
		parts.append(e.as_text() if e is InputEvent else str(e))
	return " / ".join(parts)

# --- Voice -------------------------------------------------------------------------
# Every field here except playback volume rebuilds the Opus encoder on apply — see
# SettingsManager's Voice section doc. That's why this tab has one explicit "Apply"
# button rather than each control applying itself on change.

func _build_voice_tab():
	_device_option = OptionButton.new()
	for d in AudioServer.get_input_device_list():
		# Device names come from the OS, not the translation table — see the
		# audio bus note above.
		_device_option.add_item(d)
	var current_device := SettingsManager.get_voice_device()
	for i in range(_device_option.item_count):
		if _device_option.get_item_text(i) == current_device:
			_device_option.select(i)
	voice_tab.add_child(_labeled("SETTINGS_INPUT_DEVICE", _device_option))

	# Raw keys, not tr()-resolved — see the tab-title comment in _ready() for why;
	# Localization.retranslate_tree() resolves OptionButton items too, but only if
	# what it finds is the actual key, not an already-resolved English string.
	_activation_option = OptionButton.new()
	_activation_option.add_item("SETTINGS_VOICE_ACTIVITY", VoipConfig.ActivationMode.VOICE_ACTIVITY)
	_activation_option.add_item("SETTINGS_PUSH_TO_TALK", VoipConfig.ActivationMode.PUSH_TO_TALK)
	_activation_option.add_item("SETTINGS_OPEN_MIC", VoipConfig.ActivationMode.OPEN_MIC)
	_activation_option.select(_activation_option.get_item_index(SettingsManager.get_voice_activation_mode()))
	voice_tab.add_child(_labeled("SETTINGS_ACTIVATION_MODE", _activation_option))

	_vox_slider = HSlider.new()
	_vox_slider.min_value = 0.0
	_vox_slider.max_value = 1.0
	_vox_slider.step = 0.01
	_vox_slider.value = SettingsManager.get_voice_vox_threshold()
	voice_tab.add_child(_labeled("SETTINGS_VOX_THRESHOLD", _vox_slider))

	_gain_slider = HSlider.new()
	_gain_slider.min_value = 0.0
	_gain_slider.max_value = 4.0
	_gain_slider.step = 0.05
	_gain_slider.value = SettingsManager.get_voice_microphone_gain()
	voice_tab.add_child(_labeled("SETTINGS_MIC_GAIN", _gain_slider))

	_denoise_check = CheckBox.new()
	_denoise_check.text = "SETTINGS_DENOISE"
	_denoise_check.button_pressed = SettingsManager.get_voice_denoise()
	voice_tab.add_child(_denoise_check)

	var playback_slider := HSlider.new()
	playback_slider.min_value = -24.0
	playback_slider.max_value = 12.0
	playback_slider.step = 0.5
	playback_slider.value = SettingsManager.get_voice_playback_volume_db()
	# The one voice setting safe to apply live — see set_voice_playback_volume_db's doc.
	playback_slider.value_changed.connect(SettingsManager.set_voice_playback_volume_db)
	voice_tab.add_child(_labeled("SETTINGS_PLAYBACK_VOLUME", playback_slider))

	var apply_button := Button.new()
	apply_button.text = "SETTINGS_APPLY_VOICE"
	apply_button.pressed.connect(_on_apply_voice_pressed)
	voice_tab.add_child(apply_button)

func _on_apply_voice_pressed():
	SettingsManager.set_voice_device(_device_option.get_item_text(_device_option.selected))
	SettingsManager.set_voice_activation_mode(_activation_option.get_selected_id() as VoipConfig.ActivationMode)
	SettingsManager.set_voice_vox_threshold(_vox_slider.value)
	SettingsManager.set_voice_microphone_gain(_gain_slider.value)
	SettingsManager.set_voice_denoise(_denoise_check.button_pressed)

## `text` may be a translation key or an already-final string (a bus/device
## name) — Localization.retranslate_tree() only touches recognized keys, so
## either is safe to pass without the caller needing to distinguish them.
func _labeled(text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 160
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row
