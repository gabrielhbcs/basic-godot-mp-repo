extends VBoxContainer
class_name ChatUI
## Thin subscriber over ChatNetwork — same shape as VoicePanel/AdminPanel over
## VoipNetwork/NetworkManager. Owns no RPCs and no sanitization of its own;
## just renders whatever ChatNetwork.message_received hands it for the "lobby"
## channel, and forwards submitted text to ChatNetwork.send_message(). A future
## phone/DM UI would be a separate script doing the same thing for its own
## channel, without either one needing to know the other exists.

const CHANNEL := "lobby"

@onready var chat_box = $ChatBox
@onready var chat_input = $ChatInput

func _ready():
	chat_input.text_submitted.connect(_on_chat_input_submitted)
	ChatNetwork.message_received.connect(_on_message_received)
	EventBus.system_message_received.connect(_on_system_message)
	EventBus.clear_chat.connect(_on_clear_chat)

func _on_chat_input_submitted(new_text: String):
	if new_text.is_empty():
		return

	if multiplayer.has_multiplayer_peer():
		ChatNetwork.send_message(CHANNEL, new_text)
	else:
		_on_system_message("\n[color=red][i]" + tr("MSG_NOT_CONNECTED") + "[/i][/color]")

	chat_input.text = ""

func _on_message_received(channel: String, sender_id: int, text: String):
	if channel != CHANNEL:
		return

	var sender_name = tr("MSG_PLAYER_FALLBACK_NAME") % sender_id
	if PlayerManager.players.has(sender_id):
		sender_name = PlayerManager.players[sender_id]["name"]

	var color = "lightblue"
	if sender_id == 1:
		color = "yellow"
	if sender_id == multiplayer.get_unique_id():
		color = "green"

	chat_box.append_text("\n[color=" + color + "]" + sender_name + ":[/color] " + text)

func _on_system_message(msg: String):
	chat_box.append_text(msg)

func _on_clear_chat():
	chat_box.clear()
