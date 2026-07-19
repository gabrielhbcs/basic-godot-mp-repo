# Decoupled Camera Component

This project features a highly decoupled, reusable `GameCamera` component designed to follow targets dynamically using Godot's group system.

---

## 1. Design & Decoupling Philosophy
In many games, the camera is nested directly inside the player scene. While simple, this approach causes issues in multiplayer:
*   **Wasted Resources**: Every spawned player instance (including remote players) would contain a camera node.
*   **Brittle Lifecycles**: If the player node is deleted (e.g., player dies, disconnects, or respawns), the camera is also deleted, causing abrupt visual jumps.
*   **Tight Coupling**: Screen shake, transitions, and camera bounds become difficult to coordinate independently of player movement.

Instead, this template keeps the camera as a **first-class scene node** directly in the level ([game.tscn](../scenes/game.tscn)) and uses **Godot Groups** to dynamically link it to the local player.

```
                  ┌─────────────────┐
                  │   Game Scene    │
                  └────────┬────────┘
                           │
             ┌─────────────┴─────────────┐
             ▼                           ▼
    ┌─────────────────┐         ┌─────────────────┐
    │  Players Node   │         │   GameCamera    │
    └────────┬────────┘         └────────┬────────┘
             │                           │ (Finds via group "local_player")
             ▼                           │
    ┌─────────────────┐                  │
    │   Local Player  │◄─────────────────┘
    │  (Group Member) │
    └─────────────────┘
```

---

## 2. Dynamic Target Acquisition
*   **Player Side**: In [player.gd](../scenes/player.gd), during `_ready()`, the player checks if they are the local peer (`peer_id == multiplayer.get_unique_id()`). If so, they call `add_to_group("local_player")`.
*   **Camera Side**: [game_camera.gd](../scenes/game_camera.gd) connects to the scene tree's `node_added` signal and also queries the `"local_player"` group during its own `_ready()`. The moment the local player enters the tree, the camera instantly binds to it.

---

## 3. Features & Configuration

The camera component exposes several customizable properties in the inspector:

### Target Tracking
*   `target_group` (String): The group the camera looks for to set its follow target (default: `"local_player"`).
*   `lerp_speed` (float): Control how tightly/smoothly the camera catches up to the player.
*   `look_ahead_factor` (float): Offsets the camera in front of the player's movement vector. High values help players see further in the direction they are running.
*   `look_ahead_speed` (float): How quickly the camera shifts to target the look-ahead point.

### Zoom Settings
*   `enable_zoom_control` (bool): Enables or disables scroll-based zooming.
*   `min_zoom` / `max_zoom` (float): Clamps the minimum and maximum camera zoom limits.
*   `zoom_speed` (float): Controls the interpolation speed of zoom transitions.
*   `zoom_step` (float): The increment of zoom changed per scroll tick.

---

## 4. Reusable Screen Shake API
The camera registers itself to the `"game_camera"` group, enabling any script in the codebase to request screen shakes without needing a direct reference to the camera node.

### Usage:
```gdscript
# Intensity of 10 pixels, duration of 0.4 seconds
get_tree().call_group("game_camera", "shake", 10.0, 0.4)
```
This is ideal for explosion components, bullet hit effects, UI impact events, or damage indicators.
