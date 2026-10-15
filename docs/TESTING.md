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
| `lua_test_bindings` | The `re4coop_net` C API (with `window_focused`): bad arguments raise catchable Lua errors, failures return `nil, message` (port in use, double host, unresolvable host), binary-safe payloads between two sessions |
| `lua_test_protocol` | Every game message round-trips, including PLAYER stage/chapter/waiting fields, ITEM_DROPPED, AVATAR, GEAR, chunked POSE and ACTIONS with every argument type, and the `chainsaw.ContextID` in ITEM_TAKEN. **Protocol 9**: ENEMY_STATE packed into as few datagrams as fit (ownership epoch, uid or spawn point, full rotation, velocity, HP, hit ack, visibility, up to three animation layers), ENEMY_HIT with every kind of DamageInfo value (int, float, bool, vector, uint, int64, double; capped at 64 and always one datagram), ENEMY_DEATH (killing hit, erased, reset), ENEMY_OWNER (chunked, retired ids), ENEMY_ROSTER (chunked), the graveyard; the retired enemy messages are unknown; **protocol 13**: ENEMY_STATE's partner info and finisher type, ENEMY_DEATH's client-kill flag, ENEMY_FATAL (kind, finisher type, the player's place), PLAYER_NOISE (at most 16 noises), PLAYER_DAMAGE (the attacking enemy, the attack's id and key, every hit value), the retired bounce flag; ANIMALS (chunked, GUIDs, rotations, routines, dead flags), GUID flags in batches, flag words (full copies across chunks, a 255-byte group name, 400 masks), gimmick records (the largest possible one too), objects, cutscenes and world sync markers. Quaternion packing stays under 0.3° on 20,000 random rotations. Every message stays under the datagram limit. Fragments reassemble, and an out-of-sequence piece drops the partial message. Truncated or garbage input never raises **Protocol 14**: ACTION_SIGN (flags, sign type, button), ENEMY_PARRY (parry or press), PLAYER_GRAB (held or let go, presses capped at 255, knife, action) and GRAB_ESCAPE, PLAYER_DAMAGE's grab flag and priority. |
| `lua_test_gate` | Transition gate: short events never hold, long events hold until the partner stands nearby or enters the same event, a different event far away doesn't count, F8 continues alone without re-holding, disconnect releases, partner loading keeps the hold, chapter gate only after both were in the same chapter, the player behind is never held |
| `lua_test_drop_sync` | Per-player loot: nothing is rolled before the hooks have seen one of the game's own rolls; a partner's kill without a game roll is rolled for us once (never twice); a game roll after the partner's kill, or seen in the frame before the death was noticed, is enough; a kind that died by our hand without loot is never rolled for the partner's kills; the waiting time is learned from our own kills, and grows when the game rolls after us (counted as a double); an enemy gone before the roll is counted; a reload forgets enemies but keeps what was learned; switched off |
| `lua_test_perf` | The profiler: averages of top-level spans per frame, nested spans, the worst frame, frames over 4 ms, engine calls per second, `pcall` spans; the perf file every 10 s (and not when switched off); breadcrumbs: urgent ones written at once (at most 20 writes a second), ordinary ones within half a second, newest first, bounded ring, repeats counted, a clean unload marked |
| `lua_test_call_budget` | The real entry script hosting with 10 enemies, 90 pickups and a connected partner on a simulated 60 fps clock: engine calls per second (~6,500; fails above 12,000) and in the worst frame (fails above 1,500); single player under 600 calls a second |
| `lua_test_avatar` | The character sync offline: AVATAR/GEAR sent once and again after a reset or costume change, poses rate-limited and only sent with matching descriptions, chunked poses interpolated (joints move on for at most one pose interval when a pose is late, the root briefly too), weapon placement dropped without its GEAR, events played on the delayed animation timeline and stale ones dropped |
| `lua_test_interp` | Interpolation, brief extrapolation, out-of-order packets, partner clock restarts |
| `lua_test_enemy_net` | Two simulated games running the 0.10 enemy sync (the host runs every enemy) against each other through the real codec. **Identity**: enemies pair by their level identity wherever each game placed them, never with another enemy on the same spot, runtime enemies by kind + spawn point, a context the game reuses is a new enemy (its old number is retired). **Authority**: every enemy is the host's wherever the players are (the client next to it, the host far away, a client that keeps shooting it: it never changes hands); a puppet the game switched back on is switched off again; a host enemy that left the host's world leaves the client's copy waiting unseen. **State**: puppets follow position, full rotation and animation layers smoothly, a copy spawned elsewhere jumps to the host's enemy, the host's visibility and HP show on the puppet. **Hits**: the client's hit is run by the host's game with its values (its reaction goes out at once), the HP of a hit in flight is not given back until the host acknowledged it, a puppet never dies from the client's hit (the host decides; the host's kill is the host's), the host's hits are only shown (tracers), other damage to a puppet goes to the host, without hit code the host applies HP. **Finishers**: the host says which finishers each enemy near the client's character offers it (and which enemies target it); the client's finisher runs in the host's game (a kick with its finisher type), one the host cannot run is counted. **Deaths**: a death the client's hit or finisher caused within 3 s (after the host's last hit) is the client's kill; a boss whose death removes it (El Gigante) dies in the client's game too, also after it unloaded and came back; an enemy that only unloaded is no death, and the client never decides one; dead stays dead for enemies that spawn later (erased far away, a visible death up close); the client's kill of an enemy the host has not loaded; a joining client learns the dead of the host's save; a host reload brings its dead back (and an enemy erased on the client may spawn again); enemies only the client has wait until the host has them, keeping the damage the client did; **a host enemy the client's save had dead** is spawned there and starts where the host's is - never one the client has or just killed, far away, while loading or with the setting off; traffic for 30 enemies |
| `lua_test_partner_target` | The client as a second player in the host's game (`partner_target.lua`) against a fake adapter, through the real codec: the host makes the client's model a target while it can be fought (not in a cutscene, another area, loading, or without a model; let go and taken back), retries an attach that failed, notices a lost model, never attaches when switched off (and without hits when only those are off); **hits on the model go to the client** with the enemy's number, uid, kind, attack id and key (an enemy the client has not loaded: no number); **the client's noises** are batched, a repeated footstep merged, and made in the host's game only while the model is a target; **a host hit lands on the client one interpolation delay later** from its copy of that enemy, dodged hits counted, none while loading, in a cutscene, dead, or with the setting off; shutdown lets go of the model **0.10.1**: the host's warnings reach the client's head one interpolation delay late and every frame while repeated; the client's parry goes to the host and the parried enemy's blow already on its way is not taken; a hold reaches the client with the grab, the presses come from the host's escape check (8 by default), mashing or the knife breaks free and tells the host, a hold the host ends lets go, the host ends a hold after 15 s. |
| `lua_test_animal_sync` | Animals between two simulated games through the real codec: the client's copies of the host's animals follow them (position, flight, animation once per change), only animals near both players and loaded in both games, released after a second without news; a host animal that dies dies in the client's game with its AI running, where the host's died, and never follows again (also when its routine leaves Dead); one the client shoots is released for its own death and reported once; far puppets move every third frame; switching animal sync off gives every animal back and stops the host sending; a client reload starts afresh; traffic for 40 animals |
| `lua_test_items_sync` | Key items exist once (also: **inventory "obtained" flag** confirms pickups anywhere, late flags still confirm, an already-set flag is no signal, proven flags ignore unconfirmed vanishes, only-copy matching in the same stage, removals without effect are reported): a pickup removes the partner's copy (again after an area reload). An area unloading far away, or a stale sighting after a loading screen, is never treated as a pickup. Ordinary items stay separate. Matching works without a ContextID, by level ContextID across positions, and **never by runtime ContextIDs**. Simultaneous pickups don't remove anything retroactively. **Pickup callbacks**: a confirmed pickup counts even during the key-item screen or an area swap, a late callback still confirms, a callback for an item that stays is ignored, and once callbacks are proven an unconfirmed disappearance is not a pickup |
| `lua_test_world_sync` | Flags, gimmicks, objects and cutscenes between two simulated games through the real codec: flags both ways without echo, clears, repeated sets not resent, flapping flags muted, full flag copy for a joining client, word deltas when setter hooks are missing; gimmick changes both ways with the host as referee, conflicts converge, **a change the game announces (pushDirtyList) goes out within a second**, **new records never overwrite the partner's** (the host answers with its own state, area loads are not sent), the full table for a joining client; broken crates and killed crows both ways, area unloads ignored, events waiting for objects that are not loaded, history for late joiners; cutscenes played once on both sides, triggered by both = one, travel before the replay, other chapters dropped |
| `lua_test_save_sync` | Saves for both through the real codec: a host autosave saves the client into its co-op slot (once, never reported back); a client autosave goes to the co-op slot and saves the host into its autosave; a typewriter save stays in the chosen slot and the client's is copied to its co-op slot; the same save in both games is made once; a partner's save waits while the game cannot save (not playing, busy) and is dropped after 90 s; switches and no partner. **Joining from the menus**: only for a joining client once the host is in game, once; the co-op save if there is one, else the latest; no save asks for a New Game; a game over later reloads the co-op slot only once it holds this session's progress. The adapter against the mock (`SaveFlowController.start` reported and redirected, `requestStartSaveGameDataFlow`, busy / excluded, slots), and a real client Session on the title screen: joining turns the game intent on, the title skips to the main menu, Continue loads slot 20 (not the newer slot 3) into the host's chapter |
| `lua_test_mechanism_sync` | Mechanisms through the real codec: a lever's sequence plays in the partner's game (once, not sent back; one use reported twice in a frame is one); a pushed cart moves; a sequence both games start plays once in each, also when the partner's report arrives first; an object not loaded waits, then is left to its saved state; nothing plays while not ready, and a sequence during loading is not sent; the switch. The world adapter against the mock: a lever's `PortrayalSettings.call` reported by GUID and key; doors, sequences with an effect our game cannot mute and gimmick-less portrayals not shared; the partner's sequence played with no trigger, its double skipped (`SKIP_ORIGINAL`), a later use reported again; a push reported once, applied with `MotMove`, the blocker and the flag |
| `lua_test_ashley_sync` | One Ashley for both: two simulated games, each with an Ashley whose AI follows its own player, through the real codec. She **starts with the host** (the client's is a puppet that stands, animates and has the HP of the host's); **a tap on the host sends her to the client** (the client's game runs her, the host's becomes the puppet; taken over 28 m away she is brought behind the client's player, both are told); **the client calls her over** (the host decides; near enough she walks); **the 5 s cooldown** for both players (told how long; the host keeps it even when a client's request left early; the cooldown is a setting); **both pressing at once switch once**; **no switch** while she is kidnapped or busy, when the other game has no Ashley or its player is in a cutscene (each player told why); **she goes over by herself** when the game running her has had none for 5 s (not while that game only loads); the puppet is never let go down; switched off (and released when switched off); a new partner starts with the host; the three messages round-trip. **Her animation in full**: every layer reaches the puppet with its blend rate, joint mask and blend mode, with the owner's bank variant; the owner's dynamic motion banks reach the puppet (sent once, again when they change, every 10 s, at once after each switch; the new owner's after a switch, never the old owner's or another switch's). **Never a second Ashley**: the game not running her makes hers a puppet at once (she never walks to its player) and draws her only once the owner's game said where she is, not while the owner's game hides hers or has none (a pause in its reports keeps her as she was), drawn again when she comes over; **another Ashley is removed in both games** after a moment (not one that only blinks, not during our cutscene, a refused removal tried again later), never while no game has her as a partner (a scripted Ashley alone stays), not when switched off. The adapter against the mock: Ashley found by her kind in `PartnerContextList` (Luis is not her; `getPartnerContextRef` when the list cannot be read), busy states (kidnapped, hiding); **a puppet** neither follows our player nor can be grabbed, attacked or hurt by our game, takes the partner's position, motion and HP (never killed here), and gets her head, animation and damage back (her grab permission set again by her head); her own NoDamage kept; a reload puppets the new Ashley and puts the old one back; `CharacterContext.setTransform` to bring her over; **other Ashleys** (a second partner, doll NPCs of her kind in `DollNpcContextList`) found, ours kept whatever the list order and a doll never taken for ours, removed through their spawn param's `invalidateSpawn`, never through ours, one without a spawn param stopped and hidden with what hangs from it; **her animation** read in full (layers with blend rate, mask, mode; `TargetBankType`; her dynamic banks) and played on the puppet: the bank variant first so a Battle-only motion is found, a motion of a bank only a dynamic bank brings is not found (counted once, named, not asked every tick) until the owner's banks are added through her `MotionController` (motlist, bank, order, overwrite flags; never twice, not one her own game already gave her), then it plays; blend rate, mask and mode set; banks the owner no longer has go, her own game's stay, all ours go (and her variant comes back) when she stops being a puppet; without a `MotionController` straight into `Motion`'s list (closing up on removal); a puppet hidden and drawn again (only what was drawn; released and at the session's end) |
| `lua_test_world_progress` | What one player completes, the other completes (§3.24), the world adapter against the mock: **an item the partner set in a slot** makes our slot react (its own sequence: the item appears, the lock opens) without taking our player's item or handing out the reward again (also at its end), counted, never twice (the partner's report of the same sequence is skipped), not again for the same state; the game's empty method is never hooked; a reaction that unlocks another object keeps that object's end effects too; a gimmick still setting up, or not on screen, only gets the record; doors and the switched-off setting never react; a gimmick already set by itself does nothing. **A lever whose sequence hands out items is shared** and the items stay with the player who pulled it (and our own later pull gives them again); a level event whose sequence kills runs here without the death. **Objectives**: read and shown the game's way (only a higher priority), then two games through the real codec: the more advanced objective shows in both (once, no ping-pong, nothing sent back), not while loading, only in the same chapter; switched off; the message round-trips |
| `lua_test_trap_sync` | Traps through the real codec: a bear trap that closes snaps shut in the partner's game (played once, never reported back) and opens again when re-armed; a sensor bomb that goes off goes off there; a trap not loaded waits for its area; an old report and a joining partner's snapshot are set without playing them; the switch. The world adapter against the mock: states by GUID (Bite = closed, Done = gone), Close with `_Rno` 0 then Closed with the snap and the flag, `requestOpenByEm`, a flagged bomb exploding through its own Wait, spent traps set without a snap or an explosion |
| `lua_test_travel` | The travel state machine: same-stage warp, stage preload, chapter switch + reload + world sync + warp, title screen, one reload offer, following a moving partner, retries and failure reporting |
| `lua_test_session` | Session-level shared world: reliable world messages kept while the game loop is not running (enemy states dropped) and applied only once the game has run for a moment after loading; **UI actions run on the game thread** (a teleport queued from the render thread waits; leave/host/join may run anywhere but restoring the game waits for the game thread); a disconnect restores enemy AI on the game thread; **joining**: world request → host's state → warp next to the host; from another chapter: chapter switch armed, reload started, world requested once there; from the title screen: the next load redirected; following the host into a later chapter after the delay (never back to an earlier one); **F6 loads the chapter the host waits in**; cross-stage teleports use the game's warp; the partner's cutscene plays here and ours is announced; the host answers world requests; a host reload resets the client's death records; **the host answers an enemies request with every enemy dead in its world** (save backups read over several ticks, after the world transfer's own marker), a client without a world adapter still asks for them, and **a client whose game reloaded takes the host's world again** (only once it had taken it over before, not across chapters); no-pause follows hosting/connection/leaving; **a tap of Alt switches Ashley** (host and client: on release, once the game kept the focus 0.25 s; not while held, after a long hold, with Tab/Enter/F4, on an Alt+Tab that takes the focus away, or while aiming - Alt zooms; the key is a setting), the panel's Ashley button runs on the game thread, Ashley's messages are recorded while loading; shutdown and a disconnect restore pauses, enemy AI, Ashley and the chapter switch |
| `lua_test_world_adapter` | `game_world.lua`, `game_pause.lua` and the enemy puppets in `game_enemies.lua` against the mock: **animals** (the host reads the ones near both players with position, routine and animation; a client copy leaves `GimmickManager`'s move list and its AI stops, takes the host's transform and animation, goes back on release, never if the game finished its gimmick, dies with `set_Routine(Die)` with its AI running, and leaving gives every animal back except destroyed ones; an animal the partner killed dies instead of being hidden), methods found by signature (a flag watcher, preloads, stops and queries are never hooked), flag hooks report the game's changes but not ours, do nothing without a partner and read at most 400 setter calls a second (word diffs take over meanwhile), flag words through save/load with boxed array elements (live delta reloads only with the experimental switch), the gimmick table read (incrementally, 40 per call; targeted reads of announced gimmicks) and written (arrays resized, new records), pushDirtyList announcements with the announcing gimmick's key, breakables/animals by GameObject GUID (state machine forced only with the experimental switch, hidden otherwise, an object destroyed since the scan left alone), cutscene hooks and replay, stage preload + `requestWarp` with **real `Nullable` structs** (facing, StageIdentifier; experimental) and the exact fallback move, chapter switch on the next load (one-shot, a save already in that chapter untouched), game over reload (experimental), missing types disabling features quietly, menu pauses neutralised but saving/typewriter kept (re-applied after a rebuild, restored, modes *all*/*off*), pause requests refused in aggressive mode; enemy rotation and animation layers read, the puppet's transform with `CharacterController.warp` and animation (`changeMotion`), the AI head switched off and back on (also before a kill and when the session ends) |
| `lua_test_progression` | Session-level **transition gate** (freezes and restores the time scale, partner gets an instant F6 prompt, F8, "Reset Scripts", disconnect, chapter wait with and without a loaded partner stage, gate switches off if holding stalls the game loop), left-behind prompt timing, **prompt when the partner is in another stage** (not when standing together at a stage boundary, distance rule when the stage is unknown), F6 teleport (edge-triggered), F7 snooze, no prompt during cutscenes, re-teleport after falling through unloaded ground, key-item notices during loading screens |
| `lua_test_game_adapter` | `game.lua` against a mock of REFramework's object model: player state and stage, describing the local Leon (character id, costume parts with mesh/material paths, body + face/hair joints, which joints translate), the weapon in the hand joint, the pose read at the end of the frame, never reading joints of a rebuilt skeleton, hooks capturing sounds/effects/shots on the player's components only (with the fallback for arguments that cannot travel), prefab lookup (Leon, Ada in `_mercenaries`, weapon variants), enemy list with **level identities** (an enemy's own ContextID code; group 12 is level data, runtime group 1 and non-character IDs give none; the same enemy has the same uid on another machine), **erasing** an enemy (`eliminate` + `invalidateSpawn`, its pooled head switched back on first; runtime enemies are not erased), **puppets** (AI head and animation state machine off; pooled heads never left switched off on despawn, reload, a new head for the context), **full rotation and animation layers** read (motion, bank, frame, speed) and written (another motion → `changeMotion`, a drifted frame → `set_Frame`, speed → `set_Speed`, a small drift left to the game), reading the **enemies eliminated in our save** in slices, the **self-verifying HP writer** (setter found under another name, broken setter rejected, no-op writes prove nothing, max-HP decoy never touched, field fallback, Int32 rounding), the kill fallback, `chainsaw.DropItem` scan and removal (`getItemID()` fallback), the **pickup callback hooks** (static-method argument layout, bounded queue, no hook available), hotkeys, teleport + `CharacterController.warp`, exceptions swallowed, and the **accumulating research dump** (types from earlier areas kept, enum values, the player's hierarchy, per-run log with partner, enemies, HateControllers, motion layers, pickups and the partner model's status; JSON-safe output; log capped at 60 runs). Also the **hit hook** (installed when a partner connects, idle without one; every DamageInfo value found by reflection - ints, floats, vectors, enums, a parent type's fields - but no objects and no game-local serials; only the player's hits are reported, every hit is kept as the enemy's last hit; **a hit never kills a puppet** and without prediction takes nothing), **a partner's hit run through the game's hit code** (its values, our live body as attacker, not reported as our own), **a death with its killing hit** (AI and animation driver back on first; without the partner's values a plain killing hit at the chest pushing it back, built from another character's attack data before our player hit anything; only without any, `HitPoint.dead()` and the AI's death action at once), **whether a partner's hit kills is decided by our HP** (`checkKill`: a hit that takes our last HP dies at once instead of walking on, one marked a kill with HP left here only reacts, NoDeath is respected), **a partner's hit carries its attack and body part** (a copy of our attack data made with `doDeepCopy` carrying the shooter's attack type and power, one copy per kind of attack, our own untouched; the collider of the same part and side, else the chest), **spawning an enemy our save had dead** (`enemy_revive`: the eliminated backup removed, the invalidated spawn param validated, an unpermitted one permitted - the game's update spawns it fresh with its uid; "forgotten" without a spawn param, "missing", "dead_here" for a character of ours that died; a living enemy's backup untouched), **whether a level enemy is dead for good here** (`enemy_eliminated`: its live context, else its save backup; unloaded alive or unknown is not), the **drop hooks** (the game's request → stack → generate path with our player as `cc` and the enemy as `order`; boxes ignored; our own roll for a partner's kill goes to our player, from that enemy, and never on an enemy whose body is gone), inventory flags, scene time scale and the gimmick state-change log. **The client as a second player** (`game_partner.lua`): the partner's model becomes a character our enemies fight (a stand-in `ChCommonPlContext` on its body updaters, the player's tag and a registered `TargetMarker`, its damage colliders on and its `HitController` in `HitManager`; the knife question asked with our player's head; everything undone on detach, every enemy's hate dropped); friendly fire and grabs never reach the partner (a grab only with the switch); the partner's noise is made by the model, ours is reported; the puppets' finisher checks answer from the host's information (the knife also from our own player) and their requests go to the host; **a hit from the host's enemy runs on our character like the game runs one** (`checkKill`, the dodge check, the non-lethal clamp, the attack data from the catalog, the copy of the enemy as attacker) **0.10.1**: our blows and bullets pass the partner's model (dropped before `poolDamage`) while enemy blows land; an enemy warning the model is found by polling and by the game's own delivery, and the partner's parry runs `onParry` with the model; a grab holds the model until the escape check succeeds (or the grab is undone as rejected); on the client the host's warning reaches our head, our parry of a copy is reported, a grab runs through `hitSetting`, the escape presses are read from `share.hid.Command` and letting go undoes the copy's grab. |
| `lua_test_puppet` | The partner model in the mocked world, fed by the real capture → wire → receiver path (muzzle flashes outlive their effect; a costume change that swaps a mesh on the same object is noticed by the cheap check): built from Leon's body prefab found by character id, logic/physics/animation switched off while sound and cloth stay, renamed so the real player keeps its name, the partner's material applied, the unworn default jacket hidden, face and hair rebuilt from meshes, every joint posed (face/hair joints too), hip height, walking and teleports without overshoot, weapon from its prefab in the same hand joint (or the part owning the joint) with its slide, hidden with the partner's, sounds/effects replayed on the copy's own components, muzzle flash fallback, nothing played while hidden, mirror mode without a prefab or by option, rewriting the pose after an animation that cannot be switched off, retry after failures, rebuild after an area unload or costume change, clean shutdown; **a scoped rifle never shows its scope view** (its scope camera four levels down, the thermal camera it only references and every render output switched off, the camera object no longer updating; the scope and rifle still drawn) |
| `lua_test_integration` | The **real entry script** hosts through its UI button against the mocked game. A second session joins over **real UDP on 127.0.0.1**. Covers handshake, the host building and animating the client's Leon (prefab, pose, face joints, hip, weapon in hand), the client receiving the host's character, sounds and shots crossing both ways (gunshot from the copy's gun, muzzle flash), no skeleton lines, enemy sync (the client's copies are puppets of the host's, the client's hit runs through the host's own hit code with its values, the host's enemy moves and the client's copy follows, the host's kill crosses, no echo), key items both ways (including a pickup confirmed by the hooked game callback), the research-dump button while connected (with the partner model's status), chat, teleport, the left-behind prompt and F6, surviving "Reset Scripts" (model rebuilt), leave/rejoin (model removed), settings saved. Also the host's hits shown on the client; **the host's enemies see and attack the client end to end** (the client's model is a character of the host's game with the player's tag and marker, standing where the client is; a villager after the client is shown on the client; its attack lands on the client with the attack's identity and damage while the model takes nothing; the host's own shots and a grab never do; the client's noise is made by the model in the host's game; a kick and a stealth kill the client starts run on the host's villager with the client's character as the attacker, and its death is the client's kill); and **a lethal hit from the client**: the client's game leaves the puppet alive, the host's game kills it, the client's copy dies from the killing hit and the client rolls its own loot for it, exactly once **0.10.1 end to end**: the host's blow and bullet pass the client's character, an enemy's warning reaches the client and the client's parry staggers it (its blow not taken), a boss aiming at "the player" turns to the client its hate puts first, and a grab holds the client until it mashes free and the host's enemy lets go. |
| `lua_test_integration_world` | The **real entry script** hosts against the mocked game *with its world* (flags, gimmick table, pauses, cutscenes, breakables, warps) and a client joins over **real UDP**: hosting stops menus pausing (cutscenes still pause); the client receives the host's flags and gimmicks and appears next to it; a flag change from each side reaches the other game's setter; a lever announced by the game crosses at once; the host's crow dies and the client's crate breaks on the other side; the host's cutscene plays in the client's game and the host is not frozen; **enemies by level identity**: an enemy the host's save has eliminated (from an earlier session) never appears for the client, a villager each game placed elsewhere pairs by its ID and the client's copy goes where the host's is, the host's kill crosses; **a client reload** brings that enemy back in the client's game and it is removed again while the host's world is taken over again; a crow near both players follows the host's (its AI off on the client) and one the client shoots dies on both sides; **an enemy next to the client stays the host's**: the client's copy follows the host's whether the client is far from it or right next to it, and the host's game keeps running it; **one Ashley**: the client's follows the host's mock Ashley, the client's player taps Alt and she goes to the client (brought next to the far client, the host's becomes a puppet: head and animation state machine off, no damage, no grabs, and follows the client's), after the cooldown the host's player taps Alt and she comes back (the game's own teleport, damage again); **an item the client places unlocks the host's slot** (its own sequence on the host's screen, nothing taken from or handed to the host's player) **and the client's more advanced objective shows in the host's game** (with the banner); "Reset Scripts" keeps the session and re-applies no-pause and the flag hooks; stopping restores the pauses and every enemy's AI |
| `lua_test_entry_guards` | Script stays inert outside RE4. Clear message when the DLL is missing. A broken world adapter only disables the shared world. Protocol-mismatch handling. Partner in another chapter detected |
| `lua_test_config` | Defaults (partner model, sounds, effects on; experimental features off), saved values sanitized, settings from 0.1 upgraded (ghost and manual prefab path dropped), **0.6 settings upgraded once** (risky features back to off, new rates) while the player's later choices stick; 0.7 enemy settings come back on once and the ownership switches are gone; 0.8 enemy settings start from the defaults once for 0.9's enemy sync (shared authority, hit prediction), and 0.8's host-only and hit-replay switches are gone; **0.9.1 settings get 0.10's enemies once** (the host runs every enemy, the client is a second player in the host's game: the enemy settings back to their defaults, the ownership switch gone), grabs on the client stay experimental **0.10.0 settings upgraded**: grabs on the client on once, parries and bosses on. |

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
   `cutscene_skips`, `triggers`, `trigger_hooks`,
   `chapter_switch`, `no_pause` (and `no_pause_requests`); `enemy_uid` shows how many
   enemies have a level identity (all of them, normally); once connected `enemy_erase` and, on the
   host, `enemy_backups` (after the client joined); `hit_values` (the DamageInfo values a hit
   carries) once connected; `enemy_set_hp` turns `[ok] verified …` after the first synced hit
   (step 13); `hit_apply` after the partner's first hit on an enemy your game runs; later
   `item_flags` (with a key item nearby), `time_scale`, `enemy_mirror`, `enemy_motion` and
   `enemy_puppet` (step 12); once connected
   also `avatar`, `gear`, `sound_mirror`, `effect_mirror`, `shots`; on the host, with the client
   in its area, `partner_context`, `partner_seen`, `partner_hits`, then `partner_heard`,
   `partner_damage` and `partner_fatal` (step 13b), `partner_shots`, `partner_parry`,
   `partner_grab` and `partner_bosses` (steps 13d-13f); on the client `noise_hook`, and
   `partner_parry` and `partner_grab` once B was warned or grabbed. Click **Write research
   dump** in a few different areas. Each click adds a run, and nothing is overwritten.
3. **No pause**: A clicks *Host game* and opens the inventory: the world keeps moving (water,
   enemies, the in-game timer). The same for the map, files and the pause menu. A cutscene, the
   typewriter and the merchant still pause. *Stop hosting* → the inventory pauses again. If a menu still pauses, tick *Options →
   Pauses → Also refuse pause requests* and try again.
4. **Join the same chapter**: A plays chapter 1 somewhere in the village. B loads an earlier
   save of chapter 1 and clicks *Join game*. B's HUD shows "Travelling to …", the log says
   "World synchronised with the host", and B appears next to A. Doors A opened, items A picked
   up and the current objective/map match on B.
5. **Join from elsewhere**: B loads a different chapter and joins, then loads any save (or
   *Continue*): the game loads into A's chapter and B appears next to A. (With *Experimental →
   Load the partner's chapter automatically*, the game over screen appears by itself.)
5b. **Join from the title screen**: B stays on the title screen (or the main menu, any of its
   windows open) and joins while A plays. Without touching anything B's game goes to the main
   menu and loads: the HUD says "Loading your co-op save (slot 20)..." (or "your latest save"
   the first time), it loads into A's chapter, takes A's world and B appears next to A.
   *Diagnostics*: `join_load` reads `[ok]`, the *saves* line counts "join loads 1", "menu asked 1"
   and "co-op save used" once slot 20 exists.
6. **Partner model**: on each PC, the partner appears as Leon (not a stick figure) wearing the
   same costume. *Diagnostics* → *Partner model: ready (prefab) - ch0a0z0*, with all joints
   animated. Walk around the partner: no extra jacket or missing head/hair.
7. **Every state**: on A, walk, run, crouch, turn, aim each weapon type, shoot, reload, knife,
   parry, kick a stunned enemy, climb a ladder, jump through a window, heal, get grabbed, die.
   B sees each animation, with the weapon in Leon's hand (no gap), the slide moving.
8. **Shots and sound**: A fires. B hears the gunshot from A's position (louder when close),
   sees a muzzle flash, hears A's reloads and footsteps.
9. **Doors open for both**: B walks through a door while A watches: on A's screen it swings
   open and stays open while B is in the doorway, then closes in both games once B walked on
   (*Diagnostics*: `doors` reads `[ok]`, the *doors* line counts what was sent and applied).
   Then both stand in the same door: it stays open until both left. The same with an automatic
   or elevator door and a big double door (e.g. the church/castle doors) if the chapter has one.
   **Doors, keys, levers**: A unlocks a door with a key / pulls a lever / solves a puzzle. On B
   the door is usable (after re-entering the area if it was loaded) and the lever is down.
   *Diagnostics → gimmicks* counters go up on both sides.
10. **Breakables and animals**: A breaks a crate and shoots a crow; B's crate breaks and the
    crow dies (it falls, it does not vanish). B breaks a barrel; it breaks on A. A breaks a crate
    B has not reached yet: when B gets there, it is already broken. **Animals follow the host**:
    near crows, chickens or fish, both players watch the same animal: it moves, flies off and
    lands the same way on both screens (*Diagnostics → animals* counts the ones following and
    `animal_puppets` reads `[ok]`). B shoots a crow that is following A's: it dies on B's screen
    at once and on A's a moment later.
11. **Cutscenes, events and story flags for both** (0.9.1):
    * **Event**: A and B stand together; A walks into a spot that starts a scripted event (a
      camera shot, a voice line, something that moves). B's game shows the same event. On A,
      *Diagnostics → seen in our game* counts *event triggers*; on B, *event triggers* counts it
      as *run*. Walking into a door, a ladder, an item or a trap counts under *other triggers*
      and never runs on B.
    * **Cutscene nearby**: A walks into a cutscene while B stands close: it plays on both
      screens (*cutscenes*: *sent* on A, *played* on B), and afterwards the objective, doors and
      map are the same on both. B never gets it twice when B walks into the same spot later.
    * **Cutscene far away**: A walks into a cutscene while B is more than 30 m away (or in
      another area): it starts on B's screen at once, at the same time as on A's, and A is never
      frozen waiting. When it ends, B's HUD says "Joining your partner where the cutscene took
      place" and B appears next to A.
    * **Skip**: while both watch a cutscene, A holds the skip button: it is skipped on both
      screens (*cutscenes*: *skips_sent* on A, *skips_applied* on B), and afterwards both games
      continue the same way (objective, doors). Then B skips one: the same on A.
    * **Doors and levers from the client**: B unlocks a door or pulls a lever: on A,
      *partner gimmick states applied here* counts up and the door/lever works for A (if it was
      on A's screen, after A re-enters the area at the latest).
    * **Event far away**: B walks into an event while A is far away: A's game does not run it
      (*missed* on A); when A walks there later, A's game runs it itself.
    * **Flags**: A completes an objective or reveals part of the map: B's objective and map
      update (*flags*: *sent* on A, *applied* on B). A dies and reloads a checkpoint: B's world
      keeps what A had done (flags never cross *off*).
    * If a cutscene or an event misbehaves, untick it in *Options → Shared world* and tell us
      which one (*cutscenes* names the one waiting or playing; *seen in our game* names the
      last trigger that was not an event and why).
12. **Every enemy is the host's**: both stand in a room with Ganados (and dogs), B a bit away
    from A. *Diagnostics* → `enemy_uid` reads `[ok] N of N enemies have a level identity` and
    *enemy sync (host authority)* shows the pairs made by ID and how many A numbered for B. Every
    enemy stands in the same place on both screens, doing the same thing (same animation, same
    turn), and stays A's game's wherever B goes: B walks up to A's group and fights it - nothing
    jumps, nothing changes hands. *enemy states* on B counts the puppets, their moves and
    animations; `enemy_puppet` reads `[ok] head off, 1 animation driver(s) off`. B runs ahead
    into an area A has not loaded: those enemies stand still and unseen on B's screen (*held*)
    until A's game spawns them. If enemies jitter or freeze in a pose, untick *…with their own
    animation state machine switched off*, then *…and play their animation*, then *Client: the
    host's enemies stand and move where they are in the host's game*, and tell us which one fixed
    it.
13. **Hits, HP and kills**: B shoots an enemy: it flinches/staggers on both screens the way
    it does for A's shots (*enemy hits: run* counts it on A; `hit_apply` `[ok]`), its HP drops
    on both, and in A's game it turns on B's character. Shoot a leg, the head, the hat: the same
    reaction on both. B lands the killing shot: it dies on both screens, in the same place, the
    same way (*enemy deaths* on A counts it among the client's kills). *Diagnostics* shows `[ok]
    enemy_set_hp: verified …` after the first hit.
13b. **The host's enemies fight B** (0.10): B walks toward a group of Ganados A has not been
    seen by, A stays back. On A: *client as a target: ON*, `partner_context`, `partner_seen` and
    `partner_hits` read `[ok]`, and the status line says B is a target. The Ganados notice B
    (they shout, point and walk to B on both screens) and attack B: B's HUD says "N enemies are
    after you", their blows hit B's Leon in B's game (B's HP drops, B reacts, dodges with the
    prompt work), and on A *hits on the client's model* counts them (`partner_damage` `[ok]`);
    on B *hits from the host's enemies* counts them taken or dodged. B fires a shot out of their
    sight: they hear it and turn (`partner_heard` `[ok]` on A). A shoots a Ganado standing behind
    B's character: the bullet passes B and hits the Ganado (`partner_shots` `[ok]` on A, B takes
    nothing). B goes into a cutscene or another area: *client as a target: off*, and the
    Ganados go back to A. Send the counters if any of these stays at 0.
13c. **B's finishers**: B shoots a Ganado in the head: the kick prompt shows on B's screen, and
    B's kick plays the Ganado's reaction in both games. B sneaks behind an unaware Ganado: the
    stealth kill prompt shows and works; B knifes a downed one. *enemy finishers of the client*
    counts them sent (B) and run (A); `partner_fatal` reads `[ok]` on A. A prompt B never gets,
    or one that does nothing, is what we need to know about.
13d. **B parries** (0.10.1): a Ganado swings at B with an axe or sickle: B gets the parry
    prompt (`partner_parry` `[ok]` on both), parries, and the Ganado staggers in both games; B
    takes no damage from that swing. Try a just parry too. On A *parries of the client* counts
    them run; on B *hits parried* counts the blows not taken.
13e. **B is grabbed** (0.10.1): let a Ganado grab B from the front. B's Leon is held by it on
    both screens and B's screen says "HELD! Mash the action button..."; B mashes and breaks free
    (or uses the knife when the prompt says so): the Ganado lets go on both screens
    (`partner_grab` `[ok]` on both). Then let A shoot the Ganado holding B: it lets go of B. If
    B's Leon freezes in a pose while held, untick *...may grab your partner* on B (B then only
    takes the grab's damage) and report it.
13f. **Bosses go for B** (0.10.1): at a boss (Del Lago, El Gigante, the Garrador...), B does
    most of the damage: the boss turns to B (`partner_bosses` `[ok]` on A counts the times).
14. **Dead stays dead**: A clears a room alone; B walks in afterwards: none of those enemies
    appears for B (no corpses either; *enemy deaths* counts them as erased). Then B clears the
    next room alone; when A gets there, those enemies never appear for A. **Kills from before
    the session**: A loads a save where a room is already cleared, B a save where it is not; B
    joins: `enemy_backups` on A reads `[ok] … eliminated`, and those enemies never appear for B.
    **Reload**: B dies and reloads the checkpoint: the enemies A killed since then do not come
    back for B (B's log says it took over the host's world again).
15. **Key items**: A picks up a key item (e.g. the Wooden Cog). On B it disappears and B's HUD
    says "Partner picked up a key item".
15b. **Give an item**: A opens the attache case, picks a herb or ammo: the last command reads
    "Give to B". A chooses it: the item leaves A's case and appears in B's, and both are told.
    With B's case full, what does not fit comes back to A. A key item or a weapon has no such
    command. *Diagnostics*: `give_items` reads `[ok]`, the *items given* line counts them.
15c. **Saves for both**: A walks through an autosave point (the save icon shows): B's game saves
    too ("Saved with A (slot 20)"). B saves at a typewriter in slot 3: A's game autosaves, and B's
    slot 20 follows ("Your save is in your co-op slot too"). Both through the same autosave point:
    one save each. B's Load Game list shows slot 20 at A's chapter; A's slot 0 is untouched by B
    (two copies on one PC). B quits to the title and joins again: slot 20 loads, with B's
    inventory. B dies and picks *Continue*: B's game reloads slot 20, not A's autosave.
    *Diagnostics*: `save_sync` reads `[ok]`; the *saves* line counts them.
15d. **Traps**: A shoots an open bear trap: it snaps shut on B's screen too (sound). A steps in a
    bear trap: B sees it closed. A shoots a sensor bomb in the castle: it explodes in B's game too
    (B standing next to it takes damage). B joins after A closed some: they are closed in B's
    game. *Diagnostics*: `traps` reads `[ok]`; the *traps* line counts sent / received / applied.
15e. **Mechanisms**: A pulls the lever that opens a big door (chapter 1, the village): the
    door opens on B's screen too, with the camera shot if B is near. A pushes the cart / moves
    the shelf out of the way: it moves in B's game. In chapter 2 A turns the valve: the door to
    Leon's equipment opens for B. B far away: when B gets there it is open/moved. Nothing plays
    twice on either screen. *Diagnostics*: `mechanisms` reads `[ok]`; the *mechanisms* line
    counts sent / received / applied / same.
15f. **Enemy deaths and reactions**: A and B shoot the same villager in turns: it staggers on
    both screens and stays A's game's all along. A kills it with a shotgun: it falls at once on B's screen too, never walking on. B
    shoots a knee: it drops to its knee on A's screen; a head shot staggers it for the kick.
    *Diagnostics*: `hits` shows `kill_decided`, `parts_matched`, `attack_clones` growing and
    `deaths_forced` at 0 (a death without any attack data).
15g. **Enemies the client's save had dead**: A (host) plays on; B loads an older save in which
    B had killed the villagers of the next house, then joins A there: those villagers appear in
    B's game too (where A's are) and fight both. *Diagnostics*: `enemy_revive` reads `[ok]`; the
    *enemies* counters show `spawn_spawning` and `revived`.
15h. **Scoped weapons**: A buys or equips a rifle with a scope (SR M1903, Stingray, CQBR...):
    B's screen never shows the scope's view, A's model just holds the rifle; same the other way
    round and while A aims through the scope. *Diagnostics*: `puppet_cameras` reads `[ok]`.
15i. **One Ashley** (chapters with Ashley): A (host) and B walk around: Ashley follows A in
    both games, B's screen shows her where A's is, walking and animating the same. B taps
    **Alt**: both HUDs say "Ashley now follows B", she follows B in both games (from far away
    she appears behind B); tapping again within 5 s says how long to wait. A villager in A's
    game cannot grab her while she follows B. *Diagnostics*: `ashley`, `ashley_puppet` (and
    `ashley_warp` after a far switch) read `[ok]`; the *ashley* counters show `switches`.
    **All her animations**: with B running her, A's screen shows her idle, running, crouching
    and covering in a fight, hiding, climbing and being helped over gaps the same as B's - not
    only walking. *Diagnostics*: `ashley_motion` and `ashley_banks` read `[ok]`; on A's *ashley*
    line `motion_missing` stays 0 or low (if it grows, "last motion not found here" names it).
    **Never two Ashleys**: right after each switch, and when one game loads an area, neither
    screen shows a second Ashley (B's never walks to B on her own while A runs her). If another
    Ashley shows up in either game she is gone within a second or so: *Diagnostics*
    `ashley_extra` reads `[ok]` and the *ashley* counter `extras` goes up (log: "another Ashley
    ... appeared in our game").
15j. **What one completes, both complete**: A places a key item in a slot (e.g. an emblem in a
    door): on B's screen the item appears and the door unlocks; B can walk through. A solves a
    puzzle: it is solved for B (its sequence plays). Both see the same objective afterwards (B's
    updates with a banner). Kill El Gigante: on the other screen it dies too and the area moves
    on. *Diagnostics*: `mute_effects` and `purposes` read `[ok]`; *partner gimmick states*: "reacted
    live" > 0; the *objectives* counters show `applied`; the *enemies* counters `vanished_deaths`
    after the Gigante.
16. **Teleport any time**: B presses **F6** with A 10 m away, then in another room, then in
    another stage: each time B appears next to A (the HUD line shows "F6: teleport"). Pressing
    it twice in a row says "Teleport ready again in …"; during a cutscene it says why it waits.
    **Left behind**: A goes through a door into the next stage. After ~6 s B's HUD offers a
    teleport; **F6** moves B next to A. (Cross-stage warps through the game's own loader are
    *Experimental*.)
17. **Partner's hits and loot**: A shoots an enemy near B: a yellow line runs from A's character
    to it on B's screen and it reacts there too. A kills an enemy:
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
