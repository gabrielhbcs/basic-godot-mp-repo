extends Node

# Network & Lobby Signals
signal player_connected(id: int)
signal player_disconnected(id: int)
signal connection_failed
signal server_disconnected
signal player_data_updated(id: int)
signal match_ended

## NetworkManager.ConnectionState value (int — see network_manager.gd). UI should
## observe this instead of reacting ad hoc to connection_failed/server_disconnected.
signal connection_state_changed(state: int)
## A reconnecting peer was assigned a new peer_id but is the same player as
## old_id (matched by persistent client identity — see PlayerManager.client_uuid).
## Any peer_id-keyed local state (VOIP prefs, UI selection, ready status) must be
## migrated from old_id to new_id when this fires.
signal peer_identity_migrated(old_id: int, new_id: int)

# Chat Signals
signal system_message_received(msg: String)
signal clear_chat
