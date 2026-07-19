# Tick-Based Rollback & Netcode

This project implements a custom client prediction, server reconciliation, and remote interpolation
framework for player movement, rather than relying on standard RPC sync loops or basic
`MultiplayerSynchronizer` configurations.

The rollback machinery itself lives in [RollbackController](../netcode/rollback_controller.gd) — a
generic node that knows about ticks, RPCs, and reconciliation, but **nothing about what "input" means**.
[player.gd](../scenes/player.gd) supplies that meaning via three callbacks. This split is deliberate: a
new game changes what the player can do by editing three functions in `player.gd`, never by touching
netcode.

---

## 1. Why Not Use Naive Synchronization?
Standard multiplayer setups synchronize positions using basic intervals (e.g., 20 FPS). This causes two
major issues:
1. **Input Lag for Local Player**: If the player presses a button and waits for the server to send the
   new position back, the game feels unresponsive.
2. **Stutter for Remote Players**: Remote players appear to teleport between ticks, creating jittery
   movement.

---

## 2. The Split: RollbackController vs. player.gd

```
┌───────────────────────────────┐        ┌───────────────────────────────┐
│      RollbackController        │        │           player.gd            │
│  (netcode/rollback_controller) │        │        (scenes/player.gd)      │
│                                 │        │                                 │
│  Owns: ticks, RPCs,             │◄──────►│  Supplies: gather_input()      │
│  reconciliation, snap/lerp      │callback│           apply_input()        │
│  correction, per-role state.    │  set   │           sanitize_input()     │
│  Knows NOTHING about what       │        │                                 │
│  "input" means.                 │        │  Owns: movement, animation,     │
│                                 │        │  what a direction/jump means.   │
└───────────────────────────────┘        └───────────────────────────────┘
```

`player.gd._ready()` wires the three callbacks and a `role` onto its child `RollbackController` node once
the local peer's identity is known:

```gdscript
rollback.gather_input = _gather_input
rollback.apply_input = _apply_input
rollback.sanitize_input = _sanitize_input
rollback.role = RollbackController.Role.LOCAL_PREDICTED  # or SERVER_AUTHORITY / REMOTE_DUMMY
```

### The three callbacks (all defined in `player.gd`, this is the *only* place that changes to add abilities)

- **`gather_input() -> Dictionary`** — called once per physics tick on the local player. Reads
  `Input.is_action_pressed(...)` and returns an opaque `Dictionary`. `RollbackController` adds `"tick"`
  itself before sending; don't put it in the return value yourself.
- **`apply_input(input: Dictionary, delta: float) -> void`** — applies one input frame to the owner
  (`velocity = ...; move_and_slide()`). Called both during live prediction **and** during reconciliation
  replay, so it must be a pure function of (current state, input, delta) — no side effects beyond moving
  the owner, and replaying the same inputs must always land at the same position.
- **`sanitize_input(input: Dictionary) -> Dictionary`** — server-only. Clamps/validates untrusted client
  input before it's ever queued or applied (e.g. `player.gd`'s `_sanitize_input` clamps an oversized
  direction vector so a modified client can't claim to move faster than `speed` allows). Left unset,
  `RollbackController` trusts input as-is and prints a one-time warning — an explicit, visible choice
  rather than a silent gap.

Want to add a jump or an ability? Add a key to the dictionary `gather_input()` returns, read it in
`apply_input()`, done — `RollbackController` never needs to change.

---

## 3. The Four Roles

`RollbackController.Role` determines what a given `Player` instance actually does each physics tick:

### `LOCAL_PREDICTED` — this is *my* player, on *my* client
- `_tick_local_predicted()`: increments the tick, calls `gather_input()` + `apply_input()` immediately
  (the avatar moves instantly, no waiting for the network), then — unless this client *is* the server —
  buffers the input in `pending_inputs` and sends it via `_send_input_to_server` (unreliable RPC).
- The host's own local player skips the RPC/buffer entirely: it already has full authority over itself.

### `SERVER_AUTHORITY` — the server's copy of a *remote* client's player
- `_tick_server_authority()`: drains `server_input_queue` (bounded by `MAX_INPUTS_PER_TICK` per frame, so
  a client flooding input RPCs can't force multiple move steps into one server frame), applies each via
  `apply_input()`, and sends the resulting authoritative position back via `_send_auth_state`.
- `_send_input_to_server` (server-side RPC handler) runs `sanitize_input()` before queuing, and caps the
  queue at `MAX_QUEUED_INPUTS` (oldest dropped first) so a malicious/flooding client can't grow it
  unbounded.

### `REMOTE_DUMMY` — someone else's player, as seen on a *third* client (not server, not the owner)
- `RollbackController` does nothing for this role. `player.gd`'s own `_process_dummy_player()` instead
  `lerp()`s toward `sync_position`, a replicated property kept in sync via `MultiplayerSynchronizer`
  (`player.tscn`'s `ServerSynchronizer` node). This is deliberately **not** part of rollback — a dummy
  player is never predicted or reconciled locally, just smoothed toward the last known position.

### `NONE` — not yet configured (transient, before `player.gd._ready()` assigns a real role)

---

## 4. Reconciliation

`_send_auth_state` (client-side RPC handler, called by the server) is where correction happens:

1. Discard every buffered `pending_inputs` entry the server has already acknowledged (`tick <=
   auth_tick`).
2. Snap to the server's authoritative position.
3. Replay every *remaining* (unacknowledged) buffered input through `apply_input()` again, landing back
   at a locally-predicted position.
4. Compare the pre-correction and post-replay positions:
   - **Large gap** (> `rollback_snap_threshold`, default 3px): the client desynced (lag spike, packet
     loss) — snap instantly.
   - **Small gap**: `lerp()` the correction in over a couple frames so it isn't a visible pop.

---

## 5. Customizing Movement (or Adding New Input)

Everything you'd touch to change what the player can do lives in **`player.gd`**, not
`RollbackController`:
- `_gather_input()` — what gets read from `Input`.
- `_apply_input()` — what happens when that input is applied (movement, jump, ability trigger, ...).
- `_sanitize_input()` — server-side validation for whatever new fields you add.

Only touch `netcode/rollback_controller.gd` if you're changing the rollback *mechanism* itself (tick
rate, queue limits, snap/lerp correction curve, RPC channel choices) — that file has no idea what a
"direction" or a "jump" is, and should stay that way.

> **Wire-format note**: `RollbackController`'s RPCs live on the `RollbackController` child node, not on
> `Player` directly. If you ever restructure where it lives in the scene tree, bump
> `NetworkManager.PROTOCOL_VERSION` — an old build's RPC calls would silently fail to find their target
> against the new node path.
