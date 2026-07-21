extends CanvasLayer
## Global modal for connection notices that chat can't reliably deliver:
## connection-ENDING ones (kicked, banned, handshake rejected, host left,
## reconnect exhausted — see EventBus.system_alert), and one in-progress,
## self-resolving one ("attempting to reconnect...", dismissed via
## EventBus.system_alert_clear if it actually succeeds). Pure UI: only
## listens to those two signals, knows nothing about networking, kicking, or
## banning itself, so any project can swap in its own look without
## NetworkManager/PlayerManager ever needing to change.

@export var dialog: AcceptDialog

## Queued rather than shown immediately if one's already up — e.g. a kick
## message followed moments later by the connection actually dropping.
var _queue: Array[String] = []

func _ready():
	dialog.confirmed.connect(_show_next)
	dialog.canceled.connect(_show_next)
	EventBus.system_alert.connect(_on_system_alert)
	EventBus.system_alert_clear.connect(_on_system_alert_clear)

func _on_system_alert(text: String):
	_queue.append(text)
	if not dialog.visible:
		_show_next()

func _show_next():
	if _queue.is_empty():
		return
	dialog.title = tr("SYSTEM_ALERT_TITLE")
	dialog.dialog_text = _queue.pop_front()
	dialog.popup_centered()

func _on_system_alert_clear():
	_queue.clear()
	if dialog.visible:
		dialog.hide()
