# Pokemon Gold/Silver Co-op Pack (mGBA Lua)

This pack was built from your three files in:

- `E:\tester\pokemon-coop\mGBA-build-2026-03-05-win32-9000-b35fab339dc6d48d3d62a65b69e728e2f26d5f47`
- `E:\tester\pokemon-coop\Pokemon - Gold Version (USA, Europe) (SGB Enhanced) (GB Compatible).gbc`
- `E:\tester\pokemon-coop\Pokemon - Silver Version (USA, Europe) (SGB Enhanced) (GB Compatible).gbc`

## What this co-op build does

- Live sync of party data between host/client instances.
- Live sync of bag + key item block + balls + money between host/client instances.
- Injects a network-driven partner trainer into a real Gen2 object slot so you see a sprite in-world.
- Live partner telemetry in a console HUD (map, coordinates, packet age, active object slot).
- Smoother partner rendering with wrap-safe map deltas and teleport/jitter guards.
- Safer RAM sync timing (avoids party/items/money writes during menus, scripts, map transitions, and battles).
- Host (Gold) player sprite is forced to blue for easy visual distinction.
- Faststart automation for new games:
  - auto-skips most Oak intro text to reach naming faster,
  - pauses for manual clock/day setup and DST choice,
  - resumes and skips Mom's extra tutorial text.
- Optional Silver Ollama agent:
  - controls Silver through its dedicated Silver bridge (never Gold),
  - can run in a dedicated visible Silver session wrapper,
  - runs intro automation (name choice + text skip),
  - follows host in overworld, auto-battles, and attempts catches,
  - learns from host movement + reward feedback and saves memory.
- Background dual-window controls:
  - global keyboard broadcaster can drive both Gold/Silver even when windows are not focused.

## Important caveats

- This is a RAM-level runtime hack, not a patched ROM rewrite.
- On maps with very high NPC counts, the partner slot can conflict with existing NPC object slots.
- If you see sprite glitches in a crowded map, leave/re-enter map or move to a less crowded area.
- The partner sprite only appears when both players are on the same map.

## Quick start (same PC)

1. Run `E:\tester\pokemon-coop\coop\start_local_dual.bat`.
2. Gold starts as host, Silver starts as client.
3. Keep both emulator windows running.
4. Open the `GS Co-op` console buffer in each window and check `Socket: connected`.
5. For a fresh new game, use the faststart flow:
   - set your name manually when naming appears,
   - set day/time and DST manually when prompted,
   - remaining early text auto-skips.
6. To force fresh-new-game boot (with save backup), run `E:\tester\pokemon-coop\coop\start_fresh_local_dual.bat`.

## Smart Ollama mode (same PC)

1. Ensure Ollama is running locally and your model is pulled (default: `llama3.2`).
2. Run `E:\tester\pokemon-coop\coop\start_local_dual_ollama.bat llama3.2`.
3. This starts:
   - Gold host,
   - Silver in a dedicated visible AI session wrapper (`start_silver_ai_visible.bat` + `ai\silver_session_wrapper.py`),
   - Silver AI controller only (bound to Silver bridge port `58888`),
   - no global keyboard injection by default (prevents cross-control on Gold/Silver).
4. Optional args:
   - `start_local_dual_ollama.bat MODEL NAME_SLOT KB_TARGET SILVER_MODE`
   - `NAME_SLOT` is 1-4 for preset trainer name choice (`0` = auto from model hash).
   - `KB_TARGET` defaults to `none` (strict mode, no background key injection).
   - `SILVER_MODE` defaults to `visible`; set to `bg` to run Silver via background wrapper.
   - windows are auto-tiled side-by-side by default (`GS_TILE_WINDOWS=1`); set `GS_TILE_WINDOWS=0` to disable tiling.
5. Optional global controls (only when keyboard bridge is enabled):
   - `Arrows` or `WASD`: D-pad
   - `Z`/`J`: A
   - `X`/`K`: B
   - `Enter`: Start
   - `Shift`: Select
6. Keyboard bridge target (opt-in):
   - strict default: disabled (`KB_TARGET=none`),
   - enable Gold-only bridge: `start_local_dual_ollama.bat llama3.2 0 gold`,
   - enable both windows bridge: `start_local_dual_ollama.bat llama3.2 0 both`.
7. Update AI/controller pieces without closing emulators:
   - run `E:\tester\pokemon-coop\coop\refresh_ai_background.bat`
   - this restarts Silver AI, and optionally keyboard bridge if a non-`none` target is provided.
8. One-command hot update (keep both game windows open):
   - run `E:\tester\pokemon-coop\coop\hot_update_keep_windows.bat`
   - optional: `hot_update_keep_windows.bat MODEL NAME_SLOT KB_TARGET`
   - default keyboard target is `none`,
   - re-parks Silver only when `GS_SILVER_WINDOW=bg`.
9. If you edit Lua co-op scripts (`coop\scripts\*.lua`), relaunch mGBA once to apply those Lua changes.

## Quick start (two PCs)

1. Copy the full `E:\tester\pokemon-coop` folder to both PCs.
2. On host PC, run `E:\tester\pokemon-coop\coop\start_gold_host.bat`.
3. On client PC, run `E:\tester\pokemon-coop\coop\start_silver_client.bat HOST_IP_HERE`.
4. Allow Windows Firewall access for `mGBA.exe` when prompted.

## Battles and trades

- Use mGBA's built-in link cable multiplayer mode for battle/trade sessions.
- The Lua co-op script runs alongside link mode and keeps party/items/money synchronized.

## Safety notes

- Back up `.sav` files before long sessions.
- If you want read-only tracking, set `sync_party = false`, `sync_items = false`, `sync_money = false` in both script config files.

## Troubleshooting

- If `Socket` is not connected, relaunch host first, then client.
- If connected but no partner sprite, move both players to the same route/town and re-enter the map once.
- Faststart only targets Gold/Silver ROM codes (`AAUE`/`AAXE`) and only the initial new-game flow.
- To disable faststart, set env var `GS_FASTSTART=0` before launching mGBA.
- To disable global background keyboard broadcaster, set env var `GS_BG_KEYBOARD=0` before launching `start_local_dual_ollama.bat`.
- To force keyboard broadcast target, pass arg 3: `start_local_dual_ollama.bat MODEL NAME_SLOT none|silver|gold|both`.
- To use dedicated visible Silver AI session directly (without launching Gold), run `E:\tester\pokemon-coop\coop\start_silver_ai_visible.bat`.
- To control Silver window behavior, set env var `GS_SILVER_WINDOW=bg|min|fg`.
- In Ollama mode, Silver local background key override is off by default (`GS_BG_INPUT=0`) so AI owns Silver controls unless you explicitly enable it.
- In Ollama mode, Silver also runs with local human joypad lock (`GS_SILVER_LOCK_INPUT=1`) so your keyboard does not steer Silver.
- To push an already-running Silver window back into background mode, run `E:\tester\pokemon-coop\coop\repark_silver_background.bat`.
- If manual keys conflict with Silver AI, hold manual keys and the AI will back off while keys are active.
