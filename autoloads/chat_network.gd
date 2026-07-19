extends Node
## Chat transport: the only chat piece that knows about multiplayer. Same split
## as VoipNetwork vs VoipMicrophone/VoipSpeaker — this owns RPCs, sanitization,
## and delivery; it has no idea what a "lobby" or "phone" is, and no UI logic
## of its own. A UI (ChatUI, or a future phone/DM panel) calls send_message()
## and listens to message_received(), same shape as VoicePanel/AdminPanel
## calling into VoipNetwork/NetworkManager rather than owning that logic itself.
##
## "channel" is just a caller-defined String key (e.g. "lobby", or
## "phone:<peer_id>" for a DM) — this file never branches on its value itself.

signal message_received(channel: String, sender_id: int, text: String)

## Server only. Decides who receives a message sent to a given channel.
## Signature: (channel: String, sender_id: int) -> Array. Left unset (the
## default, an invalid Callable), every connected peer (and the server itself)
## receives everything — today's lobby-chat behavior. A phone feature would set
## this to its own "are these two peers in this conversation" logic — same
## pattern as VoipNetwork.voice_relevance, keeping this file ignorant of what a
## "contact" or "conversation" even is.
var channel_recipients: Callable

## UI-facing entry point. Fire-and-forget; the server echoes the (sanitized)
## result back via message_received for anyone who's meant to see it, sender
## included — nobody renders their own message optimistically off this call.
func send_message(channel: String, text: String):
	if text.is_empty():
		return
	if multiplayer.is_server():
		# rpc_id(1, ...) targeting your own peer id is refused outright by Godot
		# (ERR_INVALID_PARAMETER) for a call_remote RPC — same issue as
		# kick_peer's self-kick — so the host calls the server logic directly,
		# same shape as AdminPanel's kick/ban handlers.
		_process_send(multiplayer.get_unique_id(), channel, text)
	else:
		_request_send.rpc_id(1, channel, text)

@rpc("any_peer", "call_remote", "reliable")
func _request_send(channel: String, text: String):
	if not multiplayer.is_server():
		return
	_process_send(multiplayer.get_remote_sender_id(), channel, text)

func _process_send(sender_id: int, channel: String, text: String):
	# Sanitize user input so they can't inject malicious rich text tags!
	var safe_text := text.replace("[", "").replace("]", "")

	var recipients: Array = channel_recipients.call(channel, sender_id) if channel_recipients.is_valid() else _everyone()
	for peer_id in recipients:
		if peer_id == multiplayer.get_unique_id():
			# Same self-target issue as above, on the delivery side this time.
			_deliver(channel, sender_id, safe_text)
		else:
			_deliver.rpc_id(peer_id, channel, sender_id, safe_text)

	ServerConsole.log_chat_message(sender_id, safe_text)

## Every id that could conceivably be listening: every connected peer, plus the
## server's own local playback — same helper shape as VoipNetwork._listener_candidates().
func _everyone() -> Array:
	var recipients := multiplayer.get_peers()
	recipients.append(multiplayer.get_unique_id())
	return recipients

@rpc("authority", "call_remote", "reliable")
func _deliver(channel: String, sender_id: int, text: String):
	message_received.emit(channel, sender_id, text)
