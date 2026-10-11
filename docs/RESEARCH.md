# Research: making RE4 (2023) playable over LAN with REFramework

This document records what was investigated before building the mod, what was found, and
why the design looks the way it does. It covers three areas:

1. **REFramework**: what it can do, and its limitations and risks.
2. **Communication systems**: how two copies of the game can talk to each other.
3. **RE4 Remake's modules**: which in-game types (`chainsaw.*`) the mod reads and writes.

It ends with the sync architecture, known limitations and a roadmap.

> Status legend used below: **Confirmed** = read in REFramework's source or used by a published
> RE4R mod. **Probed** = plausible name that the mod looks up at runtime and disables the feature
> if missing. Nothing here has been verified inside the running game from this repository yet;
> see [TESTING.md](TESTING.md).

---

## 1. REFramework

[REFramework](https://github.com/praydog/REFramework) (praydog) is the standard modding
framework for RE Engine games. It loads as `dinput8.dll` next to `re4.exe` and provides:

| Feature | Use in this mod |
|---|---|
| **Lua scripting** (`reframework/autorun/*.lua`), Lua 5.4.3 via sol2 | All game logic, UI and rendering of the partner |
| **Type database (TDB) reflection**: `sdk.find_type_definition`, `get_method`, `:call()`, `get_field`/`set_field` | Reading the player, enemies and HP without hard-coded offsets |
| **Managed singletons**: `sdk.get_managed_singleton("chainsaw.CharacterManager")` | Entry points into game state |
| **Method hooks**: `sdk.hook(method, pre, post)` | Capturing the local player's sounds, effects and shots so the partner's copy can replay them (§4.1). Enemy damage is still detected by polling (§4) |
| **Application-entry callbacks**: `re.on_application_entry("LateUpdateBehavior", fn)`, `"PrepareRendering"` | Game-thread tick for networking and sync; end-of-frame pose capture and pose check (§4.1) |
| **Drawing**: `re.on_frame` + `draw.world_to_screen/line/text/...` | Partner name tag, HP bar, HUD |
| **ImGui**: `re.on_draw_ui` + `imgui.*` | Host/Join panel inside the REFramework menu |
| **JSON**: `json.load_file/dump_file` (sandboxed to `reframework/data`) | Settings, diagnostic type dumps |
| **C/C++ plugin API**: DLLs in `reframework/plugins` with `reframework_plugin_initialize` | The network transport (`re4coop_net.dll`) |

### 1.1 Limitations and risks (the "liabilities")

These shaped the design:

* **The Lua sandbox has no networking.** REFramework opens `base, package, string, math, table,
  bit32, utf8, os, coroutine, debug` and leaves out `io`. It also strips parts of `os`
  (`src/mods/ScriptRunner.cpp`, `ScriptState::ScriptState`). There is no LuaSocket and no way to
  `require` a C module from a script.
  → Networking **must** live in a native plugin that registers Lua functions.
* **Plugins see the Lua state before scripts do.** `ScriptRunner::reset_scripts` creates the main
  state, calls every plugin's `on_lua_state_created`, *then* runs `reframework/autorun/*.lua`. So
  a plugin can install a global table (`re4coop_net`) that scripts can rely on at load time.
* **The plugin must build against the same Lua.** A plugin that calls the Lua C API on
  REFramework's `lua_State` links its own copy of Lua (REFramework's own `example_plugin` does
  this). The struct layouts must match: REFramework vendors **Lua 5.4.3 + two upstream bugfix
  patches** (`ldebug.c`, `lvm.c`). We vendor that exact copy (`third_party/lua-5.4.3`). Lua 5.4
  no longer compares static sentinel addresses (`dummynode`, `absentkey` are checked by tag), so
  two copies of the code can safely operate on one state.
* **Plugin API versioning.** `reframework_plugin_required_version` is checked as
  "same major, required minor ≤ framework minor". The fields we use (`on_lua_state_created`,
  `on_lua_state_destroyed`, `log_info`) have kept the same layout since plugin API **1.3**
  (2022, before RE4R shipped). We therefore request 1.3, so any RE4-capable REFramework build
  loads the plugin. `game_name = "RE4"` stops it loading in other games. The comparison is
  case-sensitive and uses REFramework's *build target* name, which is uppercase `"RE4"` in both
  the old per-game builds and the v2 universal build. Lua's `reframework:get_game_name()`
  returns lowercase `"re4"` instead. v0.1.0 mixed the two up and was rejected as "for a
  different game". `test_plugin_load` now pins the value.
* **"Reset Scripts" destroys the Lua state.** Anything that must survive (the UDP session) lives
  in the plugin. The reloaded script resumes it. We tested this path (`tests/lua/test_integration.lua`).
* **Threads.** `re.on_frame` runs during present (render side). `re.on_application_entry`
  callbacks run inside the game's update loop. Game objects are only touched from
  `LateUpdateBehavior`; `on_frame` only draws. The plugin's network thread never touches Lua: it
  exchanges data with the Lua side through a mutex-protected queue.
* **Draw API scope.** `draw.*` is only valid inside `re.on_frame`.
* **Names change with game patches.** Capcom updates RE4 occasionally. TDB names are stable
  more often than offsets, but methods do get renamed or removed. Every game call in `game.lua`
  is therefore probed and wrapped in `pcall`. A missing capability shows up in
  *Diagnostics* instead of throwing every frame.
* **Object lifetimes.** Managed objects held from Lua are ref-counted, but a context can be
  released by the game (enemy despawn) while Lua still holds it. Enemy contexts are refreshed
  from `get_EnemyContextList` every tick and never reused across ticks.
* **Game updates can break REFramework itself.** After a game patch, users need a matching
  REFramework nightly build. The mod cannot fix that.
* **Single-player engine.** RE4R has one player controller, one camera and one
  `getPlayerContextRef()`. Making a second, network-driven *player* inside one game instance
  would mean reverse-engineering input, camera and character-spawn systems that are not exposed
  through the TDB in any documented way. This is the main reason for the two-instance design
  in §4, and why the partner is shown as a *visual copy* (their body prefab with game logic
  switched off, posed from the network) rather than a second player character.

## 2. Communication systems

| Option | Verdict |
|---|---|
| **RE Engine's own networking (`via.network.*`, Capcom ID services)** | RE4R has no multiplayer session system. Its online features are leaderboards and Capcom ID. Hijacking authenticated Capcom services is unsafe and against their terms. **Rejected.** |
| **Steam networking (`ISteamNetworkingSockets` via `steam_api64.dll`)** | Gives NAT traversal and relays, but needs Steam friend/lobby plumbing and does not work for the Microsoft Store/other builds. Not "LAN by IP". **Rejected for v1.** It could become an optional transport later. |
| **LuaSocket / any Lua-level socket** | Impossible inside REFramework's sandbox (§1.1). **Rejected.** |
| **TCP from a plugin** | Simple, but one lost segment stalls every later update (head-of-line blocking), so player/enemy positions arrive in bursts. **Rejected.** |
| **UDP from a plugin with a small reliability layer** | Lowest latency. State updates can be dropped and simply superseded, while events (damage, deaths, chat) get acked and retransmitted. Works on LAN, and over the internet with one forwarded UDP port or a VPN such as Tailscale/ZeroTier/Radmin. **Chosen.** |

