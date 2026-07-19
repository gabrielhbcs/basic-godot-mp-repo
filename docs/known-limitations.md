# Known Limitations & Verification Status

This template was built and iterated on in an environment without a display, so a lot of it was verified
structurally (clean compiles, scenes instantiate, RPC/signal flow traced by hand) rather than by actually
clicking through the UI or running a real two-instance session. This page is the honest, current record
of what's been confirmed live vs. what hasn't, plus the gaps and shortcuts that were deliberate choices
rather than oversights — so nothing here needs rediscovering the hard way.

---

## Verified live (confirmed working with a real mic / two real instances)

- **VOIP**: capture, encode, playback, per-player mute/volume, and proximity fade (plateau-then-fade
  curve) — all confirmed working with real audio.
- **Basic connectivity**: hosting, joining, and normal play all work. One real bug was found and fixed
  this way — an unguarded `is_server()` call during the connecting window that spammed errors on every
  join (see `NetworkManager._process()`'s comment for the fix).
- **Localization**: opening Settings, switching languages, and the Settings UI generally all work.
  Two real bugs were found and fixed this way — `OptionButton` items and `TabContainer` tab titles
  weren't re-resolving on a live language switch (fixed in `Localization.retranslate_tree()`), and one
  locale file had an untranslated string sitting in it (data fix, not a code fix).

## Not yet verified live

- **Reconnect identity restoration end-to-end**: disconnect and reconnect a client, confirm name/ready
  status/other-players'-VOIP-prefs-about-them survive under the new `peer_id`. The mechanism is built
  and traced by hand (`PlayerManager.client_hello`, `EventBus.peer_identity_migrated`), just not
  exercised live.
- **Handshake edge cases**: joining with a deliberately wrong `PROTOCOL_VERSION` (should reject
  immediately, not retry for ~30s), and a peer that connects but never completes the handshake (should
  be dropped after 5s, not left in limbo).
- **Kick/ban**: kicking or banning a non-host client, confirming they see the reason and don't
  auto-reconnect, confirming a ban survives a rejoin attempt, confirming a non-admin's buttons stay
  disabled and a hand-crafted RPC bypass attempt is still refused server-side.
- **Rollback reconciliation under real network conditions**: specifically an artificial lag spike —
  does the snap/lerp correction actually feel right, or does it rubber-band?
- **A remapped keybind actually changing what moves the player** — Settings → Input lets you rebind
  `move_up` etc., but this hasn't been confirmed to actually take effect in gameplay afterward.
- **Settings persistence across an app restart** (`user://settings.cfg`) and the Quit button actually
  closing the app cleanly.
- **The Audio tab's bus volume sliders** being audible.

None of these are known-broken — they're just unexercised. Treat this list as a test plan, not a bug list.

---

## Structural debt (not bugs, but real — recorded so it isn't rediscovered)

- **`NetworkManager.gd` builds UI directly** (a `CanvasLayer` + ping `Label`, constructed in code). A
  transport autoload owning pixels makes it harder to restyle or hide. Should eventually become a signal
  (`EventBus` or `NetworkManager`'s own) that a proper UI component listens to, mirroring how VOIP and
  match state are already split.
- **`ChatUI.gd` owns its own RPCs directly** — chat request/relay/broadcast logic lives inside the UI
  node itself, unlike VOIP (`VoipNetwork` + `VoipSpeaker`) or match state (`MatchState` + `Lobby.gd`'s
  panels), which both split network logic from UI. Chat is the one place in this template that doesn't
  follow its own pattern.
- **Hardcoded scene paths scattered** across `Lobby.gd`, `LoginMenu.gd`, `Game.gd` (each
  `change_scene_to_file("res://scenes/...")` call is a literal string, repeated in multiple places).
  Worth centralizing into a single source of truth if the scene structure ever needs to change.
- **A disconnect message can show the wrong fallback name.** "X left the room" can read "Player N"
  instead of the real name, because `PlayerManager`'s `peer_disconnected` handler (which erases the
  profile) runs before `NetworkManager`'s (which emits the signal the message is built from) — an
  artifact of autoload order in `project.godot`. Doesn't affect reconnect (which reads the name before
  erasing, on the join side), just this one disconnect message.

## Known, deliberate gaps (not bugs — documented trade-offs)

- **Reconnecting mid-match doesn't respawn your avatar.** Identity restoration (name, ready status,
  voice prefs) works; `Game.gd` only spawns players present when the scene loads, so a reconnect during
  an active match restores who you are but not your position in the world. Fixing this is a separate,
  larger problem (replication catch-up for an in-progress match).
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

---

## A few non-obvious things worth remembering if you're debugging this template

- **A brand-new `class_name` script won't resolve immediately.** Godot's global script class cache
  needs an editor rescan to pick up a new `class_name` — a plain headless run of a scene referencing it
  will fail with `Could not find type "X"` until the editor has opened the project at least once (or a
  forced rescan runs). Not a bug, just how Godot's caching works.
- **`ConfigFile.get_value(section, key, null)` does not treat an explicit `null` as a valid default** —
  Godot treats it identically to "no default provided" and throws an error if the key is missing. Check
  `ConfigFile.has_section_key()` explicitly instead.
- **Don't route VOIP capture through `AudioStreamMicrophone` + `AudioEffectCapture`.** That path runs
  the mic through the *output* mixer's clock and corrupts the capture rate behind virtual audio devices
  (SteelSeries Sonar and similar) — this is the bug that killed this project's original hand-rolled VOIP
  system before this template's `voip/` package replaced it. See `voip_microphone.gd`'s own doc comment.
