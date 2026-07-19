# Starting a New Game From This Template

This template's whole point is that netcode, VOIP, settings, and localization are **already solved**
for you. Starting a new game means copying this repo wholesale and building *your* game inside it — not
re-implementing any of the systems described in [architecture.md](architecture.md).

---

## 1. Copy the repo

There's no git submodule/subtree mechanism set up for this yet. The straightforward path:

1. Duplicate the whole project folder to your new game's location.
2. Delete `.godot/` from the copy (Godot regenerates it, and a stale cache from the template — see the
   `class_name` registration gotcha in [known-limitations.md](known-limitations.md) — is exactly the
   kind of thing you don't want carried over by accident).
3. Open the copy in Godot and **let the initial filesystem scan finish** before touching anything —
   same caveat as in the README: `class_name` scripts (`RollbackController`, `MatchState`, `VoicePanel`,
   `AdminPanel`, `VoipConfig`, ...) won't resolve until that scan completes once.
4. In `project.godot`, change `config/name` (currently `"basic-mp"`) to your game's name. If you'll
   export the project, also revisit `export_presets.cfg` (package identifiers, icons) — that file is
   entirely template-specific and wasn't part of this work.
5. Rename or replace `icon.svg` and the placeholder assets in `assets/` — those are the template's
   demo art (a slime sprite sheet), not meant to ship.

If you want to keep pulling *future* template fixes into an already-started game later, that needs git
(a submodule for the shared `autoloads/`/`voip/`/`netcode/`/`session/` folders, or periodically diffing
against the template repo) — worth setting up if you plan to build more than one game from this base,
but not required to get started.

---

## 2. What's foundation vs. what's yours

Everything in these folders is meant to work unmodified across every game built from this template.
Don't fork logic out of them for a single game's needs — extend them via the hooks in Section 3 instead,
so improvements stay reusable:

| Keep as-is | What it does |
|---|---|
| `autoloads/` | Networking, identity, VOIP transport, settings persistence, localization |
| `voip/` | Mic capture, Opus encode/decode, jitter buffer, positional fade |
| `netcode/` | Rollback prediction/reconciliation mechanics |
| `session/` | Ready-up/countdown/match-lifecycle state machine |
| `addons/twovoip/` | The GDExtension VOIP itself is built on |

Everything below is **yours to replace almost entirely** — the template only put placeholder content
here to prove the systems work end-to-end:

| Replace freely | Current placeholder content |
|---|---|
| `scenes/game.tscn` + `game.gd` | Empty colored background, a basic `_spawn_player` loop, an "End Match" button |
| `scenes/player.tscn` + `player.gd`'s movement | Slime sprite sheet, WASD 4-directional movement, no abilities |
| `assets/` | Placeholder sprites |
| Lobby/LoginMenu/ServerBrowser visual styling | Functional but minimal `VBoxContainer` layouts — restyle freely, the scripts don't care about visual layout, only the exported `NodePath`s |
| `localization/locales/*.json` **strings** | The *keys* are used throughout the scripts — don't rename keys without updating every `tr("KEY")`/`.text = "KEY"` call site, but the *values* (actual English/Portuguese text) are yours to change per-game |

---

## 3. The extension points — this is how you add your own stuff without touching the foundation

The template was deliberately built with these seams. Use them; don't route around them.

### Adding movement, jumping, abilities — `player.gd`'s three callbacks
This is **the** primary extension point for gameplay. Never touch `netcode/rollback_controller.gd` for
this. In `player.gd`:

```gdscript
func _gather_input() -> Dictionary:
    var input := {"dir": ...}
    input["jump"] = Input.is_action_just_pressed("jump")  # add a field
    return input

func _apply_input(input: Dictionary, _delta: float) -> void:
    velocity = input.get("dir", Vector2.ZERO) * speed
    if input.get("jump", false) and is_on_floor():
        velocity.y = -jump_force
    move_and_slide()
    if multiplayer.is_server():
        sync_position = position

func _sanitize_input(input: Dictionary) -> Dictionary:
    # validate/clamp whatever new fields you add — this runs server-side on
    # every remote client's input before it's trusted
    ...
    return input
```

See [docs/netcode.md](netcode.md) for the full contract (what must stay a pure function, what
`RollbackController` adds automatically, etc.).

### A different voice profile per game — duplicate `VoipConfig`
`voip/default_voip_config.tres` is read once via a `ProjectSettings` key
(`voip/default_config_path`), not hard-`preload`ed. Duplicate the `.tres`, tune bitrate / VOX
threshold / proximity fade distances for your game, point the project setting at your copy. No code
changes.

### A new remappable action — `SettingsManager.REMAPPABLE_ACTIONS`
Add your action's `StringName` to that `const Array` and bind a default in `project.godot`'s
`[input]` section. It appears in **Settings → Input** automatically — `settings_menu.gd` builds that
tab by iterating the list, not by hardcoding rows.

### A new language — drop a JSON file
Copy `localization/locales/en.json`, translate the `"strings"` values, change `"locale"`/`"name"`.
Appears in the Settings language dropdown automatically. See `localization.gd`'s own doc comment (and
its section in [architecture.md](architecture.md)) for the fail-safes if a file is malformed.

### Reacting to game-wide events without new coupling — `EventBus`
If your game needs to know "a match ended" or "a player connected," listen on `EventBus` rather than
reaching into `NetworkManager`/`PlayerManager` directly — that's what already lets `lobby.gd`,
`chat_ui.gd`, and `voip_network.gd` all react to the same events without depending on each other. Don't
add gameplay-specific or high-frequency signals to it (see `architecture.md`'s "Scoped UI Event Bus"
tenet for what belongs here vs. what doesn't).

### Proximity voice culling for your game's world — `VoipNetwork.voice_relevance`
`game.gd` already sets this (`_is_voice_relevant`, a distance check against `max_voice_distance`) as
the reference implementation. If your game isn't 2D top-down with `Node2D` positions, replace that one
callback — `VoipNetwork` itself has no idea what a "position" is.

### A different lobby flow — `MatchState`'s signals
If your game doesn't want a ready-up/countdown flow at all (e.g. jump-in-anytime), you don't need to
touch `session/match_state.gd` — just don't instantiate it, or don't wire `lobby.gd`'s listeners to
it. If you want a *different* flow (best-of-N rounds, a lobby with teams), extend `MatchState` itself
rather than reimplementing ready/countdown from scratch — it already handles the reconnect-migration
and disconnect-during-countdown edge cases correctly.

---

## 4. A concrete first hour

1. Rename the project (Section 1).
2. Replace `assets/slime-sprite-sheet.png` with your own character art; update `player.tscn`'s
   `Sprite2D` texture and `hframes`/`vframes` to match.
3. Add one new ability end-to-end using the pattern in Section 3 (jump is a good first test — it
   touches all three callbacks and proves the rollback/reconciliation still works with your change).
4. Replace `game.tscn`'s empty `ColorRect` background with your actual level, and `GameManager`'s
   `_spawn_player` positions with your own spawn points.
5. Run two instances locally (README's "Testing Multiplayer Locally"), confirm movement/voice/chat all
   still work exactly as before — if something regressed, it's almost certainly because a change
   reached into `netcode/`/`voip/`/`session/` directly instead of through the callbacks/signals above.
6. Only then start reskinning the Lobby/Settings UI, if you want a different look than the functional
   default.

Everything else — reconnect, kick/ban, settings persistence, localization — needs zero further work to
be present in your new game. That's the point of building it this way once.
