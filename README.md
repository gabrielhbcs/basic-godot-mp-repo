# Godot 4 Multiplayer Base Template

Welcome to the **Server-Authoritative Godot 4 Multiplayer Template**. This repository serves as a highly scalable, decoupled foundation for building tick-rate synchronized 2D multiplayer games with integrated VOIP (voice chat), settings, and localization — meant to be the starting point for future game projects, not a one-off demo.

It strictly enforces separation of concerns (decoupling) so that features can be added, updated, or removed without breaking unrelated subsystems.

Oh and probably a very important thing... a lot here was done via ✨Vibe Coding✨ because I don't know (yet) game coding (crying in web backend). So expect this to evolve (or maybe I'll just forget about this project lol)

---

## 📖 Table of Contents

*   [Starting a New Game From This Template](docs/starting-a-new-game.md) — **start here** if you're building a new game on this base.
*   [Codebase Architecture Guide](docs/architecture.md) — Singletons, structure, and decoupling rules.
*   [Tick-Based Netcode Guide](docs/netcode.md) — Prediction, reconciliation, and the input-callback contract.
*   [Decoupled Camera Guide](docs/camera.md) — Group-based camera tracking, zoom, and screen shake APIs.
*   [Known Limitations & Verification Status](docs/known-limitations.md) — what's confirmed working, what isn't yet, and why some gaps are deliberate.

---

## ⚡ Core Features

1.  **Strict Server Authority**: The client never determines state (health, damage, valid spawns). The server controls, validates, and replicates.
2.  **Tick-Based Netcode**: Client prediction and server reconciliation for zero-latency local movement, combined with remote interpolation for smooth dummy avatars — the rollback machinery is fully decoupled from what "input" means (see [RollbackController](netcode/rollback_controller.gd)), so a new game changes movement/abilities without touching netcode.
3.  **Voice-Over-IP (VOIP)**: Microphone audio is Opus-encoded via the [twovoip](addons/twovoip) GDExtension and relayed through the server for real-time positional voice, with per-peer mute/volume and server-side proximity culling. Capture, playback, and transport are separate, swappable pieces.
4.  **Robust Networking**: Version/identity handshake with timeout, automatic reconnect with exponential backoff, and reconnect *identity restoration* — a dropped player who reconnects within the grace period keeps their name, ready status, and other players' voice prefs about them, all under a fresh `peer_id`.
5.  **Moderation**: Server-authoritative kick/ban, persisted by both peer UUID and IP. Host is always an admin; `admin_uuids` extends that to dedicated servers, which have no host player.
6.  **Settings System**: Persisted audio/video/input/voice settings, applied live where safe to do so and gated behind explicit confirmation where not (voice settings rebuild the Opus encoder, which would interrupt an active talk burst).
7.  **Localization**: Languages are data files, not code — drop a JSON file in [localization/locales/](localization/locales/) and it appears in the language dropdown automatically. Ships with English and Brazilian Portuguese.
8.  **Decoupled Camera System**: An independent camera node follows local players dynamically via groups, supporting look-ahead offsets, smooth zoom, and a screen-shake API.
9.  **Scoped Event Bus**: UI layers are decoupled from game and networking components via a strictly defined UI-only event bus.

---

## 📂 Key Code Components

*   [event_bus.gd](autoloads/event_bus.gd) — Centralised event emitter for UI & Non-Gameplay triggers.
*   [network_manager.gd](autoloads/network_manager.gd) — ENet connection, handshake, reconnect, kick/ban.
*   [player_manager.gd](autoloads/player_manager.gd) — Peer identity, profiles, reconnect detection.
*   [settings_manager.gd](autoloads/settings_manager.gd) — Persisted user settings, applied live.
*   [localization.gd](autoloads/localization.gd) — Discovers and registers `localization/locales/*.json`.
*   [voip_network.gd](autoloads/voip_network.gd) — VOIP transport: the only VOIP piece that knows about multiplayer.
*   [voip_microphone.gd](voip/voip_microphone.gd) — Opus capture/encode. Emits packet signals; never touches the network.
*   [voip_speaker.gd](voip/voip_speaker.gd) — Per-peer playback: jitter buffer, FEC concealment, drift compensation, proximity fade.
*   [voip_config.gd](voip/voip_config.gd) — All tunable VOIP parameters as a shareable `Resource`.
*   [rollback_controller.gd](netcode/rollback_controller.gd) — Generic tick/prediction/reconciliation, parameterized by input callbacks.
*   [match_state.gd](session/match_state.gd) — Ready-up/countdown/match-lifecycle state machine, signals only.
*   [player.gd](scenes/player.gd) — Movement, animation, and the input-callback contract for `RollbackController`.
*   [game_camera.gd](scenes/game_camera.gd) — Decoupled camera script for local tracking, zooming, and shaking.
*   [server_browser.gd](scenes/server_browser.gd) — LAN server discovery, direct-IP join, and host/create flow.
*   [lobby.gd](scenes/lobby.gd) — Thin orchestrator: player list, connection status, wires up the components below.
*   [voice_panel.gd](scenes/voice_panel.gd) / [admin_panel.gd](scenes/admin_panel.gd) — Per-peer voice and kick/ban controls.
*   [settings_menu.gd](scenes/settings_menu.gd) — Settings overlay (Audio/Video/Input/Voice tabs + Quit).
*   [chat_ui.gd](scenes/chat_ui.gd) — Server-relayed, sanitized lobby/in-game chat component.

