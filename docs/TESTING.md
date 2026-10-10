# Testing

## Automated tests (no game needed)

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cd build && ctest --output-on-failure
```

| Test | What it proves |
|---|---|
| `native_transport` (`plugin/tests/test_net.cpp`) | Handshake, names, binary-safe payloads, size limits. 1,500 reliable messages each way under **30% simulated packet loss** arrive exactly once and in order. Password, session-full and version-mismatch rejections. Reconnect after a partner restart. Graceful leave and rejoin. Connect timeout, link timeout, LAN address listing |
| `lua_test_bindings` | The `re4coop_net` C API: bad arguments raise catchable Lua errors, failures return `nil, message` (port in use, double host, unresolvable host), binary-safe payloads between two sessions |
| `lua_test_protocol` | Every game message round-trips. Snapshots chunk under the datagram limit. Truncated or garbage input never raises |
| `lua_test_interp` | Interpolation, brief extrapolation, out-of-order packets, partner clock restarts |
| `lua_test_enemy_sync` | Two simulated worlds: pairing by kind + spawn point, client damage → host, host damage/kills → client, no damage echo, late arrival after the host cleared a room, unmatched enemies left alone, position snapping, bandwidth |
| `lua_test_game_adapter` | `game.lua` against a mock of REFramework's object model: player/skeleton reading, enemy list, the HP setter with Int32 rounding, the field-write fallback, the kill fallback, teleport + `CharacterController.warp`, exceptions swallowed, type dump |
| `lua_test_integration` | The **real entry script** hosts through its UI button against the mocked game. A second session joins over **real UDP on 127.0.0.1**. Covers handshake, ghosts drawn on both sides, enemy damage/kill sync, chat, teleport, surviving "Reset Scripts", leave/rejoin, settings saved |
| `lua_test_entry_guards` | Script stays inert outside RE4. Clear message when the DLL is missing. Protocol-mismatch handling |

The Lua tests run in `re4coop_lua_runner`. It uses the same Lua 5.4.3 as REFramework, removes
the `io` library like REFramework does, and registers the real `re4coop_net` bindings.

CI runs everything on Linux and on Windows (MSVC). The Windows run also builds the release
zip.

The mock (`tests/lua/mock_reframework.lua`) only checks that the code agrees with the API
*shapes* found during research. It is not the game. The checklist below is the real
acceptance test.

## In-game acceptance checklist

Use two PCs on the same network, both with the same RE4 version, REFramework build and
re4coop zip.

1. **Install check**: open the REFramework menu (Insert) → *RE4 Co-op (LAN)*. You should see
   the panel, not "re4coop_net.dll is not loaded".
2. **Diagnostics**: expand *Diagnostics* while in game (not on the title screen). Expected
   `[ok]` rows: `player`, `enemy_list` (once enemies exist), `hitpoint_type`, `enemy_set_hp`,
   `enemy_kill`, `ghost_skeleton`. Click **Write type dump** and keep
   `reframework/data/re4coop_typedump.json` for bug reports.
3. **Connect**: PC A loads a chapter save and clicks *Host game*. PC B loads the same save,
   types one of A's listed addresses, and clicks *Join game*. Both HUDs show the partner's name
   and ping.
4. **Ghost**: walk around on A. B should see a skeleton that follows A's body (arms and legs
   animate) with a name tag and HP bar, and the same the other way.
5. **Enemy damage (client → host)**: B shoots a Ganado. A sees that enemy's HP drop. A
   health-bar mod helps here, or watch for the enemy dying sooner.
6. **Enemy kill (host → client)**: A kills an enemy. B's copy of it dies.
7. **Late arrival**: A clears a room alone. B walks in afterwards and should not have to fight
   the same enemies.
8. **Teleport**: B clicks *Teleport to partner* and lands next to A.
9. **Pause/menus**: A opens the inventory for 30 s. The session stays connected.
10. **Reset Scripts**: on A, REFramework → ScriptRunner → *Reset scripts*. The co-op session
    continues and the ghost comes back.
11. **Disconnect**: B quits the game. A's HUD shows the disconnect within about 10 s and A is
    hosting again. B can rejoin.

Please report failures with the step number, both `re4coop_typedump.json` files and
`re2_framework_log.txt` (REFramework's log, which has this name in every game).
