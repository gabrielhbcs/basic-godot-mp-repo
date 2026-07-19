class_name VoipMicrophone
extends Node
## Captures microphone audio and encodes it into Opus voice-stream packets.
##
## Transport-agnostic: this node never touches the network. It emits the three
## packet signals below and whoever owns it (VoipNetwork in this template) wires
## them into RPCs. Header/footer packets must be delivered reliably; frame
## packets should go over an unreliable channel.
##
## Capture deliberately uses AudioServer.get_input_frames() (the Godot 4.6 input
## API) and AudioServer.get_input_mix_rate() as the resampler source rate. Do NOT
## replace this with AudioStreamMicrophone + AudioEffectCapture: that path runs
## the mic through the *output* mixer and its clock, which corrupts the capture
## rate behind virtual audio devices (SteelSeries Sonar etc.) — the exact bug
## that killed the previous hand-rolled VOIP system in this project.

## Stream header, sent once when a talk burst starts. Deliver reliably.
signal header_ready(header: Dictionary)
## One encoded Opus frame (with 2-byte sequence prefix). Deliver unreliably.
signal frame_ready(packet: PackedByteArray, frame_index: int)
## Stream footer, sent once when a talk burst ends. Deliver reliably.
signal footer_ready(footer: Dictionary)

## Post-denoise input level of the latest captured chunk (0-1). Fires while
## capture is active regardless of transmission state — drive level meters here.
signal level_changed(level: float)
signal transmitting_changed(transmitting: bool)
signal mute_changed(muted: bool)

@export var config: VoipConfig

## While false the mic device is released and no audio is processed.
## VoipNetwork flips this with the multiplayer connection state.
var capture_enabled: bool = false: set = set_capture_enabled

var muted: bool = false: set = set_muted
## UI hook for an on-screen push-to-talk button; OR'd with the InputMap action.
var ptt_pressed: bool = false

var transmitting: bool = false
var level: float = 0.0

const CHUNK_PREFIX_LEN := 2

var _encoder: TwovoipOpusEncoder
## Input rate the resampler was last built against. The device's rate is only
## trustworthy once the device is *active*, and it can change afterwards, so this
## is tracked and re-checked rather than sampled once at startup. See _rebuild_sampler().
var _sampler_input_rate: float = 0.0
var _chunk_prefix := PackedByteArray([0, 0])
var _opus_frame_size: int = 960   # samples per Opus frame at opus_sample_rate
var _frame_time: float = 0.02
var _frame_index: int = 0
var _stream_index: int = 0
var _talk_start: float = 0.0
var _vox_active: bool = false
var _hang_frames: int = 35
var _hang_countup: int = 0

func _ready():
	if config == null:
		config = VoipConfig.new()
	apply_config()
	set_process(capture_enabled)

## (Re)creates the resampler + encoder from the current config. Call after
## changing encoding-related config values at runtime. Ends any active stream.
func apply_config():
	_set_stream_active(false)
	_encoder = TwovoipOpusEncoder.new()
	_encoder.create_opus_encoder(config.bitrate, config.complexity, config.optimize_for_voice)
	_opus_frame_size = int(config.opus_sample_rate * config.frame_duration_ms / 1000.0)
	_frame_time = config.frame_duration_ms / 1000.0
	_hang_frames = int(ceil(config.vox_hang_time / _frame_time))
	_rebuild_sampler()

## Rebuilds the resampler against the input device's *current* rate.
##
## Split out of apply_config() deliberately: get_input_mix_rate() only reports the
## real device rate once the device is active, and apply_config() runs from _ready(),
## long before activation. Building the sampler with a wrong *source* rate does not
## fail loudly — it silently pitch-shifts every packet (the chipmunk/slow-motion
## artifact documented in plan-voip.md). So the rate is (re)read at activation, on
## device switches, and whenever it changes underneath us.
func _rebuild_sampler():
	if _encoder == null:
		return
	_set_stream_active(false)  # a mid-stream sampler swap would corrupt the burst
	_sampler_input_rate = AudioServer.get_input_mix_rate()
	_encoder.create_sampler(_sampler_input_rate, config.opus_sample_rate, config.channels, config.denoise)

func set_capture_enabled(value: bool):
	if capture_enabled == value:
		return
	capture_enabled = value
	if value:
		_activate_input_device()
	else:
		_set_stream_active(false)
		_vox_active = false
		level = 0.0
		AudioServer.set_input_device_active(false)
	set_process(capture_enabled)

func set_muted(value: bool):
	if muted == value:
		return
	muted = value
	mute_changed.emit(muted)

