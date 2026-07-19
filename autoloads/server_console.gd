extends Node
## Lets whoever's running a dedicated server type admin commands into the
## terminal — the text-mode equivalent of AdminPanel's Kick/Ban buttons. Calls
## the exact same NetworkManager/PlayerManager functions those buttons do; it
## has no enforcement logic of its own, same reasoning as AdminPanel's own doc
## comment. Only ever active on a dedicated server (see _ready()) — a normal
## windowed client/host has no terminal for a player to type into, and blocking
## on stdin in that case would just be a thread doing nothing forever.
##
## Reading stdin blocks, so it runs on its own Thread; commands are marshaled
## back to the main thread via call_deferred() (safe to call from any thread)
## rather than touching NetworkManager/PlayerManager directly off-thread.

var _thread: Thread

func _ready():
	if not OS.has_feature("headless"):
		return
	print("Server console ready. Type 'help' for commands.")
	_thread = Thread.new()
	_thread.start(_stdin_loop)

## Runs on _thread. Deliberately never joined/stopped on exit — read_string_from_stdin()
## blocks until a line arrives, so there's no clean way to wake it up early; the
## whole process exiting (Ctrl+C, or closing the console window) takes this
## thread down with it, same as it would for any blocking console app.
func _stdin_loop():
	while true:
		var line := OS.read_string_from_stdin().strip_edges()
		if not line.is_empty():
			call_deferred("_handle_command", line)

func _handle_command(line: String):
	var parts := line.split(" ", false)
	var cmd := parts[0].to_lower()
	var args := parts.slice(1)
	match cmd:
		"help":
			print("Commands: list | kick <peer_id> | ban <peer_id> | unban_uuid <uuid> | unban_ip <ip>")
		"list":
			if PlayerManager.players.is_empty():
				print("  (no players connected)")
			for id in PlayerManager.players:
				print("  [%d] %s" % [id, PlayerManager.players[id].get("name", "?")])
		"kick":
			_with_peer_id(args, func(id): NetworkManager.kick_peer(id, "KICK_REASON_REMOVED", 1))
		"ban":
			_with_peer_id(args, func(id): NetworkManager.ban_peer(id, "KICK_REASON_BANNED", 1))
		"unban_uuid":
			if args.is_empty():
				print("Usage: unban_uuid <uuid>")
			else:
				NetworkManager.unban_uuid(args[0])
				print("Unbanned uuid ", args[0])
		"unban_ip":
			if args.is_empty():
				print("Usage: unban_ip <ip>")
			else:
				NetworkManager.unban_ip(args[0])
				print("Unbanned ip ", args[0])
		_:
			print("Unknown command '", cmd, "' — try 'help'")

func _with_peer_id(args: PackedStringArray, action: Callable):
	if args.is_empty() or not args[0].is_valid_int():
		print("Usage: <peer_id> — see 'list' for connected peer ids")
		return
	action.call(int(args[0]))

## Plain function, not an RPC — ChatNetwork._request_send() already runs
## server-side (see its own is_server() guard) and has sender_id/message in
## hand right there, in the same process as this autoload. No network hop
## needed; called directly from there rather than trying to RPC into it.
func log_chat_message(sender_id: int, message: String):
	var sender_name = tr("MSG_PLAYER_FALLBACK_NAME") % sender_id
	if PlayerManager.players.has(sender_id):
		sender_name = PlayerManager.players[sender_id]["name"]

	print("[CHAT] " + sender_name + "("+ str(sender_id) +"): " + message)