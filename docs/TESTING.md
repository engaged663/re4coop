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
| `plugin_load` (Windows) | Loads `re4coop_net.dll` exactly like REFramework's PluginLoader: version and **game-name gate (`"RE4"`)**, initialization, then the Lua callback on a state owned by a *separate* Lua copy. Lua errors unwind across the DLL boundary, and UDP loopback works through the DLL |
| `lua_test_bindings` | The `re4coop_net` C API: bad arguments raise catchable Lua errors, failures return `nil, message` (port in use, double host, unresolvable host), binary-safe payloads between two sessions |
| `lua_test_protocol` | Every game message round-trips, including PLAYER stage/chapter/waiting fields, ENEMY_HIT, ITEM_DROPPED, AVATAR, GEAR, chunked POSE and ACTIONS with every argument type, and the `chainsaw.ContextID` in enemy snapshots, damage and ITEM_TAKEN. Quaternion packing stays under 0.3° on 20,000 random rotations. POSE chunks and enemy snapshots stay under the datagram limit. Fragments reassemble, and an out-of-sequence piece drops the partial message. Truncated or garbage input never raises |
| `lua_test_gate` | Transition gate: short events never hold, long events hold until the partner stands nearby or enters the same event, a different event far away doesn't count, F8 continues alone without re-holding, disconnect releases, partner loading keeps the hold, chapter gate only after both were in the same chapter, the player behind is never held |
| `lua_test_drop_sync` | Identical drops: the host sends the item its enemy dropped (not far, late or key items), the client waits until its own drop hook was seen, suppresses paired enemies only, spawns at its copy's position, verifies the spawn, switches off if the spawn never appears or errors, tolerates a later miss, ignores unpaired enemies, remembers pairs of dead enemies |
| `lua_test_avatar` | The character sync offline: AVATAR/GEAR sent once and again after a reset or costume change, poses rate-limited and only sent with matching descriptions, chunked poses interpolated (joints never extrapolate, the root briefly does), weapon placement dropped without its GEAR, events played on the delayed animation timeline and stale ones dropped |
| `lua_test_interp` | Interpolation, brief extrapolation, out-of-order packets, partner clock restarts |
| `lua_test_enemy_sync` | Two simulated worlds (also: **hits** replay on the other side in both directions, unpaired hits matched by spawn, tracers, replay switched off, unrestorable replay HP not counted twice, host damage between scans not overwritten): pairing by kind + spawn point, and by **spawner ContextID only once trusted** (three agreeing spatial pairings, none disagreeing; one disagreement disables it; spawner IDs shared by several enemies pair by position only), client damage → host, host damage/kills → client, no damage echo, late arrival after the host cleared a room, unmatched enemies left alone, position snapping, bandwidth |
| `lua_test_items_sync` | Key items exist once (also: **inventory "obtained" flag** confirms pickups anywhere, late flags still confirm, an already-set flag is no signal, proven flags ignore unconfirmed vanishes, only-copy matching in the same stage, removals without effect are reported): a pickup removes the partner's copy (again after an area reload). An area unloading far away, or a stale sighting after a loading screen, is never treated as a pickup. Ordinary items stay separate. Matching works without a ContextID, by level ContextID across positions, and **never by runtime ContextIDs**. Simultaneous pickups don't remove anything retroactively. **Pickup callbacks**: a confirmed pickup counts even during the key-item screen or an area swap, a late callback still confirms, a callback for an item that stays is ignored, and once callbacks are proven an unconfirmed disappearance is not a pickup |
| `lua_test_progression` | Session-level **transition gate** (freezes and restores the time scale, partner gets an instant F6 prompt, F8, "Reset Scripts", disconnect, chapter wait with and without a loaded partner stage, gate switches off if holding stalls the game loop), left-behind prompt timing, **prompt when the partner is in another stage** (not when standing together at a stage boundary, distance rule when the stage is unknown), F6 teleport (edge-triggered), F7 snooze, no prompt during cutscenes, re-teleport after falling through unloaded ground, key-item notices during loading screens |
| `lua_test_game_adapter` | `game.lua` against a mock of REFramework's object model: player state and stage, describing the local Leon (character id, costume parts with mesh/material paths, body + face/hair joints, which joints translate), the weapon in the hand joint, the pose read at the end of the frame, never reading joints of a rebuilt skeleton, hooks capturing sounds/effects/shots on the player's components only (with the fallback for arguments that cannot travel), prefab lookup (Leon, Ada in `_mercenaries`, weapon variants), enemy list with spawner IDs (runtime spawner IDs dropped), the **self-verifying HP writer** (setter found under another name, broken setter rejected, no-op writes prove nothing, max-HP decoy never touched, field fallback, Int32 rounding), the kill fallback, `chainsaw.DropItem` scan and removal (`getItemID()` fallback), the **pickup callback hooks** (static-method argument layout, bounded queue, no hook available), hotkeys, teleport + `CharacterController.warp`, exceptions swallowed, and the **accumulating research dump** (types from earlier areas kept, enum values, the player's hierarchy, per-run log with partner, enemies, HateControllers, motion layers, pickups and the partner model's status; JSON-safe output; log capped at 60 runs). Also the **hit hook** (only the player's hits on enemies), **cosmetic hit replay** (template from our own hit, 1 damage, HP restored now and a frame later, never on nearly dead enemies, our own replay not re-sent), the **drop hook** (reports enemy drops, skips suppressed rolls, never boxes), item spawning, inventory flags, scene time scale and the gimmick state-change log |
| `lua_test_puppet` | The partner model in the mocked world, fed by the real capture → wire → receiver path: built from Leon's body prefab found by character id, logic/physics/animation switched off while sound and cloth stay, renamed so the real player keeps its name, the partner's material applied, the unworn default jacket hidden, face and hair rebuilt from meshes, every joint posed (face/hair joints too), hip height, walking and teleports without overshoot, weapon from its prefab in the same hand joint (or the part owning the joint) with its slide, hidden with the partner's, sounds/effects replayed on the copy's own components, muzzle flash fallback, nothing played while hidden, mirror mode without a prefab or by option, rewriting the pose after an animation that cannot be switched off, retry after failures, rebuild after an area unload or costume change, clean shutdown |
| `lua_test_integration` | The **real entry script** hosts through its UI button against the mocked game. A second session joins over **real UDP on 127.0.0.1**. Covers handshake, the host building and animating the client's Leon (prefab, pose, face joints, hip, weapon in hand), the client receiving the host's character, sounds and shots crossing both ways (gunshot from the copy's gun, muzzle flash), no skeleton lines, enemy damage/kill sync, key items both ways (including a pickup confirmed by the hooked game callback), the research-dump button while connected (with the partner model's status), chat, teleport, the left-behind prompt and F6, surviving "Reset Scripts" (model rebuilt), leave/rejoin (model removed), settings saved. Also hits replayed in both directions and an enemy drop arriving on the client |
| `lua_test_entry_guards` | Script stays inert outside RE4. Clear message when the DLL is missing. Protocol-mismatch handling. Partner in another chapter detected |
| `lua_test_config` | Defaults (partner model, sounds, effects on), saved values sanitized, settings from 0.1 upgraded (ghost and manual prefab path dropped) |

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
   `[ok]` rows: `player`, `joints`, `enemy_list` (once enemies exist), `hitpoint_type`,
   `enemy_kill`, `pickups`, `pickup_hook`, `hit_hook`, `drop_hook`; `enemy_spawner_id` shows how
   many enemies have a level spawner ID; `enemy_set_hp` turns `[ok] verified …` after the first
   synced hit (step 11); later `item_flags` (with a key item nearby), `hit_replay` and
   `time_scale`; once connected also `avatar` (e.g. `ch0a0z0: 4 parts, 350 joints`), `gear`
   (e.g. `wp4000`), `sound_mirror`, `effect_mirror`, `shots`. Click **Write research dump** in a
   few different areas. Each click adds a run, and nothing is overwritten any more.
3. **Connect**: PC A loads a chapter save and clicks *Host game*. PC B loads the same save,
   types one of A's listed addresses, and clicks *Join game*. Both HUDs show the partner's name
   and ping.
4. **Partner model**: on each PC, the partner appears as Leon (not a stick figure) wearing the
   same costume. *Diagnostics* → *Partner model: ready (prefab) - ch0a0z0*, with all joints
   animated. Walk around the partner: no extra jacket or missing head/hair.
5. **Every state**: on A, walk, run, crouch, turn, aim each weapon type, shoot, reload, knife,
   parry, kick a stunned enemy, climb a ladder, jump through a window, heal, get grabbed, die.
   B sees each animation, with the weapon in Leon's hand (no gap), the slide moving.
6. **Shots and sound**: A fires. B hears the gunshot from A's position (louder when close),
   sees a muzzle flash, hears A's reloads and footsteps. *Partner model* counters show
   `sounds`, `effects`/`flashes` and `shots` going up.
7. **Cutscenes and chapters**: during a cutscene on either PC, the partner's model hides and
   comes back after it. If one player loads another chapter, the model hides.
8. **Enemy damage (client → host)**: B shoots a Ganado. A sees that enemy's HP drop. A
   health-bar mod helps here, or watch for the enemy dying sooner.
9. **Enemy kill (host → client)**: A kills an enemy. B's copy of it dies.
10. **Late arrival**: A clears a room alone. B walks in afterwards and should not have to fight
    the same enemies.
11. **HP during fights**: B shoots an enemy without killing it. Within a second A's copy
    loses the same HP, and the same the other way. *Diagnostics* should show
    `[ok] enemy_set_hp: verified …` after the first hit. If it still shows `untested`/`rejected`,
    send the research dump.
12. **Key items**: A picks up a key item (e.g. the Wooden Cog). On B it disappears and B's HUD
    says "Partner picked up a key item". In A's *Diagnostics* the `flag` (or `callback`)
    counter goes up and the event log shows "you took key item …". If it doesn't, send the
    research log (it contains that event log).
13. **Left behind**: A opens a door B can't, and walks 35+ m away, or just through into the
    next stage (*Stage: you …, partner …* differs in the panel). After ~6 s B's HUD offers a
    teleport. **F6** teleports B to A, and **F7** hides the prompt.
14. **Teleport**: B clicks *Teleport to partner* and lands next to A; A's copy of B jumps there
    without sliding through walls.
15. **Pause/menus**: A opens the inventory for 30 s. The session stays connected.
16. **Partner's hits (v0.5)**: both players shoot something once (the first own hit enables
    replays). Then A shoots an enemy B can see: B's copy flinches and a yellow line runs from
    A's character to it. *Diagnostics → hits* counts sent/received/replayed. If the game
    crashes here, switch off *Options → Enemies react to your partner's hits* and report it.
