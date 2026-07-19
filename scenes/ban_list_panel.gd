class_name BanListPanel
extends Control
## Host-only view of NetworkManager's ban list (uuid + IP entries), with an
## Unban action. Purely UI — NetworkManager.unban_uuid()/unban_ip() already
## existed for this, there was just no way to reach them without hand-editing
## user://bans.cfg. Server-authoritative data, so this only makes sense for
## whoever is actually running as server — see Lobby wiring for the host-only
## gate, matching AdminPanel's pattern.

@export var ban_list: ItemList
@export var unban_button: Button
@export var close_button: Button

## Parallel to ban_list's rows: entry i here describes item i there. Kept
## alongside rather than derived from the label text, since the label is
## translated/formatted and not safe to parse back apart.
var _entries: Array[Dictionary] = []

func _ready():
	visible = false
	if close_button:
		close_button.pressed.connect(func(): visible = false)
	if unban_button:
		unban_button.pressed.connect(_on_unban_pressed)
		unban_button.disabled = true
	if ban_list:
		ban_list.item_selected.connect(func(_idx): unban_button.disabled = false)

func open():
	_refresh()
	visible = true

func _refresh():
	if not ban_list:
		return
	ban_list.clear()
	_entries.clear()
	if unban_button:
		unban_button.disabled = true
	for uuid in NetworkManager.get_banned_uuids():
		_entries.append({"type": "uuid", "value": uuid})
		ban_list.add_item(tr("BAN_ENTRY_UUID") % uuid)
	for ip in NetworkManager.get_banned_ips():
		_entries.append({"type": "ip", "value": ip})
		ban_list.add_item(tr("BAN_ENTRY_IP") % ip)

func _on_unban_pressed():
	var selected := ban_list.get_selected_items()
	if selected.is_empty():
		return
	var entry: Dictionary = _entries[selected[0]]
	if entry["type"] == "uuid":
		NetworkManager.unban_uuid(entry["value"])
	else:
		NetworkManager.unban_ip(entry["value"])
	_refresh()