### 2.1 Transport design (`plugin/src/net`)

* One host, one client (RE4 co-op is two players). The host listens on a UDP port (default
  **33040**). The client connects by IP or `IP:port`.
* Handshake: `ConnectRequest(nonce, name, password)` → `ConnectAccept(token)` or
  `ConnectReject(reason)`. All later packets carry the 32-bit session token, so stray or old
  packets are dropped.
* Channels:
  * **reliable-ordered**: 16-bit sequence numbers, selective acks, retransmit at
    `clamp(2×RTT, 50 ms, 1 s)`, a reorder buffer, and exactly-once in-order delivery;
  * **unreliable**: fire-and-forget, used for snapshots that are resent at 10–20 Hz anyway.
* Heartbeat pings every 0.5 s give the RTT. A 10 s silence counts as a disconnect. A host whose
  partner drops goes back to listening, so the partner can rejoin. If the same IP reconnects
  with a new nonce (the game restarted), it replaces the stale link immediately.
* A background thread owns the socket, so acks, pings and retransmits continue during loading
  screens when Lua is not ticking.
* Windows specifics: `SIO_UDP_CONNRESET` is disabled. Otherwise an ICMP "port unreachable"
  from a departed partner makes every later `recvfrom` fail, which kills the host.
* The full wire format is in [PROTOCOL.md](PROTOCOL.md).

## 3. RE4 Remake modules (`chainsaw.*`)

RE4R's game code lives in the `chainsaw` namespace (`sdk.game_namespace("X")` → `"chainsaw.X"`).

| Type / member | Status | Source | Used for |
|---|---|---|---|
| `chainsaw.CharacterManager` (managed singleton) | Confirmed | REFramework `scripts/utility/RE4.lua`; SRT overlay; Health Bars | Root of player/enemy access |
| `CharacterManager.getPlayerContextRef()` | Confirmed | REFramework `RE4.lua`, SRT overlay, Health Bars, REFramework discussion #1112 | Local player context |
| `CharacterManager.get_EnemyContextList()` → `List<…>` (`get_Count`, `get_Item(i)`) | Confirmed | SRT overlay (resyst/re4r, Joydurn/re4r-SRT) | Enumerating enemies |
| `chainsaw.PlayerBaseContext` (`get_Position`, `get_IsHolding`, `get_AimTargetEnemy`, `get_CameraController`) | Confirmed | Health Bars `player_handler.lua` | Player position, aim flag |
| `chainsaw.EnemyBaseContext` (`get_Position`, `get_HitPoint`, `get_BodyGameObject`, `get_IsLively`, `release`) | Confirmed | Health Bars `enemy_handler.lua` | Enemy state |
| Concrete context types, e.g. `chainsaw.Ch1c0z0Context`, `Ch1d6z0Context`, `Ch1f6z0Context` | Confirmed | Health Bars, RE4 Mod Menu notes | Enemy *kind* = runtime type name |
| `Context.get_BodyGameObject()` / `get_HeadGameObject()` | Confirmed | REFramework `RE4.lua`; AWF reads `chainsaw.PlayerEquipment` from the head object | Body = skeleton + visible parts (`ch0a0z0_body` for Leon); head = game logic |
| `chainsaw.HitPoint` (`get_CurrentHitPoint`, `get_DefaultHitPoint`, `get_IsLive`, `get_HitPointRatio`, `get_CurrentDamagePoint`) | Confirmed | SRT overlay, Health Bars | HP read |
| `HitPoint.dead()`, `HitPoint.set_Invincible(bool)` | Reported by mods (method names published on Nexus, mods 6165 and 7363) | Search summaries of *True Invincible* and *RE4 Mod Menu* | Killing an enemy (probed; falls back to HP 0) |
| `HitPoint` HP setter (`set_CurrentHitPoint`, `setHitPoint`, …) or backing field | **Verified at runtime** | No public source names it. v0.1's fixed-name probe did not find a working one in game (partial damage didn't sync) | Applying synced HP. Since v0.2 candidates come from `HitPoint`'s own methods/fields and one is trusted only after reading HP back proves it wrote the value (§3.2) |
| `chainsaw.EnemyManager.notifyHitDamage(damageInfo, enemyCtx)` / `notifyDead(...)` | Confirmed | Health Bars hooks (`args[3]`, `args[4]`) | Not used in v0.1; candidate for event-driven damage sync |
| `chainsaw.GuiManager.get_IsPlayingEvent()`, `get_IsHudOff()`, `get_GuiOpenCloseData()` | Confirmed | Health Bars `gui_handler.lua` | Cutscene flag |
| `chainsaw.GameStatsManager.getKillCount()`, `InventoryManager.get_CurrPTAS()`, `InGameShopManager.get_CurrSpinelCount()`, `GameRankSystem.get_GameRank()` | Confirmed | SRT overlay | Not used yet (possible shared-stats features) |
| Chapter/area getter (`chainsaw.CampaignManager.get_CurrentChapter`, …) | **Probed** | The autosplitter reads chapter IDs by raw offset only | "You are in different chapters" warning |
| `via.GameObject.get_Transform`, `getComponent(System.Type)`, `destroy` | Confirmed (engine) | REFramework, every RE Engine mod | Transforms, components, puppet cleanup |
| `via.Transform.get_Position/set_Position/get_Rotation/set_Rotation/get_Joints/getJointByName` | Confirmed (engine) | REFramework bindings, Health Bars | Positions, skeletons |
| `via.Joint.get_Name/get_Position/get_Parent` | Confirmed (engine) | Health Bars, REFramework | Joint names, muzzle position |
| `via.physics.CharacterController.warp()` | Engine convention (RE2/RE3/RE8 teleport mods) | Probed at call time | Teleport without physics snapping back |
| `via.Prefab` (`set_Path`, `get_Exist`, `set_Standby`, `get_Ready`, `instantiate(via.vec3)`) | Confirmed | REFramework discussion #1112 (RE4 enemy spawn; paths are relative); EMV Engine (`get_Exist`) | Spawning the partner's body, weapons, muzzle flash |
| Character prefabs `<content>/appsystem/character/<id>/<id>_body.pfb` and `<id>_head.pfb` | Confirmed | RE4 Steam file list (Ekey/REE.PAK.Tool `RE4_STM_Release.list`), §3.4 | The partner's body |
| Weapon objects `wp4000`…`wp6400` with `chainsaw.Gun` / `chainsaw.Melee`; prefabs `_chainsaw/appsystem/prefab/weapon/wpNNNN.pfb`, `_mercenaries/.../wpNNNN_ao.pfb` (Separate Ways), `wpNNNN_mc.pfb` (Mercenaries) | Confirmed | AWF (`scene:findGameObject("wp4000")`, `chainsaw.Gun`), file list | The partner's weapons |
| `chainsaw.Gun` shoot method (`shoot`, `fire`, …) or an ammo getter | **Probed** | No public source names it | Detecting shots (muzzle-flash fallback) |
| `via.GameObject.create(System.String)`, `createComponent(System.Type)`, `get_Components`, `set_DrawSelf`, `get_Draw`, `set_Name`, `destroy` | Confirmed (engine) | EMV Engine `create_gameobj`, REFramework `utility/GameObject.lua` | Rebuilding parts from meshes, hiding/naming the copy |
| `via.render.Mesh.getMesh` / `setMesh`, `get_Material` / `set_Material`; `sdk.create_resource(...):create_holder(...)` | Confirmed | EMV Engine, REFramework `Sdk.cpp` | Reading the player's meshes; rebuilding parts |
| `via.Transform` hierarchy: `get_Child`, `get_Next`, `get_Parent`, `set_Parent`, `get/set_ParentJoint`, `get/set_SameJointsConstraint`, local position/rotation | Confirmed (engine) | EMV Engine | Parts follow the body's joints; weapons hang from the hand joint |
| `via.Joint.get/set_LocalRotation`, `get/set_LocalPosition`, `get_Name` | Confirmed (engine) | EMV Engine poser (writes joints in `PrepareRendering`), REFramework scripts | Reading the local pose; posing the copy |
| `via.SceneManager.get_CurrentScene()` + `findGameObject(System.String)` | Confirmed (engine) | EMV Engine, AWF | Weapons not parented to the player |
| `via.wwise.WwiseContainer.trigger(...)` overloads; containers `snd_cont_cha0`, `snd_trgr_cha0`, `snd_bank_wp_4000`… | Confirmed (engine), banks from the file list | EMV Engine (`trigger(via.GameObject, System.UInt32, …)`) | Replaying the partner's sounds on the copy |
| `via.effect.script.EPVStandard.requestEffect(...)`; `_chainsaw/vfx/provider/epv_system/epv_muzzleflash/epve_0015_muzzleflash_0000.pfb` | Confirmed (engine), path from the file list | EMV Engine | Replaying effects; fallback muzzle flash |
| Animation banks `_chainsaw/Animation/ch/cha0/motbank/cha0.motbank` (Leon), `cha0_wp4000.motbank`…, `cha1` (Ashley), `cha8` (Ada) | Confirmed | EMV Engine RE4 resource list | Not needed: poses travel instead of animation ids (§4.1) |

