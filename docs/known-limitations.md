## Structural debt (not bugs, but real — recorded so it isn't rediscovered)

- **Hardcoded scene paths scattered** across `NetworkManager.gd`, `Lobby.gd`, `LoginMenu.gd`, and
  `ServerBrowser.gd` (each `change_scene_to_file("res://scenes/...")` call is a literal string, repeated
  in 7 places). Worth centralizing into a single source of truth if the scene structure ever needs to
  change.
- **A disconnect message can show the wrong fallback name.** "X left the room" can read "Player N"
  instead of the real name, because `PlayerManager`'s `peer_disconnected` handler (which erases the
  profile) runs before `NetworkManager`'s (which emits the signal the message is built from) — an
  artifact of autoload order in `project.godot`. Doesn't affect reconnect (which reads the name before
  erasing, on the join side), just this one disconnect message.

## Known, deliberate gaps (not bugs — documented trade-offs)

- **The host-left notice (`NetworkManager._send_host_left`) only fires on a *graceful* exit** — the Leave
  Room button or Settings' Quit button, both of which call `leave_game()`. A crash, task-kill, or the OS
  window's own close (X) button skip `leave_game()` entirely (no `NOTIFICATION_WM_CLOSE_REQUEST` handler
  is installed), so clients in that case fall back to the pre-existing behavior: `NetworkManager`'s normal
  reconnect backoff, which still gets everyone back to the server browser once it exhausts
  `MAX_RECONNECT_ATTEMPTS` (~31s default), just without the immediate, specific "the host left" modal.
  Hooking the OS close button was deliberately left out — reliably flushing a reliable RPC before the
  process actually exits needs `SceneTree.quit()` to be deferred past `leave_game()`'s own `await`, which
  isn't a change worth making blind in an environment without a display to verify it against.
- **Reconnecting mid-match doesn't respawn your avatar.** Identity restoration (name, ready status,
  voice prefs) works; `Game.gd` only spawns players present when the scene loads, so a reconnect during
  an active match restores who you are but not your position in the world. Fixing this is a separate,
  larger problem (replication catch-up for an in-progress match).
- **Bans key on `client_uuid` and IP, neither of which is a solid identity.** `client_uuid` is
  client-supplied and unauthenticated (a banned player can just delete `user://client_identity.cfg` and
  get a new one); IPs are shared (NAT, VPNs) and rotate. Both are recorded and checked
  (`NetworkManager.ban_peer()`/`is_banned()`) and the limitation is accepted rather than solved — a real
  fix needs actual accounts, which this template deliberately doesn't have (see "Deliberately out of
  scope" below).
- **A non-host dedicated-server admin has no in-Lobby kick/ban UI.** `NetworkManager.admin_uuids` fully
  authorizes them server-side, but the Lobby's Kick/Ban buttons are only shown to `peer_id == 1` (the
  host) — a client can't see the server's admin list to decide whether to show them. Moderating from
  that role today means editing `bans.cfg`/`server_admins.cfg` directly, or a future server console.
- **Two narrow "won't retroactively update on a pure language switch" cases**, both already commented
  at their exact location in code: `Lobby.gd`'s `status_label`/`ready_button` (state-driven, not
  key-driven — see the comment in `_on_ready_pressed()`), and Settings' "(unbound)" keybind label (see
  `SettingsMenu._format_events()`). Both only affect a label that's already showing something dynamic;
  neither breaks on first load, and both catch up on their next natural state change.

## Deliberately out of scope

Not forgotten — considered and left out because guessing at a game-specific answer would cost more than
adding it later once a real game built on this template actually needs it:

- Lag compensation for hitscan/projectiles.
- Persistence/accounts (this template has session identity via `client_uuid`, not accounts).
- Matchmaking beyond the existing LAN broadcast discovery.
