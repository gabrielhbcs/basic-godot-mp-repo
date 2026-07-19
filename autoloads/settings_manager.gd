extends Node
## Persists user-configurable settings across sessions (user://settings.cfg) and
## applies them to the relevant systems (AudioServer, DisplayServer, InputMap,
## VoipNetwork.config). A settings UI stages changes locally and calls the set_*
## functions below on confirm — nothing here runs per-frame or per-slider-tick;
## every apply is one explicit, deliberate call.
##
## Design note: VoipNetwork.config is a *runtime* Resource (see voip_network.gd) —
## these voice setters mutate that instance directly rather than the design-time
## .tres, and several of them rebuild the Opus encoder (see the warning on the
## Voice section below). That's why voice settings are per-field setters a UI
## calls on release/confirm, not something safe to bind to value_changed directly.

const SETTINGS_PATH := "user://settings.cfg"

## Actions a settings UI is expected to expose for rebinding. Godot's own built-in
## actions (ui_*) and anything outside this list are deliberately left alone —
## letting a player remap "confirm dialog" because it happens to double as a
## gameplay key is a footgun, not a feature.
const REMAPPABLE_ACTIONS: Array[StringName] = [
	&"move_up", &"move_down", &"move_left", &"move_right",
	&"voip_push_to_talk", &"voip_toggle_mute",
]

var _cfg := ConfigFile.new()

func _ready():
	_cfg.load(SETTINGS_PATH)  # missing/unreadable file just means empty -> defaults apply
	apply_all()

## Re-applies every stored setting. Called once at startup; a settings UI never
## needs to call this itself — use the individual set_* functions instead.
func apply_all():
	apply_audio_settings()
	apply_video_settings()
	apply_input_settings()
	apply_voice_settings()

func _save():
	var err := _cfg.save(SETTINGS_PATH)
	if err != OK:
		push_warning("SettingsManager: failed to save settings (error %d)" % err)

# --- Audio (bus volumes) -------------------------------------------------------
# Generic over however many buses the project defines — never hardcodes "Master"
# specifically, so a game that adds more buses gets them for free.

func get_bus_volume_db(bus_name: String) -> float:
	return _cfg.get_value("audio", bus_name, 0.0)

func set_bus_volume_db(bus_name: String, volume_db: float):
	_cfg.set_value("audio", bus_name, volume_db)
	_save()
	_apply_bus_volume(bus_name, volume_db)

func apply_audio_settings():
	for i in range(AudioServer.bus_count):
		var bus_name := AudioServer.get_bus_name(i)
		_apply_bus_volume(bus_name, get_bus_volume_db(bus_name))

func _apply_bus_volume(bus_name: String, volume_db: float):
	var idx := AudioServer.get_bus_index(bus_name)
	if idx != -1:
		AudioServer.set_bus_volume_db(idx, volume_db)

# --- Video -----------------------------------------------------------------------

func get_fullscreen() -> bool:
	return _cfg.get_value("video", "fullscreen", false)

func set_fullscreen(enabled: bool):
	_cfg.set_value("video", "fullscreen", enabled)
	_save()
	apply_video_settings()

func get_window_size() -> Vector2i:
	return _cfg.get_value("video", "window_size", DisplayServer.window_get_size())

func set_window_size(size: Vector2i):
	_cfg.set_value("video", "window_size", size)
	_save()
	apply_video_settings()

func apply_video_settings():
	if get_fullscreen():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(get_window_size())

# --- Language --------------------------------------------------------------------
# Read by localization.gd at startup (it must run after SettingsManager — see
# project.godot's autoload order) and applied live by set_locale() thereafter.

func get_locale() -> String:
	return _cfg.get_value("general", "locale", "en")

func set_locale(locale: String):
	_cfg.set_value("general", "locale", locale)
	_save()
	TranslationServer.set_locale(locale)
	Localization.retranslate_tree(get_tree().root)  # live-updates whatever's on screen

# --- Input (keybinds) -------------------------------------------------------------

## Rebinds action to a single event, replacing whatever it currently had. Only
## actions in REMAPPABLE_ACTIONS may be rebound this way — see the const's doc.
func rebind_action(action: StringName, event: InputEvent):
	if not action in REMAPPABLE_ACTIONS:
		push_warning("SettingsManager: %s is not in REMAPPABLE_ACTIONS, ignoring rebind." % action)
		return
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, event)
	_cfg.set_value("input", str(action), event)
	_save()