### 3.1 Prior art

* **claybtv's "Multiplayer Mod"** ([Nexus 6539](https://www.nexusmods.com/residentevil42023/mods/6539),
  open beta June 2026) runs two game instances with a host and a joining partner. It syncs
  enemies, story events, doors and switches. Reported issues are lag and choppy enemies, and
  the pause/inventory menu breaking the session. The author announced a **LAN version is in
  progress**. That validates the two-instance approach this project uses. This project is an
  independent, open implementation focused on direct IP/LAN play.

### 3.2 Second research round (v0.2)

In-game testing of v0.1 showed kills syncing but partial damage, enemy positions, attacks, drops
and key items not syncing. This round used two new primary sources:

* **The RE4 RSZ schema** ([alphazolam/RE_RSZ `rszre4.json`](https://github.com/alphazolam/RE_RSZ),
  built from praydog's REFramework dumps). It names all ~163,000 RE4 types and the serialized
  fields of each, but no methods. Facts taken from it:
  * `chainsaw.CharacterContext` / `EnemyBaseContext` have `_ID : chainsaw.ContextID`, and
    `ContextID = { _Category, _Kind : Byte, _Group : Int32, _Index : Int32 }`. It is assigned by
    level data, so placed enemies should carry the same ID on both machines. Enemy pairing now
    uses it first. It's guarded by kind and a 25 m spawn distance and falls back to spatial
    pairing, so a wrong assumption cannot make pairing worse than v0.1.
  * World pickups and drops are `chainsaw.DropItem` components with `_ID : ContextID` and
    `_ItemData : chainsaw.DropItemContext.SaveData { ItemID, Count, AmmoItemID, AmmoCount,
    Durability, … }`.
  * Systems that exist (types confirmed, methods unknown): `chainsaw.HateController` /
    `HateTargetInfo` (enemy target selection), `chainsaw.DropItemManager`, `chainsaw.RandomDrop`,
    `chainsaw.InteractGetPickupItem`, `chainsaw.ScenarioFlagManager`,
    `chainsaw.ChapterSceneManager`, `chainsaw.LocationSceneManager`, `chainsaw.LocID`,
    `chainsaw.ChapterID`, `chainsaw.CharacterSpawnController`.
* **The resyst/re4r autosplitter**: all 16 key items it tracks (Wooden Cog `119235200`, Church
  Insignia `119257600`, Boat Fuel `119273600`, …) fall in one ItemID block,
  `119,203,200–119,273,600`. The mod treats `119,000,000–119,999,999` as key items.
* **Engine calls verified in EMV Engine** (a widely used RE Engine script):
  `via.SceneManager.get_CurrentScene` → `scene:call("findComponents(System.Type)", t)`,
  `sdk.call_object_func(go, "get_Components")`, `obj:call("destroy", obj)`,
  `via.motion.TreeLayer.get_MotionBankID/get_MotionID/get_Frame` and
  `changeMotion(System.UInt32, System.UInt32, System.Single, System.Single,
  via.motion.InterpolationMode, via.motion.InterpolationCurve)`. REFramework exposes
  `reframework:is_key_down(vk)` for hotkeys.

What v0.2 builds on that:

| Feature | How | Verified by |
|---|---|---|
| HP sync during fights | Self-verifying HP writer. A candidate is used only after reading HP back proves the write. A no-op write never counts. Names containing default/max/rate/damage/… are excluded, so max HP is never touched | Tests with a working setter under another name, a broken setter, a field-only build and a max-HP decoy |
| Exact enemy pairing | `chainsaw.ContextID` first, with spatial fallback (replaced in v0.3: enemy `_ID`s turned out to be runtime counters, see §3.3) | Tests with spawns 8–12 m apart, ID+kind mismatch, ID too far away |
| Key items exist once | Scan `chainsaw.DropItem` 4×/s. An item that vanishes while you stood within 4 m of it, moments before, was picked up. Your partner's copy is destroyed (and destroyed again if the area reloads it). Area unloads far away are ignored, which prevents softlocks | `test_items_sync.lua`, integration test |
| No softlock | Partner ≥ 35 m away for 6 s outside cutscenes → HUD prompt. **F6** teleports, **F7** hides it for 2 min. If you fall through not-yet-loaded ground, it re-teleports up to 3 times | `test_progression.lua`, integration test |

Still needing **method signatures from the user's build**, collected by the in-game research dump
(*Diagnostics → Write research dump*, written to `reframework/data/re4coop_typedump.json`):

* **Enemies targeting both players, and seeing the partner's fights:** host enemies must be able
  to pick the partner as a target (`chainsaw.HateController`/`HateTargetInfo`). Only then can
  the client's enemies be turned into puppets of the host's (AI off, transform + motion layer
  copied). Doing the puppet part first would leave the client with enemies that never attack
  it. The dump lists the components on a live enemy, which shows what drives the AI.
* **Identical drops:** need `chainsaw.DropItemManager` / `chainsaw.RandomDrop` methods, either
  to make the client's random roll return the host's result or to spawn the host's drop
  directly. Editing an existing drop's `_ItemData` is not used, because the visible model would
  no longer match what you pick up.
* **Chapter/area awareness:** `ChapterSceneManager`/`LocationSceneManager` getters, to replace
  the distance heuristic in the left-behind prompt.

### 3.3 Third research round: the in-game dump (v0.3)

The first `re4coop_typedump.json` from the game gave method signatures for every listed type.
What it showed, and what v0.3 does with it:

**Identity.** `chainsaw.ContextID` is a class `{_Category, _Kind, _Group, _Index, _Code}`.
Enemies' own `_ID`s were `0:0:12:312`, `0:0:12:987`, `0:0:12:1053`, and spawned drop items
`2:0:12:192…486`. These are **runtime counters** handed out in load order, not level data,
so the v0.2 assumption was wrong for enemies. Level-placed items do carry level IDs, with the
stage as group (`3:0:40200:0…2`, `3:0:40210:12…13`). v0.3:

* identifies enemies by `CharacterContext.get_SpawnerID()`, the level spawner's ContextID.
  Spawner IDs are ignored if they are runtime IDs. A spawner can create several enemies, so
  the client pairs by spawner ID only when the ID is unique among same-kind enemies on both
  sides, within 25 m, and only after three position-based pairings agreed with spawner IDs and
  none disagreed. Same save + same load order can make runtime counters agree for a while
  and then drift, which is why the trust gate exists;
* never sends a runtime ID for key items: they match by item ID + position, or by a level ID;
* reads `DropItem.getItemID()` when `_ItemData.ItemID` is 0, which it was for every
  level-placed item in the dump.

**Pickups.** `static DropItem.onAcceptPickup(user_id: ContextID, item_id: ContextID)` and
`onAcceptOccupied(user_id, item_id, arg)` are the game's pickup callbacks. v0.3 hooks both.
For a static method REFramework passes the parameters from `args[2]` on (`args[1]` is the VM
context; checked in REFramework's `HookManager.cpp`). A key item counts as taken when a
callback named its ContextID **and** it left the scene within 3 s of it. The v0.2 proximity
heuristic only runs until a callback has been seen to match a vanished pickup. After that the
callbacks are the only signal, so an area unload can no longer be mistaken for a pickup.

**Stages and warping.** `CharacterContext.get_CurrentStageID() → chainsaw.StageID`. v0.3 sends
it in PLAYER. The teleport prompt also appears when the partner has been in another stage for
the prompt delay and is at least half the far-away distance away (17.5 m by default). Stage
borders can run through one area (the dump had items from stages 40200 and 40210 loaded at
the same time), so a smaller distance would prompt players who are only a house apart.
`CharacterManager.requestWarp(contextID, pos: Nullable<vec3>, rot: Nullable<Quaternion>,
stage: StageIdentifier)` together with `CampaignManager.get_CurrentStageIdentifier()` is the
game's own stage-aware warp. It could replace the transform teleport for cross-stage
teleports once `StageIdentifier`'s layout is known (it is in the new research log).

**HP.** `HitPoint` has `set_CurrentHitPoint(Int32)` and `<CurrentHitPoint>k__BackingField`,
plus `addDamage(Int32)`, `recovery(Int32)`, `dead()` and `Invincible`/`NoDamage`/`NoDeath`/
`Immortal` flags. The dump was taken before any partial hit was synced, so `enemy_set_hp`
read "untested". The writer verifies itself on the first synced hit.

**Targeting.** `chainsaw.HateController` (a `via.Behavior`) has `find(target: GameObject,
source)`, `addHate(target: GameObject, add_hate: Single)`, `attention(…)`, `lose(target)` and
`get_CurrentTarget() → HateTargetInfo`. It is **not** among the 58 components on an enemy's
body GameObject, so the research log now searches the scene for it. `CharacterManager` has
`getPartnerContextRef()`, `PlayerAndPartnerContextList` and `requestSpawn(spawnerContextID,
contextID, CharacterKindID, CharacterUsePurposeFlag, costumePresetID)`. Next step: on the host,
spawn a partner-purpose character that follows the remote player and is registered like
Ashley/Luis, then feed it to `HateController.find/addHate`. This needs the
`CharacterKindID`/`CharacterUsePurposeFlag` values, which the new dump reads from the enums'
static fields. Client enemies become puppets of the host's only after that works. Otherwise
they would never attack the client.

**Drops.** `DropItemManager.generateRandomDrop(droptype, cc, pos, stage, order, option)`,
`requestGenerateLostItem(itemdata: chainsaw.Item, pos, stage: StageID, option:
GenerateItemOption)` and `RandomDrop.calcRandom(droptype, cc, inventory, order) →
ItemResult`. Plan: the host reports its roll, and the client spawns that item with
`requestGenerateLostItem`. The client suppresses its own roll only after it has verified such
a spawn once.

**The dump tool itself.** v0.2 overwrote `re4coop_typedump.json` on every click, so of many
runs in different areas only the last one's live data survived (type signatures are the same
everywhere). v0.3 keeps everything:

* `re4coop_typedump.json` merges types described by earlier runs, adds enum values and lists
  every area dumped so far;
* every click appends a snapshot to `re4coop_research_log.json` (last 60 runs): stage
  identifier, difficulty, the partner character (type, kind, spawner, components), up to 30
  enemies (kind, spawner, stage, find state), where HateControllers live and what they
  target, motion layer 0 of the player and the first enemy, pickups (both item IDs, stage,
  lost flag), pickup-callback activity, and the session's sync counters.

### 3.4 The player prefab

The RE4 Steam file list (167,617 paths, from [Ekey/REE.PAK.Tool](https://github.com/Ekey/REE.PAK.Tool))
shows how characters are built:

* Every character has `<content>/appsystem/character/<id>/<id>_body.pfb` and `<id>_head.pfb`.
  The body object is what you see (the FRAMED EMV guide hides Leon by toggling `ch0a0z0_body`);
  the "head" object carries game logic (AWF finds `chainsaw.PlayerEquipment` on it).
* Leon is `ch0a0z0` (`_chainsaw/appsystem/character/ch0a0z0/ch0a0z0_body.pfb`). Ashley as a
  playable character (chapters 9–10) is `ch0a1z0`. Ada (Separate Ways and Mercenaries) is
  `ch3a8z0`, whose body prefab lives in the Mercenaries content:
  `_mercenaries/appsystem/character/ch3a8z0/ch3a8z0_body.pfb`. Mercenaries characters are
  `ch6i0z0`…`ch6i5z0`, `ch7k0z0`, `ch3a8z0_mc`.
* Costumes are separate part prefabs (`.../ch0a0z0/costume/cha000_00.pfb`, `cha000_10`, `cha000_20`,
  `cha001_00`…) over meshes such as `_chainsaw/character/ch/cha0/cha000/00/cha000_00.mesh` (body),
  `.../10/` (face), `.../20/` (hair), with material variants (`cha000_00b.mdf2`… for dirt and blood).
* Weapons: objects named by id (`wp4000` SG-09 R, `wp4100` W-870, `wp4400` SR M1903,
  `wp5000` combat knife, `wp5400` hand grenade…), prefabs under `appsystem/prefab/weapon/`, meshes
  under `_chainsaw/character/wp/wp40/wp4000/00/`, sound banks `snd_bank_wp_4000`, effects under
  `vfx/provider/epv_weapon/epv_wp4000/`.

So the mod does not need the user to type a path: the sender reports its body object's name, the
receiver derives the character id and checks the candidate paths with `via.Prefab.get_Exist`.
Costume differences are handled by mesh path (§4.1). Animation banks are not needed at all.

### 3.5 Fourth research round: 31 runs in chapter 1 (v0.5)

The second dump (accumulated over 31 runs in `cp10_chp1_1` = ChapterID 21100, stages 40200 and
43300–43410) added enum values and the types the next features need. The research log was not
included, so the key-item callback activity and the live HateController search are still open.

**Enums.** `CharacterUsePurposeFlag` = {None 0, Spawner 1, Dynamic 2}.
`ContextID.EntityCategory` = {Character 0, Gimmick 1, Item 2, LostItem 3, Custom 4, GmDynamicID 5}.
So the category-3 items with the stage as group are *LostItems* (spawned drops), and `2:0:12:…`
are ordinary items. `CharacterKindID` has 72 values (e.g. `ch0_a0z0` 100000, `ch3_a8z0` 380000,
Ganado `ch1_c0z0` 200000). `ChapterID` has 85 and `StageID` 833. `RandomDrop.DropType` =
{Woodbox 1, WoodboxB 2, WoodboxC 4, enemy types 512…33554432, Crow, Egg}. Also
`HateTargetInfo.FindSourceType`/`FindStateType` and `PauseLayer` = {Self 1, Inventory 2, Map 4, …}.

**Enemies.** `enemy_spawner_id` read "0 of 9": these Ganados' spawner IDs are runtime IDs or
missing, so pairing stays positional. Every character has a separate AI **head**
(`CharacterContext.get_HeadGameObject()`, `get_HeadUpdater()`) and a **body**
(`get_BodyUpdater()`). The context carries what the head tells the body: `Actions`,
`MoveDirection`, `MoveIntensity`, `WatchDirection`. It also has `OperationStopState`
(a `PauseLayer`) and, for Ganados, `ThinkOffEvent`. `HateController` is a `via.Behavior` but not
on the body GameObject, so it most likely lives on the head. This is the route to enemy puppets:
switch the head off on the machine that doesn't own the enemy, and feed the owner's commands to
the body.

**Hits.** `HitController.callbackDamageHit(info: DamageInfo)` runs on the victim's HitController
for every hit. `DamageInfo` = {Damage, Wince, Break, Stopping, DamageDir, AttackOwnerObject,
WeaponGameObject, WeaponID, IsCritical, IsKill, IsPartnerDamage} with `copy(src)`.

**Drops and items.** `DropItemManager.generateRandomDrop(droptype, cc, pos, stage, order,
option)`, `requestGenerateLostItem(item, pos, stage, option)`. `chainsaw.Item` has
`setItemId`/`setItemCount`, and `GenerateItemOption` is a plain class (Falldown, Effect,
NeedColCheck, …). `InventoryManager.getItemGetFlag(ItemID)` turns true when the save obtains an
item.

**Gimmicks and story.** `GimmickManager.findGimmick/findContext(ContextID)`,
`pushDirtyList(context)` (a gimmick changed state), `CampaignManager.setChapter`,
`CampaignJumper`, `GameSituationManager.requestInhibit(InhibitType, RequestLayer)`. REFramework's
own timescale feature uses `via.Scene.set_TimeScale`, and 0 is allowed.

What v0.5 builds on that:

| Feature | How | Safety |
|---|---|---|
| See the partner's hits | Hook `callbackDamageHit`. A hit whose attack owner is your player is sent as ENEMY_HIT. The partner replays it on its copy: a new `DamageInfo` copied from their *own* last hit (so weapon/owner objects are valid in their game), with your wince/break/stopping/direction and 1 damage. HP is put back at once, and again if the game applies it a frame late. A yellow tracer runs from your ghost to the enemy | No replay before the receiving player has landed a hit. Never on nearly dead enemies. HP still syncs through the proven damage/HP path. Option: *Enemies react to your partner's hits* |
| Identical enemy drops | Host: `generateRandomDrop` for an enemy + a new pickup near it → ITEM_DROPPED. Client: skips its own roll (`SKIP_ORIGINAL`) for paired enemies and spawns the host's item with `requestGenerateLostItem` where its copy is | Skipping starts only after the client's own hook fired for an enemy. If the first spawned item never shows up, sync switches off and both roll their own again. Boxes and unpaired enemies are untouched |
| Key items exist once | The game's "obtained" flag turning true while the item leaves the scene is now the main signal. If the item was the only copy on both sides in the same stage, it matches even at another position. A removal that had no effect is reported | Proximity guessing only until an exact signal has worked. Event log in *Diagnostics* |
| Transition gate (RE5/6 style) | A cutscene longer than 1.5 s, or a chapter/part change, holds the player who got there first (scene time scale 0) until the partner arrives. The partner is offered F6 right away. **F8** continues alone | Released on disconnect, on "Reset Scripts", when switched off, and automatically if holding ever stops the mod's game loop |
| Damage race fix | The host applied client damage to the HP from its last enemy scan, overwriting HP the enemy lost since (its own shots). It now reads the current HP | Regression test |

### 3.6 Fifth round: the shared world (v0.6)

v0.6 adds what the roadmap called *shared progression* and *enemies for both players*, plus
two things players asked for directly: no pausing in co-op, and joining straight into the
host's game. Sources for this round: the in-game Lua client of the RE4R Archipelago randomizer
([LiterallyMetaphorical/RE4R-AP-Wizard](https://github.com/LiterallyMetaphorical/RE4R-AP-Wizard),
whose code records what was verified live), the RE4 RSZ schema (§3.2), REFramework's binding
source (`src/mods/bindings/Sdk.cpp`, `shared/sdk/SystemArray.cpp`), EMV Engine and this mod's
own dumps (§3.3, §3.5). Status: **Live** = used in game by a published mod; **Dump** = the
type/fields exist in the game's type database, method names are found at runtime by signature
(*Diagnostics* lists each one).

| Area | Type / member | Status | Used for |
|---|---|---|---|
| Scenario flags | `chainsaw.ScenarioFlagManager.requestSetFlag(System.Guid, System.Boolean)`, `checkFlag(System.Guid)`; GUIDs from `System.Guid.Parse(System.String)` | Live (AP Wizard re-fires pickup flags with it) | Applying the partner's flag changes through the game's own setter |
| Scenario flags | Setters `(Guid[, Boolean])` on `ScenarioFlagManager` with an allow-listed name (`requestSetFlag`, `setFlag`, `...FlagOn/Off`, `resetFlag`...) | Dump + signature probe | Hooked to report local changes. Watchers, counters and locks are never hooked |
| Scenario flags | `ScenarioFlagManager.SaveData {Datas: SaveGroup[] {GroupName, Flags: UInt32[]}}`, save/load methods returning/taking it | Dump + signature probe | Full flag copy for a joining client; 32-bit word diffs when no setter can be hooked |
| Gimmicks | `chainsaw.GimmickManager.SaveData {Datas: List<SaveItem {ID: ContextID, SaveData}>}`, `GimmickContext.SaveData {Attr: Byte[], TriggerSave: TriggerDone[] {SaveID, Done}, IsDetected, AccDatas: AccessoryData{Float,Uint}[]}` | Dump + signature probe | Locks, keys used, levers, shutters, puzzles: diffed and replicated by ContextID (the save table is what goes into save files, so its IDs are level IDs) |
| Gimmicks | `GimmickManager.pushDirtyList(context)` | This mod's dump (§3.5) | A gimmick announced a state change: its record is read and sent at once instead of at the next 2 s scan |
| Breakables, animals | `chainsaw.GmWoodBox`, `GmOilDrum`, `GmBottle`, `GmSimpleBreak`, `GmShootObj`, `GmBlueCoin`, `GmWindowBreakable`, `GmCrow`, `GmChicken`, `GmFish`, `GmBat`… with a `_Routine` state enum | Dump | Watched by GameObject GUID; a terminal routine name (`Break`, `Dead`, …) is "destroyed". Applied by setting the same routine (the object plays its own break/death), else a break/kill method, else hiding it |
| Scene | `via.SceneManager.get_CurrentScene` → `findComponents(System.Type)`; GameObject `ToString()` → `name@<guid>` | Live (AP Wizard) | Finding objects; a cross-PC object identity from the scene file |
| Cutscenes | `chainsaw.TimelineEventManager` methods taking `chainsaw.TimelineEventDefine.ID`; `GuiManager.get_IsPlayingEvent` | Dump + signature probe (`get_IsPlayingEvent` confirmed) | Hooking local cutscene starts (play/start requests only; preloads, stops and queries excluded), replaying the partner's |
| Pauses | `share.PauseManager` with `Dictionary<UInt32, PauseParameter {TargetUpdate, TargetDraw}>`, `PauseType` and `chainsaw.PauseManagerCustom.CustomPause` enums; `PauseLayer` = {Self 1, Inventory 2, Map 4, …} (§3.5) | Dump | Neutralising menu pauses (their targets set to 0 while in a session, restored afterwards), optionally refusing the requests |
| Location | `PlayerContext.get_CurrentStageID()`, `CampaignManager.get_CurrentChapter()` (ChapterID 21100 = chapter 1 … 25400 = chapter 16) | Live (AP Wizard, this mod's dump) | Where each player is |
| Warp | `Prefecture/Location/EnvSceneManager.requestToChangeStatus(id, Nullable<EnvSceneStatus> = 3, priority 1)` (prefecture = stage / 1000, location = prefecture × 1000), then `CharacterManager.requestWarp(ContextID, Nullable<vec3>, Nullable<Quaternion>, StageIdentifier.setup(location, stage, 0))` | Live (AP Wizard typewriter warps; technique by JumperDenfer, Nexus 5923) | Travelling to the partner in another stage |
| Chapter switch | Hook `CampaignManager.loadGameSaveData(GameData)`: set `_InitialSettings._Chapter` and `_SpecialJumpSequence` (6 = chapter 1 … 21 = chapter 16) before the load runs | Live (AP Wizard chapter select) | Loading the host's chapter |
| Reload | `GameOverManager.get_Mediator().requestGameOver(new GameOverRequest)` → *Continue* reloads through `loadGameSaveData` | Live (AP Wizard DeathLink) | Starting the chapter switch without the menu |
| Enemy AI | `CharacterContext.get_HeadGameObject()` (the AI "head": think, targeting, `HateController`) vs the body (§3.5); `via.GameObject.set_UpdateSelf(bool)` | Engine + this mod's dump | Switching a mirrored enemy's AI off |
| Enemy animation | `via.motion.Motion.getLayer(0)` → `get_MotionBankID/get_MotionID/get_Frame`, `changeMotion(UInt32, UInt32, Single, Single, InterpolationMode, InterpolationCurve)` | Confirmed (EMV Engine) | Mirroring the owner's animation |
| REFramework | `SystemArray:get_element` returns boxed values for primitive arrays (`System.Array.GetValue`); `arr[i] = sdk.create_uint32(v)` writes through `SetValue`; `sdk.to_valuetype(ptr, "System.Guid")` reads a struct argument in a hook | Source | Reading/writing flag words and attribute bytes; GUID hook arguments |

Two things the dumps ruled out:

* **Spawn vetoes.** v0.2 (unreleased) refused spawns of enemies the host had killed at
  `CharacterSpawnController.permitSpawn`, keyed by ContextID. Enemy `_ID`s are runtime IDs
  (§3.3) and one spawner creates several enemies (waves), so a veto keyed by either would also
  refuse the *next* enemy of a wave. v0.6 kills late arrivals on pairing instead (§4).
* RE4 also contains a dormant `chainsaw.NetworkManager` / `ReNetUnit_*` family. Those are
  RE.NET statistics uploads (kills, items, objects destroyed), not gameplay networking.
  `GmCoopJump` and `CoopMediator` are Ashley's partner actions.

What v0.6 builds on that:

| Feature | How | Safety |
|---|---|---|
| Story progress, objectives, map, doors | Flag setter hooks report each change by GUID; the partner applies it with `requestSetFlag`, so whatever reacts to the flag reacts on both PCs | Echoes of our own applications are ignored; a flag that flips more than 6 times in 10 s (per-machine state) is muted for a minute; repeated sets of the same value are not resent |
| Locks, levers, puzzles | Gimmick table diffs (on `pushDirtyList`, and every 2 s, read 60 records per frame), sent by ContextID; the host re-broadcasts what it applies | Conflicts converge to the host's version. A record that *appears* (a gimmick loaded for the first time) is only added where the partner has none, and an area load (more than 16 new records at once) is not sent at all, so a gimmick's initial state never overwrites the partner's progress |
| Breakables and animals | Observed by GameObject GUID; destroyed objects are remembered and sent to a joining client | An area unload (objects vanishing far away or more than 4 at once) is not a break. Events for objects that are not loaded wait for them (30 min) |
| Cutscenes for both | A cutscene request (hooked) is sent with chapter, stage and position; the partner's game plays the same timeline event, after travelling there if it is more than 30 m away or in another stage | Played once even if both trigger it; dropped if the partner is in another chapter. The transition gate (§3.5) holds the first player until the partner is in the same event |
| No pauses | While hosting or connected, the parameters of menu pauses (inventory, map, files, pause menu, item pickup, typewriter, tutorials) freeze nothing; re-applied when the game rebuilds its table | Cutscene, movie and loading pauses are kept. Restored on leave and on "Reset Scripts". Mode *all* and a request-refusing mode are options |
| Join the host's game | Client: arm the chapter switch to the host's chapter (also from the title screen) and start the reload; once there, WORLD_REQUEST → full flags, gimmicks and destroyed objects → stage preload + `requestWarp` next to the host | Each step has a timeout and reports what failed; without a stage, a plain teleport |
| Follow the host | The client follows the host into a *later* chapter after 15 s (or at once with F6 when the host waits for it at the gate) | Never pulled back to an earlier chapter; the transition gate keeps the host waiting meanwhile |
| Enemies fight both players | Ownership: the host gives an enemy to the client when the client's player is closer by 2 m for 0.6 s (and back); the owner's AI runs it, the other game mirrors position, facing and animation from a 150 ms buffer and switches that enemy's AI head off | Only enemies the client reported having (ENEMY_CLIENT) are handed over; AI is switched back on before any kill, on hand-back, on disconnect and on "Reset Scripts"; every part has an option |
| Late arrivals, both ways | Host deaths the client did not witness are re-advertised for 10 min and kill the client's copy when its level spawns it; client kills of enemies the host had not loaded are remembered by the host and applied when they spawn there | Deaths the client saw are never re-advertised, and living host enemies pair first, so a wave enemy spawning where another died is not killed. A host checkpoint reload clears all death records on both sides |

## 4. Sync architecture

```
 PC A (host)                                          PC B (client)
 RE4 + REFramework                                    RE4 + REFramework
 ┌────────────────────────┐   UDP 33040 (direct IP)   ┌────────────────────────┐
 │ re4coop.lua            │ ◄───────────────────────► │ re4coop.lua            │
 │  session ─ enemy_sync  │   PLAYER (20 Hz, unrel.)  │  session ─ enemy_sync  │
 │   items, drops, gate   │   POSE / AVATAR / ACTIONS │   items, drops, gate   │
 │   flag/gimmick/object/ │   ENEMY_SNAPSHOT (15 Hz)  │   flag/gimmick/object/ │
 │   cutscene sync        │   ENEMY_CLIENT (20 Hz)    │   cutscene sync        │
 │   travel               │   ENEMY_DAMAGE/DEAD/HIT   │   travel               │
 │  game / game_world /   │   FLAGS, FLAG_WORDS,      │  game / game_world /   │
 │  game_pause (sdk)      │   GIMMICKS, OBJECTS,      │  game_pause (sdk)      │
 │  puppet (partner model)│   CUTSCENE, WORLD_*       │  puppet (partner model)│
 │ re4coop_net.dll        │   CHAT/NOTIFY/HELLO       │ re4coop_net.dll        │
 └────────────────────────┘                           └────────────────────────┘
```

* **Two full game instances, one world.** Each player runs their own RE4 with their own Leon,
  camera and inputs. The client joins the **host's world**: it is brought to the host's
  chapter (a reload with the chapter switch if needed), receives the host's flag and gimmick
  tables and the list of destroyed objects, and is warped next to the host. From then on
  every change on either side is replicated (§3.6).
* **Partner presence: their real character.** Each side describes its character once (AVATAR:
  character id, costume parts, skeleton joint list) and then streams its final pose ~30 times a
  second (POSE). The receiver spawns the partner's body prefab, dresses it and poses it, 100 ms in
  the past for smooth interpolation. Details in §4.1. Name tag, distance and HP bar are drawn on
  top.
* **Enemies: one shared set.**
  * Identity: the host numbers its enemies. The client pairs each with its own copy by **kind +
    spawn point** (deterministic level spawns), or by the enemy's **spawner ContextID** once
    spawner IDs have proven reliable (§3.3). Living host enemies are paired first.
  * Health and death: the host is authoritative. Client damage is detected by HP polling and
    sent as `ENEMY_DAMAGE`; the client only ever lowers HP and applies deaths. Deaths the client
    did not witness are re-advertised, and kills the host could not match wait for the enemy to
    spawn on the host (§3.6).
  * Movement and AI: each enemy is **owned** by the machine whose player is closer (2 m
    hysteresis, 0.6 s hold). The owner's AI runs it; the other machine **mirrors** it every
    frame (position, facing, animation) with its AI head switched off. So an enemy near the
    client attacks the client for real, and both see it in the same place doing the same thing.
  * Hits each player lands are replayed (cosmetically) on the other side's copy, and the host's
    random roll decides enemy drops for both (§3.5).
* **World: event + state replication** (§3.6): scenario flags by GUID through the game's own
  setter, gimmick records by ContextID, breakables and animals by GameObject GUID, cutscenes by
  timeline event ID.
* **No pauses in co-op** (§3.6): menu pauses freeze nothing while hosting or connected.
* **Key items exist once** (§3.2, §3.3): whoever picks one up keeps it, and the partner's copy
  is removed.
* **Left-behind prompt** (§3.2, §3.3): F6 when the partner has been far away or in another
  stage for a while; across stages the game's own warp is used, across chapters (client) the
  chapter switch.
* **Transition gate** (§3.5): the player who reaches a cutscene or a new chapter part first is
  held there (scene time scale 0) until the partner arrives; F8 continues alone. With cutscene
  replay the partner arrives *in* the same cutscene.
* **Utilities**: teleport/travel to partner, chat, notices ("partner is down", "teleported to
  you"), and a diagnostics panel with the research dump.

### 4.1 The partner's character

**Why poses, not animation ids.** RE4R's player animation is a stack of layers, FSMs, IK, aim
offsets, additive upper-body layers and physics (hair, cloth). Replaying motion bank + motion id
+ frame would need the same banks loaded on the copy (weapon banks are loaded on demand) and the
same FSM/IK state, and would still miss IK and physics. Copying the *final* pose avoids all of
that: whatever the partner's character does, every joint's local rotation is sent and applied.
Every state is covered by construction, including ones nobody listed.

**Capture (sender).** At `PrepareRendering` (end of frame, after animation, IK and physics, the
same point where EMV Engine's poser writes joints) the mod reads the local rotation of every joint
of the body skeleton plus the joints only a part has (face, hair), up to 512, and the local
position of root/hip joints. Packed to 32 bits per joint (§PROTOCOL), ~1.2 KB per pose. Joint
objects are never read after their transform changed (costume swap): the description is
rescanned instead. The weapon is reported relative to the joint it hangs from (its
`ParentJoint`), so the copy can hang it from the same joint.

**Building the copy (receiver).**

1. Find the body prefab from the character id (§3.4) and load it (`set_Standby`, wait for
   `get_Ready`, `instantiate`).
2. *Sanitize*: every component of the spawned tree whose type starts with `chainsaw.`, `app.`,
   `via.behaviortree.`, `via.physics.`, `via.motion.Motion`, `via.motion.Ik`, `via.navigation.`,
   `via.dynamics.`… is disabled. Rendering, sound containers, effect providers and cloth/hair
   chains keep running. The copy has no logic, no collision, no AI, and cannot shoot.
3. *Rename* every spawned object `re4coop_<name>`, so the game's own lookups by name (and
   ours) keep finding the real player, and remember them so capture never mistakes them for ours.
4. *Dress it*: the prefab's meshes are matched with the partner's parts by mesh path. Materials
   are switched to the partner's (dirt/blood variants), meshes the partner does not wear are
   hidden, and missing parts are rebuilt as mesh-only objects (`GameObject.create` +
   `via.render.Mesh` + `setMesh`/`set_Material`) attached with the partner's parent joint and
   `SameJointsConstraint`.
5. If the prefab is missing, fails or takes over 15 s: *mirror mode*. The whole model is
   rebuilt from meshes, with the main (body) mesh on the root so the other parts follow its
   skeleton. *Options* has a switch to force this.

**Posing.** Each frame (`LateUpdateBehavior`) the copy's root goes to the partner's position and
every mapped joint gets its interpolated local rotation (unchanged joints are skipped). Parts that
follow the body by name only get the joints the body lacks. At `PrepareRendering` one body joint
is checked; if the engine overwrote the pose (an animation that could not be switched off), the
pose is rewritten there from then on. Teleports (over 2.5 m between poses) jump instead of sliding.

**Weapons.** Spawned from their prefab (`wp4000.pfb`), sanitized (so `chainsaw.Gun` cannot fire
real bullets), hung from the same joint with the same offset; slide/trigger joints follow;
hidden when the partner's weapon is hidden.

**Sounds and effects.** All `via.wwise.WwiseContainer.trigger*` and
`via.effect.script.EPVStandard.requestEffect*` overloads are hooked. A call on one of the local
player's components (body, parts, head object, weapons) is recorded with the component's type
and index and its arguments (numbers, booleans, GameObjects as part references, nulls). The
copy has the same components (same prefabs), so the receiver calls the same overload on the
matching component and the same sound plays from the copy's position, in sync with the delayed
animation. Calls whose arguments cannot travel (a request object) are replayed through the
simplest `trigger` overload with the same trigger id. The receiver's own replays are not
recorded (they are not on the local player).

**Shots.** `chainsaw.Gun` shoot methods are hooked when they exist (names probed), otherwise the
magazine count is polled. A shot whose weapon effects did not come through the effect mirror
gets the game's generic muzzle flash (`epve_0015_muzzleflash_0000.pfb`) at the copy's muzzle
joint.

**When it hides.** During the partner's or your own cutscenes (option), when both games report
different chapters, and when no pose arrived for 3 s. If the game unloads the copy with an area,
it is rebuilt.

### 4.2 Known limitations (v0.6)

* Nothing here has been verified in the running game yet. The riskiest assumptions are that the
  body prefab can be spawned outside the game's character spawner once its logic is disabled
  (*Build partner from meshes only* is the escape hatch), that switching an enemy's AI head off
  leaves its body and HitController working (*...with their AI switched off* is the switch),
  and that the probed flag/gimmick/cutscene methods are the ones named in §3.6 (*Diagnostics*).
* The copy is visual only: no collision, enemies don't see it, bullets pass through it. An
  enemy chasing the partner is run by the partner's game (ownership), so it does not target the
  copy on yours.
* Sounds the engine plays without going through the reflected `trigger` methods are not
  replayed. Thrown grenades, projectiles, bullet impacts and blood happen only in the thrower's
  game.
* Cutscenes that start without a hooked timeline request (movies) are not replayed; the
  transition gate and the flags still bring both players through them.
* A checkpoint reload (death, Retry) happens only in that player's game.
* Joining from another chapter, and following the host into the next one, go through the game
  over screen (*Continue*).
* Damage dealt to an enemy before your game has observed it once (the first ~50 ms after it
  spawns) is not reported.
* Both players need the same game version, REFramework build and mod version. A protocol
  mismatch is detected and reported.

## 5. Roadmap

1. **In-game validation of v0.6** with the checklist in [TESTING.md](TESTING.md), collecting
   `re4coop_typedump.json` + `re4coop_research_log.json` from several areas, and fixing any
   probed names with them.
2. Shared checkpoints: when one player dies, both reload (RE5/RE6 style), or the other revives
   them.
3. Event-driven damage via `chainsaw.EnemyManager.notifyHitDamage` hooks, to remove polling
   latency.
4. Replicate thrown objects (grenades, eggs, bolts) and hit effects on enemies.
5. The partner's model as an enemy target (`HateController.find/addHate`), so enemies run by
   your game can also turn on the partner standing next to you.
6. Optional Steam networking transport for NAT traversal.

## Sources

* REFramework source: [`include/reframework/API.h`](https://github.com/praydog/REFramework/blob/master/include/reframework/API.h), [`src/mods/ScriptRunner.cpp`](https://github.com/praydog/REFramework/blob/master/src/mods/ScriptRunner.cpp), [`src/mods/bindings/Sdk.cpp`](https://github.com/praydog/REFramework/blob/master/src/mods/bindings/Sdk.cpp), [`src/mods/PluginLoader.cpp`](https://github.com/praydog/REFramework/blob/master/src/mods/PluginLoader.cpp), [`scripts/utility/RE4.lua`](https://github.com/praydog/REFramework/blob/master/scripts/utility/RE4.lua), [`examples/example_plugin`](https://github.com/praydog/REFramework/tree/master/examples/example_plugin)
* [REFramework discussion #1112: creating a prefab instance in RE4](https://github.com/praydog/REFramework/discussions/1112)
* [resyst/re4r `srt-overlay.lua`](https://github.com/resyst/re4r/blob/master/srt-overlay.lua) and [Joydurn/re4r-SRT](https://github.com/Joydurn/re4r-SRT/blob/master/srt-overlay.lua)
* [GreenComfyTea/RE4-Health-Bars](https://github.com/GreenComfyTea/RE4-Health-Bars)
* [LiterallyMetaphorical/RE4R-AP-Wizard](https://github.com/LiterallyMetaphorical/RE4R-AP-Wizard) (scenario flags by GUID, typewriter warps with `requestWarp`, chapter select through `loadGameSaveData`, DeathLink game over, scene components and GameObject GUIDs, `permitSpawn` gates)
* REFramework [`shared/sdk/SystemArray.cpp`](https://github.com/praydog/REFramework/blob/master/shared/sdk/SystemArray.cpp) (boxed elements of primitive arrays, `SetValue` on write)
* [alphazolam/EMV-Engine](https://github.com/alphazolam/EMV-Engine) (RE4 resource lists; `create_gameobj`, `create_resource`, `via.Prefab.get_Exist`, the poser writing joints at `PrepareRendering`, Wwise/EPV calls, `findComponents`, `get_Components`)
* [alphazolam/RE_RSZ `rszre4.json`](https://github.com/alphazolam/RE_RSZ) (RE4 type names and serialized fields)
* [resyst/re4r `re4r.asl`](https://github.com/resyst/re4r/blob/master/re4r.asl) (key item IDs)
* [Ekey/REE.PAK.Tool](https://github.com/Ekey/REE.PAK.Tool) `Projects/RE4_STM_Release.list` (the RE4 Steam file list: character, costume, weapon, sound and effect paths)
* [SilverEzredes/Advanced-Weapon-Framework](https://github.com/SilverEzredes/Advanced-Weapon-Framework) (`RE4R_WeaponData.lua`: weapon ids; `chainsaw.Gun`, `chainsaw.PlayerEquipment`)
* [FRAMED: EMV Engine guide](https://framedsc.com/GeneralGuides/emv_engine.htm) (`ch0a0z0_body` is Leon)
* [RE4 Mod Menu (Nexus 7363)](https://www.nexusmods.com/residentevil42023/mods/7363), [True Invincible (Nexus 6165)](https://www.nexusmods.com/residentevil42023/mods/6165)
* claybtv Multiplayer Mod coverage: [Nexus 6539](https://www.nexusmods.com/residentevil42023/mods/6539), [Screen Rant](https://screenrant.com/resident-evil-4-remake-co-op-mod/), [Rely on Horror](https://www.relyonhorror.com/latest-news/resident-evil-news/resident-evil-4-remake-gets-full-co-op-mode-thanks-to-new-mod/), [Retro Dodo](https://retrododo.com/resident-evil-4-remake-now-has-a-co-op-mode-mod/)
