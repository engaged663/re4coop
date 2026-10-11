# Testing

## Automated tests (no game needed)

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cd build && ctest --output-on-failure
```

| Test | What it proves |
|---|---|
| `native_transport` (`plugin/tests/test_net.cpp`) | Handshake, names, binary-safe payloads, size limits (1200-byte datagrams). 1,500 reliable messages each way under **30% simulated packet loss** arrive exactly once and in order. The **unordered lane** under 30% loss: every message exactly once, later ones overtaking resent earlier ones, the ordered lane unaffected, resends recognised as duplicates. **Resend backoff**: a partner that stops acknowledging gets ~80 resends of 20 packets in 1.5 s instead of ~600. Password, session-full and version-mismatch rejections. Reconnect after a partner restart. Graceful leave and rejoin. Connect timeout, link timeout, LAN address listing |
| `plugin_load` (Windows) | Loads `re4coop_net.dll` exactly like REFramework's PluginLoader: version and **game-name gate (`"RE4"`)**, initialization, then the Lua callback on a state owned by a *separate* Lua copy. Lua errors unwind across the DLL boundary, and UDP loopback works through the DLL |
| `lua_test_bindings` | The `re4coop_net` C API: bad arguments raise catchable Lua errors, failures return `nil, message` (port in use, double host, unresolvable host), binary-safe payloads between two sessions |
| `lua_test_protocol` | Every game message round-trips, including PLAYER stage/chapter/waiting fields, ENEMY_HIT, ITEM_DROPPED, AVATAR, GEAR, chunked POSE and ACTIONS with every argument type, and the `chainsaw.ContextID` in enemy snapshots, damage and ITEM_TAKEN. **Protocol 8**: enemy uids and animation in snapshots, ENEMY_CLIENT (the host enemies the client has, capped), ANIMALS (chunked, GUIDs, rotations, routines, dead flags), GUID flags in batches, flag words (full copies across chunks, a 255-byte group name, 400 masks), gimmick records (the largest possible one too), objects, cutscenes and world sync markers. Quaternion packing stays under 0.3° on 20,000 random rotations. Every message stays under the datagram limit. Fragments reassemble, and an out-of-sequence piece drops the partial message. Truncated or garbage input never raises |
| `lua_test_gate` | Transition gate: short events never hold, long events hold until the partner stands nearby or enters the same event, a different event far away doesn't count, F8 continues alone without re-holding, disconnect releases, partner loading keeps the hold, chapter gate only after both were in the same chapter, the player behind is never held |
| `lua_test_drop_sync` | Per-player loot: nothing is rolled before the hooks have seen one of the game's own rolls; a partner's kill without a game roll is rolled for us once (never twice); a game roll after the partner's kill, or seen in the frame before the death was noticed, is enough; a kind that died by our hand without loot is never rolled for the partner's kills; the waiting time is learned from our own kills, and grows when the game rolls after us (counted as a double); an enemy gone before the roll is counted; a reload forgets enemies but keeps what was learned; switched off |
| `lua_test_perf` | The profiler: averages of top-level spans per frame, nested spans, the worst frame, frames over 4 ms, engine calls per second, `pcall` spans; the perf file every 10 s (and not when switched off); breadcrumbs: urgent ones written at once (at most 20 writes a second), ordinary ones within half a second, newest first, bounded ring, repeats counted, a clean unload marked |
| `lua_test_call_budget` | The real entry script hosting with 10 enemies, 90 pickups and a connected partner on a simulated 60 fps clock: engine calls per second (~7,100; fails above 12,000) and in the worst frame (fails above 1,500); single player under 600 calls a second |
| `lua_test_avatar` | The character sync offline: AVATAR/GEAR sent once and again after a reset or costume change, poses rate-limited and only sent with matching descriptions, chunked poses interpolated (joints move on for at most one pose interval when a pose is late, the root briefly too), weapon placement dropped without its GEAR, events played on the delayed animation timeline and stale ones dropped |
| `lua_test_interp` | Interpolation, brief extrapolation, out-of-order packets, partner clock restarts |
| `lua_test_enemy_sync` | Two simulated worlds talking through the real codec. **Identity**: enemies pair by their level identity wherever each game placed them (a spawn point controller picks different points), never with another enemy standing on the same spot, runtime enemies by kind + spawn point, a context the game reuses for another enemy is a new enemy. **Health**: client damage → host (also before pairing, found by uid), host HP/kills → client, no echo, failed HP writes counted, host damage between scans not overwritten. **Deaths**: a kill in front of the client dies with its own logic (and the client rolls its own loot); an enemy the host killed that the client's level spawns later never appears (erased, no corpse, no loot), also one dead far away; without a spawn param it is killed instead; an erase the game ignores becomes a kill, a refused kill is retried; erasing can be switched off; a joining client gets every enemy dead in the host's save (read over several ticks) and a new list replaces the old one; a corpse the host finds is announced; a stale snapshot never revives a dead enemy, one alive again in the host's world is unburied; client kills the host had not loaded apply when it spawns them; a host reload forgets its deaths, a client reload keeps them; two waves at one door are never confused. **Hits**: replays both ways (experimental switch), unpaired hits found by uid, tracers, unrestorable replay HP not counted twice. **The host runs every enemy**: the client's copy follows the host's enemy smoothly (position, facing the short way round ±π) with its AI off, a copy spawned elsewhere jumps to the host's enemy, an enemy only the client has runs on the client's own AI until the host's level spawns it, the host keeps every AI even for an enemy next to the client that only the client shoots, the host reads animations only for enemies the client has, an enemy the client kills dies with its own AI there and on the host, a copy without news from the host runs on its own for a while, animation mirrored without restarts, mirroring off keeps everything local (HP still synced), switching it off gives the AI back, a mirrored enemy dies or is erased with its AI on; bandwidth |
| `lua_test_animal_sync` | Animals between two simulated games through the real codec: the client's copies of the host's animals follow them (position, flight, animation once per change), only animals near both players and loaded in both games, released after a second without news; a host animal that dies dies in the client's game with its AI running, where the host's died, and never follows again (also when its routine leaves Dead); one the client shoots is released for its own death and reported once; far puppets move every third frame; switching animal sync off gives every animal back and stops the host sending; a client reload starts afresh; traffic for 40 animals |
| `lua_test_items_sync` | Key items exist once (also: **inventory "obtained" flag** confirms pickups anywhere, late flags still confirm, an already-set flag is no signal, proven flags ignore unconfirmed vanishes, only-copy matching in the same stage, removals without effect are reported): a pickup removes the partner's copy (again after an area reload). An area unloading far away, or a stale sighting after a loading screen, is never treated as a pickup. Ordinary items stay separate. Matching works without a ContextID, by level ContextID across positions, and **never by runtime ContextIDs**. Simultaneous pickups don't remove anything retroactively. **Pickup callbacks**: a confirmed pickup counts even during the key-item screen or an area swap, a late callback still confirms, a callback for an item that stays is ignored, and once callbacks are proven an unconfirmed disappearance is not a pickup |
| `lua_test_world_sync` | Flags, gimmicks, objects and cutscenes between two simulated games through the real codec: flags both ways without echo, clears, repeated sets not resent, flapping flags muted, full flag copy for a joining client, word deltas when setter hooks are missing; gimmick changes both ways with the host as referee, conflicts converge, **a change the game announces (pushDirtyList) goes out within a second**, **new records never overwrite the partner's** (the host answers with its own state, area loads are not sent), the full table for a joining client; broken crates and killed crows both ways, area unloads ignored, events waiting for objects that are not loaded, history for late joiners; cutscenes played once on both sides, triggered by both = one, travel before the replay, other chapters dropped |
| `lua_test_travel` | The travel state machine: same-stage warp, stage preload, chapter switch + reload + world sync + warp, title screen, one reload offer, following a moving partner, retries and failure reporting |
| `lua_test_session` | Session-level shared world: reliable world messages kept while the game loop is not running (enemy snapshots dropped) and applied only once the game has run for a moment after loading; **UI actions run on the game thread** (a teleport queued from the render thread waits; leave/host/join may run anywhere but restoring the game waits for the game thread); a disconnect restores enemy AI on the game thread; **joining**: world request → host's state → warp next to the host; from another chapter: chapter switch armed, reload started, world requested once there; from the title screen: the next load redirected; following the host into a later chapter after the delay (never back to an earlier one); **F6 loads the chapter the host waits in**; cross-stage teleports use the game's warp; the partner's cutscene plays here and ours is announced; the host answers world requests; a host reload resets the client's death records; **the host answers an enemies request with every enemy dead in its world** (save backups read over several ticks, after the world transfer's own marker), a client without a world adapter still asks for them, and **a client whose game reloaded takes the host's world again** (only once it had taken it over before, not across chapters); no-pause follows hosting/connection/leaving; shutdown restores pauses, enemy AI and the chapter switch |
| `lua_test_world_adapter` | `game_world.lua`, `game_pause.lua` and the enemy mirroring in `game.lua` against the mock: **animals** (the host reads the ones near both players with position, routine and animation; a client copy leaves `GimmickManager`'s move list and its AI stops, takes the host's transform and animation, goes back on release, never if the game finished its gimmick, dies with `set_Routine(Die)` with its AI running, and leaving gives every animal back except destroyed ones; an animal the partner killed dies instead of being hidden), methods found by signature (a flag watcher, preloads, stops and queries are never hooked), flag hooks report the game's changes but not ours, do nothing without a partner and read at most 400 setter calls a second (word diffs take over meanwhile), flag words through save/load with boxed array elements (live delta reloads only with the experimental switch), the gimmick table read (incrementally, 40 per call; targeted reads of announced gimmicks) and written (arrays resized, new records), pushDirtyList announcements with the announcing gimmick's key, breakables/animals by GameObject GUID (state machine forced only with the experimental switch, hidden otherwise, an object destroyed since the scan left alone), cutscene hooks and replay, stage preload + `requestWarp` with **real `Nullable` structs** (facing, StageIdentifier; experimental) and the exact fallback move, chapter switch on the next load (one-shot, a save already in that chapter untouched), game over reload (experimental), missing types disabling features quietly, menu pauses neutralised but saving/typewriter kept (re-applied after a rebuild, restored, modes *all*/*off*), pause requests refused in aggressive mode; enemy facing, animation (`changeMotion`), mirrored transform with `CharacterController.warp`, the AI head switched off and back on (also before a kill and when the session ends) |
| `lua_test_progression` | Session-level **transition gate** (freezes and restores the time scale, partner gets an instant F6 prompt, F8, "Reset Scripts", disconnect, chapter wait with and without a loaded partner stage, gate switches off if holding stalls the game loop), left-behind prompt timing, **prompt when the partner is in another stage** (not when standing together at a stage boundary, distance rule when the stage is unknown), F6 teleport (edge-triggered), F7 snooze, no prompt during cutscenes, re-teleport after falling through unloaded ground, key-item notices during loading screens |
| `lua_test_game_adapter` | `game.lua` against a mock of REFramework's object model: player state and stage, describing the local Leon (character id, costume parts with mesh/material paths, body + face/hair joints, which joints translate), the weapon in the hand joint, the pose read at the end of the frame, never reading joints of a rebuilt skeleton, hooks capturing sounds/effects/shots on the player's components only (with the fallback for arguments that cannot travel), prefab lookup (Leon, Ada in `_mercenaries`, weapon variants), enemy list with **level identities** (an enemy's own ContextID code; group 12 is level data, runtime group 1 and non-character IDs give none; the same enemy has the same uid on another machine), **erasing** an enemy (`eliminate` + `invalidateSpawn`, its pooled head switched back on first; runtime enemies are not erased), **pooled heads** never left switched off (despawn, reload, a new head for the context), reading the **enemies eliminated in our save** in slices, the **self-verifying HP writer** (setter found under another name, broken setter rejected, no-op writes prove nothing, max-HP decoy never touched, field fallback, Int32 rounding), the kill fallback, `chainsaw.DropItem` scan and removal (`getItemID()` fallback), the **pickup callback hooks** (static-method argument layout, bounded queue, no hook available), hotkeys, teleport + `CharacterController.warp`, exceptions swallowed, and the **accumulating research dump** (types from earlier areas kept, enum values, the player's hierarchy, per-run log with partner, enemies, HateControllers, motion layers, pickups and the partner model's status; JSON-safe output; log capped at 60 runs). Also the **hit hook** (installed when a partner connects, idle without one; only the player's hits on enemies), **cosmetic hit replay** (experimental; template from our own hit of this scene, our live body as attacker, dead objects cleared, dropped on reload, 1 damage, HP restored now and a frame later, never on nearly dead enemies, our own replay not re-sent), the **drop hooks** (the game's request → stack → generate path with our player as `cc` and the enemy as `order`; boxes ignored; our own roll for a partner's kill goes to our player, from that enemy, and never on an enemy whose body is gone), inventory flags, scene time scale and the gimmick state-change log |
| `lua_test_puppet` | The partner model in the mocked world, fed by the real capture → wire → receiver path (muzzle flashes outlive their effect; a costume change that swaps a mesh on the same object is noticed by the cheap check): built from Leon's body prefab found by character id, logic/physics/animation switched off while sound and cloth stay, renamed so the real player keeps its name, the partner's material applied, the unworn default jacket hidden, face and hair rebuilt from meshes, every joint posed (face/hair joints too), hip height, walking and teleports without overshoot, weapon from its prefab in the same hand joint (or the part owning the joint) with its slide, hidden with the partner's, sounds/effects replayed on the copy's own components, muzzle flash fallback, nothing played while hidden, mirror mode without a prefab or by option, rewriting the pose after an animation that cannot be switched off, retry after failures, rebuild after an area unload or costume change, clean shutdown |
| `lua_test_integration` | The **real entry script** hosts through its UI button against the mocked game. A second session joins over **real UDP on 127.0.0.1**. Covers handshake, the host building and animating the client's Leon (prefab, pose, face joints, hip, weapon in hand), the client receiving the host's character, sounds and shots crossing both ways (gunshot from the copy's gun, muzzle flash), no skeleton lines, enemy damage/kill sync, key items both ways (including a pickup confirmed by the hooked game callback), the research-dump button while connected (with the partner model's status), chat, teleport, the left-behind prompt and F6, surviving "Reset Scripts" (model rebuilt), leave/rejoin (model removed), settings saved. Also hits replayed in both directions (experimental switch on) and **loot for the partner's kill**: the client kills an enemy, the host's copy dies through enemy sync and the host rolls that enemy's loot for its own player, exactly once |
| `lua_test_integration_world` | The **real entry script** hosts against the mocked game *with its world* (flags, gimmick table, pauses, cutscenes, breakables, warps) and a client joins over **real UDP**: hosting stops menus pausing (cutscenes still pause); the client receives the host's flags and gimmicks and appears next to it; a flag change from each side reaches the other game's setter; a lever announced by the game crosses at once; the host's crow dies and the client's crate breaks on the other side; the host's cutscene plays in the client's game and the host is not frozen; **enemies by level identity**: an enemy the host's save has eliminated (from an earlier session) never appears for the client, a villager each game placed elsewhere pairs by its ID and the client's copy goes where the host's is, the host's kill crosses; **a client reload** brings that enemy back in the client's game and it is removed again while the host's world is taken over again; a crow near both players follows the host's (its AI off on the client) and one the client shoots dies on both sides; an enemy next to the client is still run by the host (its AI stays on there, the client's copy follows); "Reset Scripts" keeps the session and re-applies no-pause and the flag hooks; stopping restores the pauses and every enemy's AI |
| `lua_test_entry_guards` | Script stays inert outside RE4. Clear message when the DLL is missing. A broken world adapter only disables the shared world. Protocol-mismatch handling. Partner in another chapter detected |
| `lua_test_config` | Defaults (partner model, sounds, effects on; experimental features off), saved values sanitized, settings from 0.1 upgraded (ghost and manual prefab path dropped), **0.6 settings upgraded once** (risky features back to off, new rates) while the player's later choices stick; 0.7 enemy settings come back on once and the ownership switches are gone |

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
2. **Diagnostics**: expand *Diagnostics* while in game (not on the title screen). *Performance*
   shows the mod's cost per frame: in single player it should be close to 0 ms; connected,
   note the average, the worst frame and the busiest parts (and send `re4coop_perf.json`).
   Expected `[ok]` rows: `player`, `joints`, `enemy_list` (once enemies exist), `hitpoint_type`,
   `enemy_kill`, `pickups`, `pickup_hook`; once connected `hit_hook`, `drop_hook`,
   `drop_request`, `gimmick_hook`; for the shared world
   `flags`, `flag_hooks`, `flag_words`, `gimmicks`, `objects`, `animal_puppets`, `cutscenes`, `cutscene_hooks`,
   `chapter_switch`, `no_pause` (and `no_pause_requests`); `enemy_uid` shows how many
   enemies have a level identity (all of them, normally); once connected `enemy_erase` and, on the
   host, `enemy_backups` (after the client joined); `enemy_set_hp` turns `[ok] verified …` after the first
   synced hit (step 13); later `item_flags` (with a key item nearby), `hit_replay`,
   `time_scale`, `enemy_mirror`, `enemy_motion` and `enemy_ai_switch` (step 12); once connected
   also `avatar`, `gear`, `sound_mirror`, `effect_mirror`, `shots`. Click **Write research
   dump** in a few different areas. Each click adds a run, and nothing is overwritten.
3. **No pause**: A clicks *Host game* and opens the inventory: the world keeps moving (water,
   enemies, the in-game timer). The same for the map, files and the pause menu. A cutscene, the
   typewriter and the merchant still pause. *Stop hosting* → the inventory pauses again. If a menu still pauses, tick *Options →
   Pauses → Also refuse pause requests* and try again.
4. **Join the same chapter**: A plays chapter 1 somewhere in the village. B loads an earlier
   save of chapter 1 and clicks *Join game*. B's HUD shows "Travelling to …", the log says
   "World synchronised with the host", and B appears next to A. Doors A opened, items A picked
   up and the current objective/map match on B.
5. **Join from elsewhere**: B loads a different chapter (or stays on the title screen) and
   joins, then loads any save (or *Continue*): the game loads into A's chapter and B appears
   next to A. (With *Experimental → Load the partner's chapter automatically*, the game over
   screen appears by itself.)
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
    crow dies (it falls, it does not vanish). B breaks a barrel; it breaks on A. A breaks a crate
    B has not reached yet: when B gets there, it is already broken. **Animals follow the host**:
    near crows, chickens or fish, both players watch the same animal: it moves, flies off and
    lands the same way on both screens (*Diagnostics → animals* counts the ones following and
    `animal_puppets` reads `[ok]`). B shoots a crow that is following A's: it dies on B's screen
    at once and on A's a moment later.
11. **Cutscene**: A walks into a cutscene trigger while B is elsewhere: A waits after 1.5 s
    ("Waiting for B…"), B gets an F6 prompt; when B arrives, A's cutscene continues and B's
    game plays it when B walks into it. (*Experimental → A cutscene one player triggers starts
    in the partner's game* tries starting it in B's game directly.)
12. **The host runs every enemy**: both stand in a room with Ganados (and dogs), B a bit away
    from A. *Diagnostics* → `enemy_uid` reads `[ok] N of N enemies have a level identity` and
    *enemy sync* shows the pairs made by ID. Every enemy stands in the same place on both
    screens, doing the same thing, also the ones right next to B; they go for A (the host's
    game decides, and its enemies only target A's character). *Diagnostics → enemy puppets* on B
    counts the enemies following A's, their moves and animations. B runs ahead into an area A
    has not loaded: those enemies fight B with B's own AI, and once A gets close enough for A's
    level to spawn them, B's copies take A's positions. If enemies jitter on B's screen, untick
    *Client: enemies and animals play the host's animation*, then *Client: enemies stand and
    move where the host's are*, and tell us which one fixed it.
13. **HP and kills**: B shoots an enemy without killing it. Within a second A's copy loses the
    same HP, and the same the other way. A kills one in front of B: B's copy dies with its own
    death animation. *Diagnostics* shows `[ok] enemy_set_hp: verified …` after the first hit.
14. **Dead stays dead**: A clears a room alone; B walks in afterwards: none of those enemies
    appears for B (no corpses either; *enemy deaths* counts them as erased). Then B clears the
    next room alone; when A gets there, those enemies never appear for A. **Kills from before
    the session**: A loads a save where a room is already cleared, B a save where it is not; B
    joins: `enemy_backups` on A reads `[ok] … eliminated`, and those enemies never appear for B.
    **Reload**: B dies and reloads the checkpoint: the enemies A killed since then do not come
    back for B (B's log says it took over the host's world again).
15. **Key items**: A picks up a key item (e.g. the Wooden Cog). On B it disappears and B's HUD
    says "Partner picked up a key item".
16. **Left behind**: A goes through a door into the next stage. After ~6 s B's HUD offers a
    teleport; **F6** moves B next to A. (Cross-stage warps through the game's own loader are
    *Experimental*.)
17. **Partner's hits and loot**: A shoots an enemy near B: on B's screen it reacts to A's
    shots (B's copy follows A's game), and a yellow line runs from A's character to it. B shoots
    one: its HP drops on both screens within a second. A kills an enemy:
    both get loot, rolled for each player's own inventory (often different items).
    *Diagnostics → loot* counts the partner's kills and the rolls made for them. Then
    `re4coop_research_log.json` (*Write research dump*) lists `drop_calls`: please send it.
18. **Transition gate and chapters**: A finishes a chapter part while B is behind. A waits
    ("Waiting for B…"); B is told to finish the part. If B does nothing, B's game is armed to
    follow into A's chapter after about 15 s (load a save or *Continue*).
19. **Reset Scripts**: on A, REFramework → ScriptRunner → *Reset scripts*. The co-op session
    continues, the partner's model is rebuilt, the inventory still doesn't pause, and a paused
    game (step 18) is never left paused.
20. **Disconnect**: B quits the game. A's HUD shows the disconnect within about 10 s, B's model
    disappears, every enemy behaves normally again, and A is hosting again. B can rejoin.
21. **Experimental switches**: only once 1–20 work, switch one experimental feature on at a
    time (*Options → Experimental*) and repeat the step it belongs to. If the game crashes, the
    breadcrumb file names it.

If a step fails, switch off the matching option in *Options* to keep playing. **After a crash**,
send `reframework/data/re4coop_breadcrumb.json` from the PC that crashed (it lists the last
things the mod did, newest first, with frame numbers) and the crash dump. Please report
failures with the step number, plus these files from both PCs:
`reframework/data/re4coop_typedump.json` and `reframework/data/re4coop_research_log.json`
(from *Diagnostics → Write research dump*, clicked in game with enemies and items nearby,
ideally in several areas), and `re2_framework_log.txt` (REFramework's log, which has this
name in every game).