func get_action_events(action: StringName) -> Array:
	return InputMap.action_get_events(action) if InputMap.has_action(action) else []

func apply_input_settings():
	# ConfigFile.get_value() treats an explicitly-passed null default the same as
	# "no default provided" and errors if the key is missing — so existence has to
	# be checked explicitly rather than relying on a null-default sentinel.
	for action in REMAPPABLE_ACTIONS:
		if not InputMap.has_action(action):
			continue
		if not _cfg.has_section_key("input", str(action)):
			continue
		var event = _cfg.get_value("input", str(action))
		if event is InputEvent:
			InputMap.action_erase_events(action)
			InputMap.action_add_event(action, event)

## Drops the stored override and reloads that action's original project.godot
## binding — InputMap doesn't remember its own defaults once action_erase_events()
## has run, so "reset" means re-reading project.godot itself, not undoing in memory.
func reset_action_to_default(action: StringName):
	_cfg.erase_section_key("input", str(action))
	_save()
	InputMap.load_from_project_settings()
	apply_input_settings()  # re-apply every OTHER stored override load_from_project_settings just wiped

# --- Voice -------------------------------------------------------------------------
# Every setter below (other than playback volume) rebuilds the Opus encoder via
# VoipMicrophone.apply_config(), which ENDS any active talk burst. A settings UI
# must call these on release/confirm, never on every slider tick, or a live
# speaker gets cut off mid-word on every frame the slider moves.

func get_voice_device() -> String:
	return _cfg.get_value("voice", "input_device", "Default")

func set_voice_device(device: String):
	_cfg.set_value("voice", "input_device", device)
	_save()
	VoipNetwork.set_input_device(device)  # handles the deactivate/reactivate dance itself

func get_voice_activation_mode() -> VoipConfig.ActivationMode:
	return _cfg.get_value("voice", "activation_mode", VoipConfig.ActivationMode.VOICE_ACTIVITY) as VoipConfig.ActivationMode

func set_voice_activation_mode(mode: VoipConfig.ActivationMode):
	_cfg.set_value("voice", "activation_mode", mode)
	_save()
	VoipNetwork.config.activation_mode = mode
	VoipNetwork.microphone.apply_config()

func get_voice_vox_threshold() -> float:
	return _cfg.get_value("voice", "vox_threshold", VoipNetwork.config.vox_threshold)

func set_voice_vox_threshold(threshold: float):
	_cfg.set_value("voice", "vox_threshold", threshold)
	_save()
	VoipNetwork.config.vox_threshold = threshold
	VoipNetwork.microphone.apply_config()

func get_voice_microphone_gain() -> float:
	return _cfg.get_value("voice", "microphone_gain", VoipNetwork.config.microphone_gain)

func set_voice_microphone_gain(gain: float):
	_cfg.set_value("voice", "microphone_gain", gain)
	_save()
	VoipNetwork.config.microphone_gain = gain
	VoipNetwork.microphone.apply_config()

func get_voice_denoise() -> bool:
	return _cfg.get_value("voice", "denoise", VoipNetwork.config.denoise)

func set_voice_denoise(enabled: bool):
	_cfg.set_value("voice", "denoise", enabled)
	_save()
	VoipNetwork.config.denoise = enabled
	VoipNetwork.microphone.apply_config()

func get_voice_playback_volume_db() -> float:
	return _cfg.get_value("voice", "playback_volume_db", VoipNetwork.config.playback_volume_db)

## The one voice setting safe to apply live: playback volume isn't an encoder
## parameter (VoipSpeaker reads it on demand — see _apply_volume()), so this
## never touches apply_config() and never interrupts anything mid-stream.
func set_voice_playback_volume_db(volume_db: float):
	_cfg.set_value("voice", "playback_volume_db", volume_db)
	_save()
	VoipNetwork.config.playback_volume_db = volume_db

func apply_voice_settings():
	VoipNetwork.config.activation_mode = get_voice_activation_mode()
	VoipNetwork.config.vox_threshold = get_voice_vox_threshold()
	VoipNetwork.config.microphone_gain = get_voice_microphone_gain()
	VoipNetwork.config.denoise = get_voice_denoise()
	VoipNetwork.config.playback_volume_db = get_voice_playback_volume_db()
	VoipNetwork.microphone.apply_config()
	# "Default" is itself a real device name Godot understands (see
	# AudioServer.get_input_device_list()), not a sentinel meaning "skip" — no
	# special-casing needed, same as set_voice_device().
	VoipNetwork.set_input_device(get_voice_device())
