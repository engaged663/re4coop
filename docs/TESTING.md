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
| `lua_test_protocol` | Every game message round-trips, including PLAYER stage/chapter/waiting fields, ENEMY_HIT, ITEM_DROPPED, AVATAR, GEAR, chunked POSE and ACTIONS with every argument type, and the `chainsaw.ContextID` in enemy snapshots, damage and ITEM_TAKEN. **Protocol 6**: enemy animation and client ownership in snapshots, ENEMY_CLIENT (capped), GUID flags in batches, flag words (full copies across chunks, a 255-byte group name, 400 masks), gimmick records (the largest possible one too), objects, cutscenes and world sync markers. Quaternion packing stays under 0.3° on 20,000 random rotations. Every message stays under the datagram limit. Fragments reassemble, and an out-of-sequence piece drops the partial message. Truncated or garbage input never raises |
| `lua_test_gate` | Transition gate: short events never hold, long events hold until the partner stands nearby or enters the same event, a different event far away doesn't count, F8 continues alone without re-holding, disconnect releases, partner loading keeps the hold, chapter gate only after both were in the same chapter, the player behind is never held |
| `lua_test_drop_sync` | Identical drops: the host sends the item its enemy dropped (not far, late or key items), the client waits until its own drop hook was seen, suppresses paired enemies only, spawns at its copy's position, verifies the spawn, switches off if the spawn never appears or errors, tolerates a later miss, ignores unpaired enemies, remembers pairs of dead enemies |
| `lua_test_avatar` | The character sync offline: AVATAR/GEAR sent once and again after a reset or costume change, poses rate-limited and only sent with matching descriptions, chunked poses interpolated (joints never extrapolate, the root briefly does), weapon placement dropped without its GEAR, events played on the delayed animation timeline and stale ones dropped |
| `lua_test_interp` | Interpolation, brief extrapolation, out-of-order packets, partner clock restarts |
| `lua_test_enemy_sync` | Two simulated worlds (also: **hits** replay on the other side in both directions, unpaired hits matched by spawn, tracers, replay switched off, unrestorable replay HP not counted twice, host damage between scans not overwritten): pairing by kind + spawn point, and by **spawner ContextID only once trusted** (three agreeing spatial pairings, none disagreeing; one disagreement disables it; spawner IDs shared by several enemies pair by position only), client damage → host, host damage/kills → client, no damage echo, late arrival after the host cleared a room, unmatched enemies left alone, position snapping, bandwidth. **Ownership and mirroring**: the client's copy follows the host's enemy smoothly (position and facing, the short way round ±π) with its AI off; an enemy near the client is handed to the client (its AI runs there, the host mirrors it with its AI off) and back with hysteresis; never handed over without a client copy or a partner nearby; animation mirrored without restarting it; mirroring switched off keeps everything local; a mirrored enemy gets its AI back before it dies; a **wave enemy spawning where another died is not killed**; client kills where the host had no enemy apply when it spawns there (once); a host reload forgets old deaths |
| `lua_test_items_sync` | Key items exist once (also: **inventory "obtained" flag** confirms pickups anywhere, late flags still confirm, an already-set flag is no signal, proven flags ignore unconfirmed vanishes, only-copy matching in the same stage, removals without effect are reported): a pickup removes the partner's copy (again after an area reload). An area unloading far away, or a stale sighting after a loading screen, is never treated as a pickup. Ordinary items stay separate. Matching works without a ContextID, by level ContextID across positions, and **never by runtime ContextIDs**. Simultaneous pickups don't remove anything retroactively. **Pickup callbacks**: a confirmed pickup counts even during the key-item screen or an area swap, a late callback still confirms, a callback for an item that stays is ignored, and once callbacks are proven an unconfirmed disappearance is not a pickup |
| `lua_test_world_sync` | Flags, gimmicks, objects and cutscenes between two simulated games through the real codec: flags both ways without echo, clears, repeated sets not resent, flapping flags muted, full flag copy for a joining client, word deltas when setter hooks are missing; gimmick changes both ways with the host as referee, conflicts converge, **a change the game announces (pushDirtyList) goes out within a second**, **new records never overwrite the partner's** (the host answers with its own state, area loads are not sent), the full table for a joining client; broken crates and killed crows both ways, area unloads ignored, events waiting for objects that are not loaded, history for late joiners; cutscenes played once on both sides, triggered by both = one, travel before the replay, other chapters dropped |
| `lua_test_travel` | The travel state machine: same-stage warp, stage preload, chapter switch + reload + world sync + warp, title screen, one reload offer, following a moving partner, retries and failure reporting |
| `lua_test_session` | Session-level shared world: reliable world messages kept while the game loop is not running (enemy snapshots dropped), **joining**: world request → host's state → warp next to the host; from another chapter: chapter switch armed, reload started, world requested once there; from the title screen: the next load redirected; following the host into a later chapter after the delay (never back to an earlier one); **F6 loads the chapter the host waits in**; cross-stage teleports use the game's warp; the partner's cutscene plays here and ours is announced; the host answers world requests; a host reload resets the client's death records; no-pause follows hosting/connection/leaving; shutdown restores pauses, enemy AI and the chapter switch |
| `lua_test_world_adapter` | `game_world.lua`, `game_pause.lua` and the enemy mirroring in `game.lua` against the mock: methods found by signature (a flag watcher, preloads, stops and queries are never hooked), flag hooks report the game's changes but not ours, do nothing without a partner and read at most 400 setter calls a second (word diffs take over meanwhile), flag words through save/load with boxed array elements, the gimmick table read (incrementally, 60 per call) and written (arrays resized, new records), pushDirtyList announcements, breakables/animals by GameObject GUID with the three ways to apply a destruction, cutscene hooks and replay, stage preload + `requestWarp` (facing, StageIdentifier) and the exact fallback move, chapter switch on the next load (one-shot, a save already in that chapter untouched), game over reload, missing types disabling features quietly, menu pauses neutralised (re-applied after a rebuild, restored, modes *all*/*off*), pause requests refused in aggressive mode; enemy facing, animation (`changeMotion`), mirrored transform with `CharacterController.warp`, the AI head switched off and back on (also before a kill and when the session ends) |
| `lua_test_progression` | Session-level **transition gate** (freezes and restores the time scale, partner gets an instant F6 prompt, F8, "Reset Scripts", disconnect, chapter wait with and without a loaded partner stage, gate switches off if holding stalls the game loop), left-behind prompt timing, **prompt when the partner is in another stage** (not when standing together at a stage boundary, distance rule when the stage is unknown), F6 teleport (edge-triggered), F7 snooze, no prompt during cutscenes, re-teleport after falling through unloaded ground, key-item notices during loading screens |
| `lua_test_game_adapter` | `game.lua` against a mock of REFramework's object model: player state and stage, describing the local Leon (character id, costume parts with mesh/material paths, body + face/hair joints, which joints translate), the weapon in the hand joint, the pose read at the end of the frame, never reading joints of a rebuilt skeleton, hooks capturing sounds/effects/shots on the player's components only (with the fallback for arguments that cannot travel), prefab lookup (Leon, Ada in `_mercenaries`, weapon variants), enemy list with spawner IDs (runtime spawner IDs dropped), the **self-verifying HP writer** (setter found under another name, broken setter rejected, no-op writes prove nothing, max-HP decoy never touched, field fallback, Int32 rounding), the kill fallback, `chainsaw.DropItem` scan and removal (`getItemID()` fallback), the **pickup callback hooks** (static-method argument layout, bounded queue, no hook available), hotkeys, teleport + `CharacterController.warp`, exceptions swallowed, and the **accumulating research dump** (types from earlier areas kept, enum values, the player's hierarchy, per-run log with partner, enemies, HateControllers, motion layers, pickups and the partner model's status; JSON-safe output; log capped at 60 runs). Also the **hit hook** (only the player's hits on enemies), **cosmetic hit replay** (template from our own hit, 1 damage, HP restored now and a frame later, never on nearly dead enemies, our own replay not re-sent), the **drop hook** (reports enemy drops, skips suppressed rolls, never boxes), item spawning, inventory flags, scene time scale and the gimmick state-change log |
| `lua_test_puppet` | The partner model in the mocked world, fed by the real capture → wire → receiver path: built from Leon's body prefab found by character id, logic/physics/animation switched off while sound and cloth stay, renamed so the real player keeps its name, the partner's material applied, the unworn default jacket hidden, face and hair rebuilt from meshes, every joint posed (face/hair joints too), hip height, walking and teleports without overshoot, weapon from its prefab in the same hand joint (or the part owning the joint) with its slide, hidden with the partner's, sounds/effects replayed on the copy's own components, muzzle flash fallback, nothing played while hidden, mirror mode without a prefab or by option, rewriting the pose after an animation that cannot be switched off, retry after failures, rebuild after an area unload or costume change, clean shutdown |
| `lua_test_integration` | The **real entry script** hosts through its UI button against the mocked game. A second session joins over **real UDP on 127.0.0.1**. Covers handshake, the host building and animating the client's Leon (prefab, pose, face joints, hip, weapon in hand), the client receiving the host's character, sounds and shots crossing both ways (gunshot from the copy's gun, muzzle flash), no skeleton lines, enemy damage/kill sync, key items both ways (including a pickup confirmed by the hooked game callback), the research-dump button while connected (with the partner model's status), chat, teleport, the left-behind prompt and F6, surviving "Reset Scripts" (model rebuilt), leave/rejoin (model removed), settings saved. Also hits replayed in both directions and an enemy drop arriving on the client |
| `lua_test_integration_world` | The **real entry script** hosts against the mocked game *with its world* (flags, gimmick table, pauses, cutscenes, breakables, warps) and a client joins over **real UDP**: hosting stops menus pausing (cutscenes still pause); the client receives the host's flags and gimmicks and appears next to it; a flag change from each side reaches the other game's setter; a lever announced by the game crosses at once; the host's crow dies and the client's crate breaks on the other side; the host's cutscene plays in the client's game and the host is not frozen; an enemy near the client is handed over (AI on there, off on the host, the host's copy follows) and back; "Reset Scripts" keeps the session and re-applies no-pause and the flag hooks; stopping restores the pauses and every enemy's AI |
| `lua_test_entry_guards` | Script stays inert outside RE4. Clear message when the DLL is missing. A broken world adapter only disables the shared world. Protocol-mismatch handling. Partner in another chapter detected |
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
   `enemy_kill`, `pickups`, `pickup_hook`, `hit_hook`, `drop_hook`; for the shared world
   `flags`, `flag_hooks`, `flag_words`, `gimmicks`, `objects`, `cutscenes`, `cutscene_hooks`,
   `warp`, `chapter_switch`, `no_pause` (and `no_pause_requests`); `enemy_spawner_id` shows how
   many enemies have a level spawner ID; `enemy_set_hp` turns `[ok] verified …` after the first
   synced hit (step 13); later `item_flags` (with a key item nearby), `hit_replay`,
   `time_scale`, `enemy_mirror`, `enemy_motion` and `enemy_ai_switch` (step 12); once connected
   also `avatar`, `gear`, `sound_mirror`, `effect_mirror`, `shots`. Click **Write research
   dump** in a few different areas. Each click adds a run, and nothing is overwritten.
3. **No pause**: A clicks *Host game* and opens the inventory: the world keeps moving (water,
   enemies, the in-game timer). The same for the map, files and the pause menu. A cutscene still
   pauses. *Stop hosting* → the inventory pauses again. If a menu still pauses, tick *Options →
   Pauses → Also refuse pause requests* and try again.
4. **Join the same chapter**: A plays chapter 1 somewhere in the village. B loads an earlier
   save of chapter 1 and clicks *Join game*. B's HUD shows "Travelling to …", the log says
   "World synchronised with the host", and B appears next to A. Doors A opened, items A picked
   up and the current objective/map match on B.
5. **Join from elsewhere**: B loads a different chapter (or stays on the title screen) and
   joins. The game over screen appears (or B loads any save): B picks *Continue* and loads into
   A's chapter, then appears next to A.
6. **Partner model**: on each PC, the partner appears as Leon (not a stick figure) wearing the
   same costume. *Diagnostics* → *Partner model: ready (prefab) - ch0a0z0*, with all joints
   animated. Walk around the partner: no extra jacket or missing head/hair.
7. **Every state**: on A, walk, run, crouch, turn, aim each weapon type, shoot, reload, knife,
   parry, kick a stunned enemy, climb a ladder, jump through a window, heal, get grabbed, die.
   B sees each animation, with the weapon in Leon's hand (no gap), the slide moving.
8. **Shots and sound**: A fires. B hears the gunshot from A's position (louder when close),
   sees a muzzle flash, hears A's reloads and footsteps.
9. **Doors, keys, levers**: A unlocks a door with a key / pulls a lever / solves a puzzle. On B
   the door is usable (after re-entering the area if it was loaded) and the lever is down.
   *Diagnostics → gimmicks* counters go up on both sides.
10. **Breakables and animals**: A breaks a crate and shoots a crow; B's crate breaks and the
    crow dies. B breaks a barrel; it breaks on A. A breaks a crate B has not reached yet: when B
    gets there, it is already broken.
11. **Cutscene**: A walks into a cutscene trigger. B's game plays the same cutscene (B is
    brought next to A first if elsewhere) and A's game does not wait. Afterwards both continue
    from the same place.
12. **Enemies for both**: both stand in a room with Ganados, B a bit away from A. Enemies near
    B attack B, enemies near A attack A, and each enemy stands in the same place on both
    screens, doing the same thing. Walk past each other: enemies change hands without jumping.
    *Diagnostics → enemy ownership* counts hand-overs, mirrored moves and animations. If enemies
    jitter or freeze on one screen, untick, one at a time, *...play the same animation*,
    *...with their AI switched off*, *Same enemy positions on both screens*, and tell us which
    one fixed it.
13. **HP and kills**: B shoots an enemy without killing it. Within a second A's copy loses the
    same HP, and the same the other way. A kills one: B's copy dies. *Diagnostics* shows
    `[ok] enemy_set_hp: verified …` after the first hit.
14. **Late arrival, both ways**: A clears a room alone; B walks in afterwards and the enemies
    are already dead. Then B clears the next room alone; when A gets there, those enemies die
    at once.
15. **Key items**: A picks up a key item (e.g. the Wooden Cog). On B it disappears and B's HUD
    says "Partner picked up a key item".
16. **Left behind / travel**: A goes through a door into the next stage. After ~6 s B's HUD
    offers a teleport; **F6** warps B into A's stage next to A (the stage loads first). *Travel
    to partner* does the same from anywhere.
17. **Partner's hits and drops**: A shoots an enemy B can see: B's copy flinches and a yellow
    line runs from A's character to it. Killed enemies drop the same item for both.
18. **Transition gate and chapters**: A finishes a chapter part while B is behind. A waits
    ("Waiting for B…"); B is told to finish the part or press **F6** to load it. If B does
    nothing, B's game follows into A's chapter after about 15 s (game over → *Continue*).
19. **Reset Scripts**: on A, REFramework → ScriptRunner → *Reset scripts*. The co-op session
    continues, the partner's model is rebuilt, the inventory still doesn't pause, and a paused
    game (step 18) is never left paused.
20. **Disconnect**: B quits the game. A's HUD shows the disconnect within about 10 s, B's model
    disappears, every enemy behaves normally again, and A is hosting again. B can rejoin.

If a step fails, switch off the matching option in *Options* to keep playing. Please report
failures with the step number, plus these files from both PCs:
`reframework/data/re4coop_typedump.json` and `reframework/data/re4coop_research_log.json`
(from *Diagnostics → Write research dump*, clicked in game with enemies and items nearby,
ideally in several areas), and `re2_framework_log.txt` (REFramework's log, which has this
name in every game).
