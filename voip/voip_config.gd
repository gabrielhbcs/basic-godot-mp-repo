class_name VoipConfig
extends Resource
## All tunable VOIP parameters in one shareable resource.
##
## The default instance lives at res://voip/default_voip_config.tres. Future projects
## built on this template can duplicate that file (or create variants per game mode)
## and assign it to VoipNetwork / VoipMicrophone / VoipSpeaker without touching code.

enum ActivationMode {
	VOICE_ACTIVITY, ## Transmit automatically while the input level is above vox_threshold.
	PUSH_TO_TALK,   ## Transmit while push_to_talk_action (or VoipMicrophone.ptt_pressed) is held.
	OPEN_MIC,       ## Transmit continuously while unmuted.
}

@export_group("Opus Encoding")
## Opus output sample rate. Must be one of 8000, 12000, 16000, 24000, 48000.
## Mic input is explicitly resampled to this fixed rate regardless of hardware rate.
@export var opus_sample_rate: int = 48000
## Opus frame duration in milliseconds. Valid: 2.5, 5, 10, 20, 40, 60.
@export var frame_duration_ms: float = 20.0
## 1 = mono, 2 = stereo. Mono halves bandwidth and is usually enough for voice.
@export_range(1, 2) var channels: int = 2
## Target bitrate in bits/second. 12000 is intelligible speech; raise for quality.
@export var bitrate: int = 12000
## Opus encoder complexity (CPU vs quality trade-off).
@export_range(0, 10) var complexity: int = 5
## Tune the encoder for speech instead of general audio.
@export var optimize_for_voice: bool = true

@export_group("Capture")
## Run RNNoise denoising on captured audio before encoding.
@export var denoise: bool = true
## Linear gain applied to the mic signal at encode time.
@export var microphone_gain: float = 1.0

@export_group("Transmission")
@export var activation_mode: ActivationMode = ActivationMode.VOICE_ACTIVITY
## Input level (0-1) above which voice activity triggers transmission.
@export_range(0.0, 1.0) var vox_threshold: float = 0.05
## Seconds to keep transmitting after the level drops below vox_threshold.
@export var vox_hang_time: float = 0.7

@export_group("Input Actions")
## InputMap action held to talk in PUSH_TO_TALK mode. Ignored if the action doesn't exist.
@export var push_to_talk_action: StringName = &"voip_push_to_talk"
## InputMap action that toggles the mic mute. Ignored if the action doesn't exist.
@export var mute_toggle_action: StringName = &"voip_toggle_mute"

@export_group("Playback")
## Extra volume applied to the receiving AudioStreamPlayer, in dB.
@export var playback_volume_db: float = 0.0
## Target buffered playback latency in seconds. Lower = snappier but more fragile
## to jitter. The speaker time-warps playback (pitch_scale) to hold this target.
@export var buffer_lag_target: float = 0.6
## Allowed deviation from buffer_lag_target before drift compensation kicks in.
@export var buffer_lag_tolerance: float = 0.35

@export_group("Positional Audio")
## Only applies when the speaker plays through an AudioStreamPlayer2D/3D — ignored
## for plain (non-positional) AudioStreamPlayer.
##
## VoipSpeaker drives this curve itself rather than relying on the engine's built-in
## distance attenuation: Godot's own curve starts fading the instant you move away
## from distance 0, which gives no plateau — voice quietens even at close range.
## This gives the plateau-then-fade shape real proximity voice chat wants: full
## volume out to fade_start_distance, then a fade down to silent by max_distance.
## The engine's own attenuation is disabled on the player node (attenuation = 0) so
## the two curves don't stack.

## Distance (px for 2D, units for 3D) within which a speaker is at full volume.
@export var fade_start_distance: float = 250.0
## Distance beyond which a speaker is inaudible. Must be > fade_start_distance.
## This is purely the client's perceptual fade; if the game also does server-side
## proximity culling (VoipNetwork.voice_relevance), keep that cutoff distance >= this
## one, or the server will drop packets before this fade ever gets a say.
@export var max_distance: float = 1000.0
## Shapes the fade between fade_start_distance and max_distance: 1.0 = linear (in
## dB), <1.0 = fades faster near fade_start_distance, >1.0 = stays louder longer
## before dropping off sharply near max_distance.
@export var attenuation: float = 1.0
