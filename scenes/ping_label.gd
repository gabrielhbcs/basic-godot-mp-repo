extends Label
## Ping HUD, split out of NetworkManager (which only measures the round trip
## via NetworkManager.ping_updated — it never touches a Control itself). Same
## split as VoipNetwork vs VoicePanel: swap this file for a differently styled
## HUD without touching the transport autoload at all.
##
## Lives under Lobby.tscn rather than as its own autoload: unlike the
## kick/ban/reconnect alerts (SystemAlertModal), ping only ever matters once
## connected, and Lobby.tscn is never torn down for the lobby<->match
## transition (see GameLevelContainer in lobby.gd) — only for the
## login/server_browser scenes beforehand, where there's nothing to ping yet.

func _ready():
	NetworkManager.ping_updated.connect(_on_ping_updated)
	EventBus.connection_state_changed.connect(_on_connection_state_changed)
	_refresh()

func _on_ping_updated(_ms: int):
	_refresh()

func _on_connection_state_changed(_state: int):
	_refresh()

func _refresh():
	if not NetworkManager.is_connected_to_session():
		text = ""
		return
	# Explicit tr() here, not a bare key assignment: the interpolated result
	# ("Ping: 42ms") can never match a translation key itself — see
	# Localization.retranslate_tree()'s doc for why that pattern doesn't fit.
	if NetworkManager.get_local_peer_id() == 1:
		text = tr("PING_HOST")
	elif NetworkManager.current_ping > 0:
		text = tr("PING_FORMAT") % NetworkManager.current_ping
	else:
		text = ""