17. **Identical drops (v0.5)**: kill a few enemies. Both players get the same item where the
    enemy died. *Diagnostics → drops* should read `synced`. `off (spawning … failed)` means
    each game rolls its own drops again: please send the research log.
18. **Transition gate (v0.5)**: A walks into a cutscene while B is far away. A's game pauses
    with "Waiting for B…". B's HUD offers F6. After B teleports in, A continues. **F8** on A
    continues alone. If it pauses at the wrong moments (for example at the merchant), switch
    off *Options → Wait for the partner at cutscenes…* and tell us where.
19. **Reset Scripts**: on A, REFramework → ScriptRunner → *Reset scripts*. The co-op session
    continues and the partner's model is rebuilt; a paused game (step 18) is never left paused.
20. **Disconnect**: B quits the game. A's HUD shows the disconnect within about 10 s, B's model
    disappears, and A is hosting again. B can rejoin.

If the model misbehaves (wrong position, logic running, the game reacting to it), tick
*Build partner from meshes only* and repeat 4–6. Please report failures with the step number,
plus these files from both PCs: `reframework/data/re4coop_typedump.json` and
`reframework/data/re4coop_research_log.json` (from *Diagnostics → Write research dump*,
clicked in game with enemies and items nearby, ideally in several areas, and with Ashley or
Luis around once), and `re2_framework_log.txt` (REFramework's log, which has this name in
every game). The log is also what the next features (enemy targeting/animation sync,
identical drops) are built from.