func toggle_mute():
	set_muted(not muted)

## Switches the OS input device, handling the deactivate/reactivate dance
## required while capture is running.
func set_input_device(device_name: String):
	var was_active := capture_enabled
	if was_active:
		set_capture_enabled(false)
	AudioServer.set_input_device(device_name)
	if was_active:
		set_capture_enabled(true)

func _activate_input_device():
	if OS.get_name() == "Android" and not OS.request_permission("android.permission.RECORD_AUDIO"):
		_await_android_permission()
		return
	var err := AudioServer.set_input_device_active(true)
	if err != OK:
		push_warning("VoipMicrophone: could not activate input device (error %d)" % err)
		return
	# Only now does get_input_mix_rate() describe the device we are about to read.
	_rebuild_sampler()

func _await_android_permission():
	@warning_ignore("untyped_declaration")
	var result = await get_tree().on_request_permissions_result
	if result[0] == "android.permission.RECORD_AUDIO" and result[1] and capture_enabled:
		var err := AudioServer.set_input_device_active(true)
		if err != OK:
			push_warning("VoipMicrophone: could not activate input device (error %d)" % err)
			return
		_rebuild_sampler()

func _wants_to_transmit() -> bool:
	if muted:
		return false
	match config.activation_mode:
		VoipConfig.ActivationMode.OPEN_MIC:
			return true
		VoipConfig.ActivationMode.PUSH_TO_TALK:
			var action_held := InputMap.has_action(config.push_to_talk_action) \
					and Input.is_action_pressed(config.push_to_talk_action)
			return ptt_pressed or action_held
		VoipConfig.ActivationMode.VOICE_ACTIVITY:
			return _vox_active
	return false

func _process(_delta):
	# The input rate can change without going through set_input_device() — the user
	# switches the OS default device, or a virtual device (Sonar etc.) renegotiates.
	# A stale source rate corrupts pitch silently, so verify rather than assume.
	if not is_equal_approx(AudioServer.get_input_mix_rate(), _sampler_input_rate):
		_rebuild_sampler()
	# Stream start/stop transitions happen once per frame, before draining the
	# capture buffer — same ordering as upstream twovoip's reference mic script.
	_set_stream_active(_wants_to_transmit())
	while true:
		var audio_chunk = AudioServer.get_input_frames(_encoder.calc_audio_chunk_size(_opus_frame_size))
		if len(audio_chunk) == 0:
			break
		var chunk_max: float = _encoder.process_pre_encoded_chunk(audio_chunk, _opus_frame_size, config.denoise, false)
		level = chunk_max
		level_changed.emit(chunk_max)
		_update_vox(chunk_max)
		if transmitting:
			_encode_and_emit_frame()

func _update_vox(chunk_max: float):
	if chunk_max >= config.vox_threshold:
		_vox_active = true
		_hang_countup = 0
	elif _vox_active:
		_hang_countup += 1
		if _hang_countup >= _hang_frames:
			_vox_active = false

func _set_stream_active(talking: bool):
	if talking and not transmitting:
		_talk_start = Time.get_ticks_msec() * 0.001
		_frame_index = 0
		_encoder.reset_opus_encoder()
		header_ready.emit({
			"opusframesize": _opus_frame_size,
			"opussamplerate": config.opus_sample_rate,
			"opuschannels": config.channels,
			"lenchunkprefix": CHUNK_PREFIX_LEN,
			"opusstreamcount": _stream_index,
			"opusframecount": 0,
			"talkingtimestart": _talk_start,
		})
		transmitting = true
		transmitting_changed.emit(true)
	elif not talking and transmitting:
		var talk_end := Time.get_ticks_msec() * 0.001
		footer_ready.emit({
			"opusstreamcount": _stream_index,
			"opusframecount": _frame_index,
			"talkingtimeduration": talk_end - _talk_start,
			"talkingtimeend": talk_end,
		})
		_stream_index += 1
		transmitting = false
		transmitting_changed.emit(false)

func _encode_and_emit_frame():
	# 15-bit frame counter (wraps at ~10 min of continuous speech) plus a 1-bit
	# stream parity flag so receivers can drop stale frames from a previous burst.
	_chunk_prefix.set(0, _frame_index % 256)
	_chunk_prefix.set(1, (int(_frame_index / 256.0) & 127) + (_stream_index % 2) * 128)
	var packet: PackedByteArray = _encoder.encode_chunk(_chunk_prefix, config.microphone_gain)
	frame_ready.emit(packet, _frame_index)
	_frame_index += 1
