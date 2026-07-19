extends VBoxContainer
class_name ChatUI

@onready var chat_box = $ChatBox
@onready var chat_input = $ChatInput

func _ready():
	chat_input.text_submitted.connect(_on_chat_input_submitted)
	EventBus.system_message_received.connect(_on_system_message)
	EventBus.clear_chat.connect(_on_clear_chat)

func _on_chat_input_submitted(new_text: String):
	if new_text.is_empty():
		return
		
	if multiplayer.has_multiplayer_peer():
		receive_chat_request.rpc_id(1, new_text)
	else:
		_on_system_message("\n[color=red][i]" + tr("MSG_NOT_CONNECTED") + "[/i][/color]")
		
	chat_input.text = ""

@rpc("any_peer", "call_local")
func receive_chat_request(message: String):
	if not multiplayer.is_server():
		return
		
	var sender_id = multiplayer.get_remote_sender_id()
	
	# Sanitize user input so they can't inject malicious rich text tags!
	var safe_message = message.replace("[", "").replace("]", "")
	
	receive_chat.rpc(sender_id, safe_message)

@rpc("authority", "call_local")
func receive_chat(sender_id: int, message: String):
	var sender_name = tr("MSG_PLAYER_FALLBACK_NAME") % sender_id
	if PlayerManager.players.has(sender_id):
		sender_name = PlayerManager.players[sender_id]["name"]
		
	var color = "lightblue"
	if sender_id == 1:
		color = "yellow"
	if sender_id == multiplayer.get_unique_id():
		color = "green"
		
	chat_box.append_text("\n[color=" + color + "]" + sender_name + ":[/color] " + message)

func _on_system_message(msg: String):
	chat_box.append_text(msg)
	
func _on_clear_chat():
	chat_box.clear()