---

## 🚀 Quick Start / Development

### Testing Multiplayer Locally
To run and test connection logs:
1. Open the project in Godot 4 — **let the initial filesystem scan finish** before running anything; a
   just-opened project may briefly show "Could not find type" errors for the template's `class_name`
   scripts until that scan completes.
2. Under **Project Settings -> Debug -> Run Multiple Instances**, set the count to `2` or `3`, and make sure to add the argument `--client-uuid=[uuid]` to the extra instances so you can connect to yourself.
3. Hit the **Run Project (F5)** button.
4. In Instance 1, click **Host**.
5. In Instance 2/3, enter a player name and click **Join**.
6. Move around using `WASD` or arrow keys — remapping any of these lives in **Settings -> Input**. The camera will dynamically follow the local player.

### Enabling Voice Chat (VOIP)
*   Ensure a microphone is plugged in, and that your default system recording device is set correctly in your OS.
*   Pick a specific input device from the dropdown on the **Login** screen, or from **Settings -> Voice**.
*   Transmission defaults to **voice activity detection** (talk and it transmits). Hold `V` for push-to-talk or press `M` to toggle mute — all configurable in **Settings -> Voice**, backed by [voip_config.gd](voip/voip_config.gd).
*   Voice playback uses the `VoipSpeaker` node under each `Player` avatar's `VoicePlayer` (`AudioStreamPlayer2D`), giving positional audio with a plateau-then-fade proximity curve — see `VoipConfig.fade_start_distance`/`max_distance`.

### Settings & Language
*   Open **Settings** from either the Login screen or the Lobby (it's an overlay, not a scene change — opening it from the Lobby never disconnects you).
*   **Video** tab includes the language dropdown — it reflects whatever `.json` files are present in [localization/locales/](localization/locales/), not a hardcoded list.
*   Adding a language: copy `localization/locales/en.json`, translate the `"strings"` values, change `"locale"`/`"name"`, save it as a new file in the same folder. No code changes needed.

### Moderation
*   The host (`peer_id` 1) can kick/ban a selected player from the Lobby's player list.
*   For a dedicated (headless) server, which has no host player, grant admin rights via
    `user://server_admins.cfg` — see `NetworkManager.admin_uuids`'s doc comment. There's currently no
    in-Lobby UI for a non-host admin to use this (see [known-limitations.md](docs/known-limitations.md));
    moderate by editing `bans.cfg`/`server_admins.cfg` directly, or via a future server console.

---

## 🤝 Want to Contribute?

This project's whole reason for existing is to stay a **decoupled base template** — something you can drop into a new game and only touch the pieces relevant to that game, without one subsystem dragging three others along with it. That constraint matters more here than in a typical game project, so before opening a PR, keep a few things in mind:

*   **Decoupling is the point, not a nice-to-have.** VOIP doesn't know what a "player" is; the rollback netcode doesn't know what "input" means; the camera doesn't know about networking; the event bus doesn't know about game logic. If your change makes one system reach into another's internals to work, that's a sign it needs a callback, signal, or config value instead — not a sign the decoupling is being too strict.
*   **Prefer callbacks/signals/Resources over hard references.** Look at how [rollback_controller.gd](netcode/rollback_controller.gd) takes `gather_input`/`apply_input`/`sanitize_input` as injected callables, or how [voip_network.gd](autoloads/voip_network.gd) exposes a `voice_relevance` callback instead of knowing about positions itself — that's the pattern to follow for new features.
*   **Fail safe, not silent.** Optional integrations (e.g. `EventBus` presence checks in VOIP/PlayerManager) should degrade gracefully if a project doesn't have that autoload, rather than assuming it's always there.
*   **Small, focused PRs.** Since the goal is reusability, a PR that bundles an unrelated refactor with a feature is harder to evaluate for "does this leak coupling somewhere."
*   Check [known-limitations.md](docs/known-limitations.md) first — your idea might already be a documented, deliberate gap rather than an oversight.

Bug reports, docs fixes, and translations (drop a new `.json` in [localization/locales/](localization/locales/)) are welcome with much less ceremony than the above — that guidance is mainly for anything touching core architecture.
