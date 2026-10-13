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
| **Method hooks**: `sdk.hook(method, pre, post)` | Capturing the local player's sounds, effects and shots so the partner's copy can replay them (§4.1), and every hit on an enemy (`HitController.callbackDamageHit`) with all its values, so the enemy's owner can run it (§3.10) |
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

> **Corrected in v0.8 (§3.8):** for enemies, group 12 is *not* a runtime counter. The game's
> code shows that a level enemy's `_ID` (and its `SpawnerID`) is the serialized `_ContextID` of
> the spawn param that created it, while runtime characters get group 1. Treating group 12 as
> "runtime" made v0.3–v0.7 throw away the one exact identity every enemy has.

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
| Scenario flags | Setters `(Guid[, Boolean])` on `ScenarioFlagManager` with an allow-listed name (`requestSetFlag`, `setFlag`, `...FlagOn/Off`, `resetFlag`...) | Dump + signature probe | Hooked to report local changes. Watchers, counters and locks are never hooked. Replaced in v0.9.1 by the change handlers (§3.11) |
| Scenario flags | `ScenarioFlagManager.SaveData {Datas: SaveGroup[] {GroupName, Flags: UInt32[]}}`, save/load methods returning/taking it | Dump + signature probe | Full flag copy for a joining client; 32-bit word diffs when no setter can be hooked |
| Gimmicks | `chainsaw.GimmickManager.SaveData {Datas: List<SaveItem {ID: ContextID, SaveData}>}`, `GimmickContext.SaveData {Attr: Byte[], TriggerSave: TriggerDone[] {SaveID, Done}, IsDetected, AccDatas: AccessoryData{Float,Uint}[]}` | Dump + signature probe | Locks, keys used, levers, shutters, puzzles: diffed and replicated by ContextID (the save table is what goes into save files, so its IDs are level IDs) |
| Gimmicks | `GimmickManager.pushDirtyList(context)` | This mod's dump (§3.5) | A gimmick announced a state change: its record is read and sent at once instead of at the next 2 s scan |
| Breakables, animals | `chainsaw.GmWoodBox`, `GmOilDrum`, `GmBottle`, `GmSimpleBreak`, `GmShootObj`, `GmBlueCoin`, `GmWindowBreakable`, `GmCrow`, `GmChicken`, `GmFish`, `GmBat`… with a `_Routine` state enum | Dump | Watched by GameObject GUID; a terminal routine name (`Break`, `Dead`, …) is "destroyed". Applied by setting the same routine (the object plays its own break/death), else a break/kill method, else hiding it |
| Scene | `via.SceneManager.get_CurrentScene` → `findComponents(System.Type)`; GameObject `ToString()` → `name@<guid>` | Live (AP Wizard) | Finding objects; a cross-PC object identity from the scene file |
| Cutscenes | `chainsaw.TimelineEventManager` methods taking `chainsaw.TimelineEventDefine.ID`; `GuiManager.get_IsPlayingEvent` | Dump + signature probe (`get_IsPlayingEvent` confirmed) | Hooking local cutscene starts (play/start requests only; preloads, stops and queries excluded), replaying the partner's. None exist in this build: replaced in v0.9.1 by `ClapperboardMediator.procPayloadPlay` (§3.11) |
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
| Story progress, objectives, map, doors | Flag setter hooks report each change by GUID; the partner applies it with `requestSetFlag`, so whatever reacts to the flag reacts on both PCs | Echoes of our own applications are ignored; a flag that flips more than 6 times in 10 s (per-machine state) is muted for a minute; repeated sets of the same value are not resent. The hooks do nothing outside a session, and if the game calls the setters more than 400 times a second they stop reading arguments for 5 s while word diffs take over, so the frame rate never pays for it |
| Locks, levers, puzzles | Gimmick table diffs (on `pushDirtyList`, and every 2 s, read 60 records per frame), sent by ContextID; the host re-broadcasts what it applies | Conflicts converge to the host's version. A record that *appears* (a gimmick loaded for the first time) is only added where the partner has none, and an area load (more than 16 new records at once) is not sent at all, so a gimmick's initial state never overwrites the partner's progress |
| Breakables and animals | Observed by GameObject GUID; destroyed objects are remembered and sent to a joining client | An area unload (objects vanishing far away or more than 4 at once) is not a break. Events for objects that are not loaded wait for them (30 min) |
| Cutscenes for both | A cutscene request (hooked) is sent with chapter, stage and position; the partner's game plays the same timeline event, after travelling there if it is more than 30 m away or in another stage | Played once even if both trigger it; dropped if the partner is in another chapter. The transition gate (§3.5) holds the first player until the partner is in the same event |
| No pauses | While hosting or connected, the parameters of menu pauses (inventory, map, files, pause menu, item pickup, typewriter, tutorials) freeze nothing; re-applied when the game rebuilds its table | Cutscene, movie and loading pauses are kept. Restored on leave and on "Reset Scripts". Mode *all* and a request-refusing mode are options |
| Join the host's game | Client: arm the chapter switch to the host's chapter (also from the title screen) and start the reload; once there, WORLD_REQUEST → full flags, gimmicks and destroyed objects → stage preload + `requestWarp` next to the host | Each step has a timeout and reports what failed; without a stage, a plain teleport |
| Follow the host | The client follows the host into a *later* chapter after 15 s (or at once with F6 when the host waits for it at the gate) | Never pulled back to an earlier chapter; the transition gate keeps the host waiting meanwhile |
| Enemies fight both players | Ownership: the host gives an enemy to the client when the client's player is closer by 2 m for 0.6 s (and back); the owner's AI runs it, the other game mirrors position, facing and animation from a 150 ms buffer and switches that enemy's AI head off | Only enemies the client reported having (ENEMY_CLIENT) are handed over; AI is switched back on before any kill, on hand-back, on disconnect and on "Reset Scripts"; every part has an option. Replaced in v0.8: the host runs every enemy (§3.9) |
| Late arrivals, both ways | Host deaths the client did not witness are re-advertised for 10 min and kill the client's copy when its level spawns it; client kills of enemies the host had not loaded are remembered by the host and applied when they spawn there | Deaths the client saw are never re-advertised, and living host enemies pair first, so a wave enemy spawning where another died is not killed. A host checkpoint reload clears all death records on both sides |

### 3.7 v0.7: crashes, stutter, lag and loot

The first in-game tests of v0.6 reported lag, low frame rate, stutter, crashes and enemy drops
that never synced. v0.7 is the answer to that report; it adds no new feature.

**The crash dump.** One `reframework_crash.dmp` (v0.6): an access violation reading address
`0x24` at `re4.exe+0x193f995`, on a game worker thread, about 20 game frames above
REFramework's update hook (so in the game's own update, not inside a Lua call). The code there
is compiled managed code:

```
mov  rax, [r8]            ; arg's type info
call is_instance_of(T)     ; if (arg is T t)
mov  rax, [r14+0x18]       ; t.field_18      -> null
mov  ecx, [rax+0x24]       ; field_18.enum   -> crash (0x0 + 0x24)
...
lea  r8, [r14+0x90]        ; an inline UTF-16 name inside the object -> new System.String
```

The heap is not in the dump, so the type cannot be named. A null at `+0x18` is what a
destroyed `via.GameObject` looks like (its Transform pointer is cleared), and the work runs
later on a worker thread. That fits the mod handing the game objects that no longer exist:
the permanent hit-replay template (a copied `DamageInfo` whose attacker, weapon, collider and
victim objects could be long gone), enemy mirroring writing to cached transforms of despawned
enemies every frame, world messages queued during a load and applied to the new scene, game
state changed from the render thread (UI buttons, the network fallback), and boxed values
passed where the game expects `System.Nullable` structs (stage preload, warps).

**What v0.7 changes** (each with a test against the mock):

| Area | Change |
|---|---|
| Stale objects | Every cached engine object is checked before use (`Game:alive`: the component's owner GameObject at `+0x10` is still a managed object; `Game:go_alive` for GameObjects). Enemy data is cached per context and dropped when its body changes. A reload (new player context) drops every cache in the game and world adapters |
| Hit replay | No permanent template. Off by default (*Experimental*). When on, the template is the latest hit of this scene, every object field is checked or replaced (our live body as attacker, the target's body as damaged object, dead objects cleared) |
| Loads | Messages queued while the game loop was not running are applied only after the game has been playable for a second, right after a fresh enemy list |
| Threads | UI buttons and the render-thread network fallback only queue actions; `Session:update` (LateUpdateBehavior) carries them out. Disconnects restore enemy AI on the game thread |
| Hooks | Hit, drop and gimmick hooks are installed when a partner connects and do nothing while none is (REFramework cannot remove hooks) |
| Risky features | Off by default, each with a switch in *Options → Experimental*: hit replay, cutscene replay (zero-argument timeline requests), cross-stage warps (the `Nullable` arguments are now built as real structs, but untested in game), the automatic game-over reload, live flag-table reloads, forcing a breakable's `_Routine`. Gimmick table reloads wait while loading or in a cutscene. Saving, the merchant and game over keep pausing in co-op. Old configs get the new defaults once (`config_version`) |
| Puppet | No second `.ctor` on created objects; a liveness check before the late pose write; muzzle flashes destroyed after 3 s instead of 0.4 s (an effect's GameObject must outlive the effect) |
| Breadcrumbs | `reframework/data/re4coop_breadcrumb.json`: the last ~48 things the mod did, with frame numbers; rare risky calls (kills, warps, table reloads, spawns, replays) are written before they happen |

**Performance.** v0.6 made roughly 90,000 engine calls per second in game, with bursts. The
biggest items and what replaced them:

* `Game:call` resolved the method through the object's type name on every call (three engine
  calls plus a closure and a string); now one `obj:call`.
* The avatar was rescanned every second (thousands of calls in one frame); now a cheap check
  (body, skeleton size, children, part meshes) runs once a second and a scan only on change.
  Gear every second instead of four times; the scene search for loose weapons ten names at a
  time instead of seventy.
* Pickups: what never changes for an item is read once per component (4 calls per item per
  scan instead of ~12).
* Objects: 4 of the ~30 breakable/animal types are searched per scan instead of all of them.
* Gimmicks: only the records whose gimmick announced a change (`pushDirtyList`) are read, a
  full comparison every 30 s instead of every 2 s; flag words every 5 s. Boxed array elements
  read with one engine call instead of up to five.
* Enemies further than 50 m are read in full every 4th tick; animation only for enemies the
  partner mirrors.
* The partner's model writes joints only when they move, every frame within 8 m, every 2nd
  frame up to 40 m, every 4th beyond; the pose is sent at half rate beyond 40 m and at 5 Hz
  while the partner is in another chapter.
* The HUD's status is computed once per frame (it was computed up to three times).

*Diagnostics → Performance* shows the mod's cost per frame, its worst frame, frames over 4 ms
and the busiest parts, and writes them to `re4coop_perf.json` every 10 s. The call-budget test
(`tests/lua/test_call_budget.lua`) measures ~6,500 engine calls per second against the mock (10
enemies, 90 pickups, a connected partner; the mock's skeleton has 34 joints where Leon has
~350) and fails above 12,000 or a frame above 1,500.

**Lag.** Built-in delay was ~150–200 ms: 100 ms interpolation, a pose captured at the end of one
frame and sent in the next, timers that drifted with the frame rate, and joints that froze
when a pose was late. Now: 66 ms interpolation (adaptive: more only when jitter needs it),
the pose is sent at the end of the frame it was captured in, rates are exact, all pose chunks
are sampled at the same instant, joints move on for one pose interval when a pose is late,
enemy snapshots go at 20 Hz with a 100 ms mirror buffer. Transport: 1200-byte datagrams (VPN
tunnels never split them), a second, unordered reliable lane for sounds and effects (a lost
packet no longer holds back flags and deaths), and per-packet resend backoff.

**Loot.** v0.6's drop hook only reported a drop when `cc` was a known enemy, but `cc` is the
*player*: the roll is tailored to that player's inventory (`RandomDrop.calcRandom(droptype, cc,
inventory, order)`, `calcPointInInventory(..., cc, inventory)`, `calcPointAround(id, cc)`).
The dropper is `order` (a `chainsaw.Context`: enemy or box). So the hook never fired and the
host-roll design never started. You asked for each player to get their own roll from every
enemy, including the partner's kills, so v0.7 drops the host roll entirely:

* `requestGenerateRandomDrop` (both overloads) and `generateRandomDrop` are hooked; a call whose
  `order` (or `cc`, or GameObject) is one of our enemies means that enemy rolled its loot here.
  The research log records the argument types of every call (`drop_calls`), to confirm this.
* An enemy that dies in our world because the partner's game killed it (enemy sync's kill) and
  shows no roll within `wait` seconds is rolled by us: `generateRandomDrop(droptype, our player,
  its position, stage, the enemy, option)`, exactly once. `wait` is learned from our own kills
  (how long the game takes to roll after a death); a kind that dies by our hand without a roll
  is never rolled for the partner's kills either. Nothing is rolled until the hooks have seen
  one roll of the game's own (otherwise a missed hook would double the loot).

### 3.8 v0.8: enemy sync on the game's own identities

In-game reports of v0.7: enemies one player killed were still alive for the other, enemy
positions were often wrong on one screen, and enemies spawned differently. v0.8 rebuilds
enemy sync on how RE4 itself identifies, spawns, kills and persists enemies.

**How this was established.** REFramework had written its type dump (`il2cpp_dump.json`, 1 GB:
every type, field, method and the address of its compiled code) into the game folder. Its
addresses still match the current `re4.exe` (checked on getters such as
`CharacterContext.get_SpawnerID` = `mov rax,[rdx+40h]; ret`). The functions below were cut out
of `re4.exe` with their `.pdata` bounds into small PE files, decompiled with Ghidra (through
REA), and their calls named from the dump. Addresses are for the October 2026 build.

| Function (address) | What it does | Consequence |
|---|---|---|
| `CharacterSpawnParam._ContextID` (RSZ field) | Serialized in the scene file | Level data: the same on both PCs |
| `CharacterSpawnParam.createCharacter` (`0x1424C49E0`), `updateSpawn` (`0x142559670`) | `CharacterInstanceCoordinator.requestCreateBody/Head(this._ContextID, kind, Spawner)` and `CharacterLinkCoordinator.requestSpawn(_ContextID, _ContextID, …)` | A level enemy's own `_ID` **and** its `SpawnerID` are that ContextID |
| `CharacterManager.generateDynamicContextID` (`0x143425CA0`) | `new ContextID(Character, 0, 1, counter)`, counter `& 0x7FF` | Runtime characters live in group 1 (machine-specific); group 12 is level data |
| `CharacterSpawnParam.isNextSpawn` (`0x1424F0410`) | Reads the live context's `IsEliminated` (`+0x5A`), else `CharacterManager.getBackupData(_ContextID)._IsEliminated`; if set, `invalidateSpawn(true)` and never spawns | Eliminated = gone for good, also after the area reloads |
| `CharacterContext.eliminate` (`0x140174160`) | `IsEliminated = true` | Marks an enemy as finished |
| `CharacterSpawnParam.invalidateSpawn` (`0x1424EDB70`) | Status bit 8, then `updateSpawn`: `requestSuspend`, `releaseControl`, `requestDestroyBody/Head` | Despawns the enemy at once: no death, corpse or loot |
| `CharacterManager.storeContext` (`0x1434C0E00`) / `restoreContext` / `getBackupData` (`0x143427050`) | Backups in `CharacterBackupDB` (ConcurrentDictionary: ContextID code → `CharacterBackup`, saved with the game), written when a character is unlinked (`CharacterLinkInfo.doneUnlink`, `storeContextAll`), restored when it is linked again | The save remembers every enemy (HP, position, `_IsEliminated`) |
| `CharacterSpawnPointController.getNextSpawnParam` (`0x1419508C0`) | The first pool entry not yet in `SpawnedDataList` | Wave/spawn-point enemies come from a pool of spawn params, each used once: one ContextID = one life |
| `HitPoint.dead` (`0x14028F870`), `get_IsLive` | `IsHPChanged = 1; CurrentHitPoint = 0`; alive = HP > 0 | A kill is data; the enemy's own logic plays the death |
| `CharacterInstanceCoordinator` | `HeadPoolList`, `BodyPoolList`, `findUsableHead/Body` | Heads and bodies are pooled and reused by later enemies |
| `CharacterContext.setTransform` | Sets the context transform, fires `OnChangeTransform`; used by `requestWarp` and spawn relocation | The game's own character teleport (not used yet) |
| `GmCrow/GmChicken/GmFish/GmBat/GmMouse.RoutineType` | All have `Die`/`Dead` (fish also `Erase`); `GmAnimal._DeadSetFlag` | Animal deaths are detected by `object_sync`; animals themselves: §3.9 |

Everything in `EnemyContextList` derives from `chainsaw.EnemyBaseContext` (Ganados, dogs,
Novistadors, bosses: ch1/ch4/ch7/ch8 kinds); `ch2` kinds are partner NPCs and are not synced.

**What was wrong, and what v0.8 does instead.**

| Problem | Cause | v0.8 |
|---|---|---|
| Enemies paired with the wrong one | Pairing by kind + first-seen position within 3 m; spawn-point controllers place the same enemy at different points on each PC; the exact ID was discarded as "runtime" | Pairing by **uid** (the ContextID code of the enemy's own `_ID`): exact, whatever the positions. Kind + spawn point only for runtime (group 1) enemies |
| Killed enemies alive for the partner | Deaths re-advertised by position, only those seen during the session | A **graveyard**: every enemy dead in the host's world by uid - deaths it sees, the client's kills of enemies it had not loaded, and, for a joining client, every enemy its save has eliminated (`CharacterBackupDB`, read 48 backups per tick). The client removes them wherever they appear: one dying in front of the player (known ≥ 1 s, within 40 m) is killed with `HitPoint.dead` (death animation, loot); one that just spawned or is far away is **erased** with the game's own `eliminate` + `invalidateSpawn` (never appears, never comes back). An erase the game ignores becomes a kill after 3 s |
| Enemies frozen or standing still | Heads switched off for mirroring went back to the game's pool switched off when their enemy despawned | The adapter remembers the head it switched off and switches it back on when the enemy leaves the list, gets another head, or the game reloads |
| Enemies jumping between players, positions that disagree | Each game ran some enemies: ownership moved an enemy between the games with distance and hits | **The host's game runs every enemy** (§3.9): an enemy never changes hands, and the client's copy follows the host's from the moment they pair |
| A client reload brought enemies back | Nothing re-applied the host's state | A client whose game reloads (same chapter) requests the host's world again: flags, gimmicks, objects and the graveyard |

The UI's enemy section keeps the tweaks that help (master switch, same positions, animation,
erasing, smoothing, loot, animals) and drops the ones that could only break sync (separate
HP/death switches, AI-off switch, pairing radius, legacy snapping, and the ownership switches:
the host runs every enemy).

### 3.9 v0.8: one authority - everything follows the host

The first v0.8 builds still let enemies change hands: each enemy was run by the game of the
closer player (or of the one fighting it alone), and the other game mirrored it. That is two
authorities over one enemy, kept apart by hand-over rules. v0.8 drops it: **the host's game
runs every enemy and every animal; the client's game shows them.**

| What | Host | Client |
|---|---|---|
| Enemies the host has loaded | AI, movement, HP and death run normally | Copies paired by uid follow the host's: AI head off (`set_UpdateSelf(false)` on the head GameObject), position, facing and animation from a 100 ms buffer, HP lowered to the host's. Damage the client's player deals goes to the host (ENEMY_DAMAGE); a copy the client kills gets its AI back so its own death plays, and the host kills its enemy |
| Enemies only the client has loaded | (not spawned yet) | Held (since 0.8.1, `enemy_host_only`): AI head off and not drawn (`set_DrawSelf(false)` on the body and everything under it) until the host's level spawns them; from then on they follow the host's. A copy without news from the host waits where it is. The client's player can still shoot and kill a held enemy: it dies with its own logic and the kill waits in the host's graveyard |
| Animals within 50 m of the client's player | Normal | Follow the host's (below); the ones the host does not report are taken off the move list where they are (0.8.1) |
| Deaths | The graveyard (§3.8) | Removed or killed as in §3.8 |
| Flags, gimmicks, breakables, cutscenes | Shared both ways with the host as referee (§3.6): the client must still be able to open doors and progress | |

Consequence: RE4's enemy AI picks its targets among the characters of its own game. The host's
enemies only know the host's Leon (the partner's model is visual only, §4.1), so enemies chase
and attack the host's character, and the client's character is not attacked by enemies the
host's game has loaded. Making the partner a target in the host's game is on the roadmap (§5).

**Animals.** Established like §3.8 (functions cut out of `re4.exe`, decompiled with Ghidra
through REA; addresses for the October 2026 build):

| Function (address) | What it does | Consequence |
|---|---|---|
| `GmCrow`, `GmChicken`, `GmFish`, `GmBat`, `GmMouse` | Derive from `chainsaw.GmAnimal` → `GmBase` → `via.Behavior`; `GmAnimal._Motion` is a `via.motion.Motion` | The animals; their animation is an ordinary motion layer |
| `GmAnimal.lateUpdate` (`0x140749DD0`) | Only pauses and resumes the Motion during the game's pauses | Switching the animal component off would not stop its AI |
| `GimmickCore.update` (`0x142219040`) | Registers the gimmick, then (state 2) calls `onGimmickMove` on every `IGimmickOnMove` in `_GimmickMove`. When `GimmickManager` has its updater behaviour (`_Bhv`), the core calls `registerMove(core)`, sets `_HasRegisteredMove` and switches itself off (`ComponentEnableMediator.request(core, false, …)`) | A gimmick's AI normally runs from `GimmickManager`'s move list |
| `GmBase.onGimmickMove` (`0x14044F4A0`) | Tail call to the virtual `updateGimmick` | `updateGimmick` is the animal's AI (`GmCrow.updateGimmick` `0x14254F6F0` switches on `_Routine`) |
| `GimmickManager.registerMove` (`0x141022470`), `unregisterMove` (`0x14105F8B0`) | Add / remove the core in `_Move` under `_LockMove`, then `_RenewMoveArray = true` | Taking a core off the list stops that animal's AI; putting it back resumes it |
| `GimmickCore.finish` (`0x142183410`) | The only caller of `unregisterMove`; clears `_HasRegisteredMove` | A core whose flag went false was finished by the game and must never be registered again |
| `GmCrow.onHitDamage` (`0x142502EB0`) | Called from the hit system; ends with `set_Routine(Die)` | A shot kills an animal even while its AI is off the list; the death plays once it is back |
| `GmCrow.set_Routine` (`0x142530960`), `updateDie` (`0x14254DD10`) | `_Routine = value`, step counter 0; Die: die motion, fall, effects, then the gimmick flag | The death the mod applies is the game's own entry into it: `set_Routine(Die)` |
| `RoutineType` values | Crow Die 7, Dead 8 (some deaths end in Loop 10); chicken 6/7; fish 4/5 (Erase 6); bat 2/3; mouse 6/7 | "Dead" = a routine named Die/Dead, read from the enum at runtime |

So the client takes its copy of each host animal off `GimmickManager`'s move list (or switches
its core off when it updates itself), writes the host animal's position and rotation every frame
(every third frame beyond 20 m) and plays its animation (`changeMotion` on layer 0). It looks at
the copy's routine ten times a second: a copy the client's player shot goes back on the list at
once to play its death, and the kill goes to the host as OBJECTS. A host animal that dies is put
back and given `set_Routine(Die)` where it followed the host's. Leaving, disconnecting, a reload
and "Reset Scripts" put every animal back, unless its GameObject is gone or the game finished its
gimmick. Animals are found in the breakables' scan (§3.6) and paired by GameObject GUID. Before
this, the partner's kill only hid an animal (no animal has a kill method); now it dies.

**Head pool crash (0.8.1).** The 0.8.0 client crashed with an access violation at
`re4.exe+0x1273425`, called from `EnemyHeadUpdater.update`. Disassembly of
`CharacterHeadUpdater.update` (`0x1412733C0`): it loads `HeadUpdater.<Context>` (offset 0x50),
checks its type, and then reads `Context+0x148` without a null check. A head whose updater has
no Context is a head in `CharacterInstanceCoordinator`'s pool. 0.8.0 switched every head it had
switched off back on (`set_UpdateSelf(true)`) when its enemy left the list, which is exactly when
the game had just put that head back in the pool, so the next frame updated an unlinked head. Since
0.8.1 a head is only switched on while `HeadUpdater.get_Context()` is set. A pooled head we
switched off is parked and switched on as soon as the game links it to its next enemy (checked
every 0.1 s). Bodies hidden for held enemies are handled the same way: drawn again when an enemy
shows up with that body.

**REFramework references (0.8.1).** The `REManagedObject:release attempted to release an object
that was not managed by our Lua state` warnings came from the mod itself. REFramework adds a
reference when it hands a managed object to Lua and releases it when the Lua value is garbage
collected (`__gc` calls `release`; `src/mods/bindings/Sdk.cpp`). The mod also called
`release()` itself, so the collector's later release found nothing to drop. That was
harmless, but it logged a warning every time and could release an object early if the game handed
the same pointer to Lua again in the meantime. The mod now only calls `add_ref()` on objects it
creates and lets the collector release them.

### 3.10 v0.9: enemy sync rebuilt from scratch

v0.8 made the host's game run every enemy and turned the client's copies into followers. That
left gaps players see at once: the host's enemies only ever attack the host (RE4's AI targets
the player of its own game), the client's hits only changed a number on the host (no flinch, no
stagger, no knock-down: the host's enemy never reacted), deaths happened in the client's game
with its own, unrelated death reaction, the client's copies played only the base animation layer
and drifted out of step (the body's own animation state machine kept choosing motions), and only
the heading travelled. v0.9 deletes `enemy_sync.lua` and its five messages and replaces them
with `enemy_net.lua` (logic), `game_enemies.lua` (the game side) and protocol 9.

**One owner per enemy, with epochs.** Every enemy is run by exactly one game, its owner; the
other game shows a puppet. The host numbers its enemies (net ids, as before) and decides who
owns what; every change bumps the enemy's ownership epoch (u8, 0 = never assigned), and state
or hits of another epoch are ignored, so two AIs never run one enemy. With
`enemy_authority = "shared"` (default) an enemy belongs to the game of the player it is closer
to (3 m margin, 0.75 s hold, at least 2.5 s with an owner, +4 m for the player who hit it in the
last 3 s, never a player who is down, in a cutscene or 80 m away): **enemies attack both
players**, each with its own game's real AI. `"host"` keeps every enemy with the host (0.8's
behaviour). A hand-over continues from the latest state the new owner received (position
extrapolated by the sender's velocity, HP never raised), so nothing jumps. Races are closed by
design: a hit that crossed a hand-over is sent back (BOUNCE) and runs once; the old owner reports
the HP its own player took off the enemy after the host's last look at it (the HP travels in
ENEMY_OWNER); an owner that lost its copy (area unloaded, reload) gives the enemy back; a host
enemy that left the host's world is retired and the client's copy runs on its own again.
Enemies the host has not loaded run on the client's own AI (shared) or are held still and unseen
(host authority); when the host's level spawns them, the damage the client did stays.

**Full state.** The owner sends, 20 times a second, for each of its enemies: position, the full
rotation (smallest-three quaternion: enemies that climb, crawl or fly turn about every axis),
velocity, HP, max HP, whether its game draws it, and up to three animation layers (motion bank,
motion id, frame, speed: `via.motion.TreeLayer`). Entries are packed into as few datagrams as fit
(about 46 bytes plus 16 per layer).

**Puppets.** A puppet's AI head is switched off (`set_UpdateSelf(false)` on the head
GameObject, with 0.8.1's pool safety: a head is never switched on while its HeadUpdater has no
Context) and so is the body's animation state machine (`via.motion.MotionFsm2`, re-enabled with
the AI): otherwise the body keeps choosing its own motions and overrides what we write, which is
what made 0.8's copies drift and snap. Position and rotation are written every frame from a
100 ms interpolation buffer (+ `CharacterController.warp`). Each animation layer is corrected at
the state rate: another motion → `changeMotion(bank, id, frame, 6 blend frames)`, the same motion
more than 4 frames off → `set_Frame` (or `changeMotion` without blending), another speed →
`set_Speed`; in between the game plays the motion on by itself, so the animation is as smooth as
the owner's. Visibility follows the owner's (`set_DrawSelf` on the body tree).

**Hits run in the owner's game.** `HitController.callbackDamageHit(DamageInfo)` is hooked on
every character. The pre-hook reads every primitive field of the DamageInfo and its parent types
by reflection (ints, floats, bools, enums, `via.vec3`; no objects, nothing named like a serial,
handle, frame or time) - no field name is hard-coded, both games run the same build, so FNV-1a
of the name addresses the same value on both sides (*Diagnostics*: `hit_values`; the research
dump lists them). A hit our player lands on an enemy the partner owns travels as ENEMY_HIT with
all those values; the owner builds a fresh DamageInfo, writes them, makes its object fields safe
(our live body as attacker, the enemy as damaged object, dead objects cleared - the v0.7 crash
rules) and runs it through the enemy's own HitController: **the same damage, the same reaction
(flinch, stagger, knock-down, part breaks), the same result** as in the shooter's game. In the
shooter's game the hit happens too (blood, part breaks, its HP at once), but the pre-hook lowers
a lethal hit's Damage so it leaves 1 HP and clears IsKill: a puppet never dies there. Its HP
then follows the owner's, and is not given back while one of our hits is in flight (the owner's
state acknowledges the last hit it ran; after 1 s the owner's HP counts again). Damage a puppet
takes from anything else (a barrel, a fall) is reported to the owner as plain damage. Without
values (or if the hit cannot be built) the owner subtracts HP.

**Deaths with the killing hit.** Only the owner decides a death. It announces it (ENEMY_DEATH)
with where the enemy died, its rotation and the values of the last hit it took (kept by the hook
for every hit, whoever landed it). The other game takes its puppet off the stream, puts it
there, switches its AI and animation driver back on and kills it by running that hit with
`IsKill` and enough damage: **the same kind of death in both games**, and its own death logic
(ragdoll, dissolve, loot roll). Without a hit, `HitPoint.dead()`. The graveyard, erasing and the
save scan of §3.8 stay, now for both directions.

What is still not the same in both games: physics after death (ragdolls are simulated in each
game), effects spawned by the AI itself (both games play them from the animation, but not the
same particles), and grabs: a puppet's grab plays its animation, the grabbed character's own
reaction exists only in the owner's game.

### 3.11 v0.9.1: player events for both players

Report: when one player set off a level event (walked into an area that starts a scripted
scene) or a cutscene, the other player saw nothing. The in-game log and re4.exe's code (read
at the addresses of the REFramework dump, decompiled function by function) showed why:

1. **The flag hooks watched the wrong thing.** v0.6 hooked `ScenarioFlagManager` setters by
   name and took their Boolean for the value. `requestSetFlag(Guid, Boolean)`'s Boolean is
   `ck_readonly` (the method only ever turns a flag on), and most flags never go through it: the
   game sets the `via.userdata.Variable` behind a flag directly, from portrayals, cutscene
   start/end flags, gimmicks. Most changes were never seen.
2. **The save probes found nothing.** `saveGameSaveData`/`loadGameSaveData` are declared with
   `share.SaveDataBase`, not with the manager's own SaveData type ("0 flag groups, 0 gimmicks"
   in the log): no full flag copy for a joining client, no word diffs, and no gimmick sync at
   all (doors, locks, levers).
5. **A skip was local**: skipping a cutscene skipped only that player's copy.
3. **Cutscene sync could never start.** Its probe looked for `TimelineEventManager` methods
   taking a `TimelineEventDefine.ID`; this build has none, so the feature was empty (and off by
   default, as experimental).
4. **Level triggers were never replicated**: an area trigger runs only in the game of the
   player who walked into it.

What the game's code shows (addresses in re4.exe of this build):

| Area | Member (address) | Finding |
|---|---|---|
| Flags | `via.userdata.Variable.set_Bool` (0x1402bd2f0), `setTrigger` (0x1402b09d0), `get_TypeKind` (0x1402b6380), `get_Guid` | Every scenario and common flag is a Variable: a GUID and a value. TypeKind 2 = Boolean, 16 = Trigger (fires for a frame) |
| Flags | `GlobalUserDataManager.registerValueChangedEvent(Guid, Action<Variable>)` (0x142390560); `ScenarioFlagManagerBehavior.start` (0x141442620) registers `onSetScenarioFlagEvent(Variable)` (0x1413fdee0) and `onSetCommonFlagEvent(Variable)` (0x140531a00) | Every flag change, whoever makes it, reaches one of these two handlers: one hook point for all of them |
| Flags | `GlobalUserDataManager.findVariable(Guid)` (0x14233e6a0), `trySetBool(Guid, Boolean)` (0x140a312e0), both static | Find and set any flag by GUID; its change event runs, so the game reacts as to its own |
| Flags | `ScenarioFlagManager.requestSetFlag(Guid, Boolean ck_readonly)` (0x141234060), `checkFlag(Guid)` (0x14050b120) | Fallback setter (on only) and reader |
| Flags | `ScenarioFlagManager.saveGameSaveData() -> share.SaveDataBase` (0x141238e50), `loadGameSaveData(share.SaveDataBase)` (0x1411ec760); `_Group[]` (0x20), each with its `<Variables>`: bit i of a group's words is variable i | Full copy for a joining client; live bits set variable by variable |
| Cutscenes | `ClapperboardMediator.requestPlayWithID` (0x1419baa60) → `setupAndCheck` (0x1419df720: the play-once check against `_HasDone`, a `HashSet<via.Int2>` of camera type and id) → `calcRequest` (0x141913670) → `PayloadPlay.createPayload` (0x141f54db0) → `procPayloadPlay(UInt32, PayloadPlay)` (0x1419b1ae0), which also adds the cutscene to `_HasDone` | Every "play once" camera request (story cutscenes, movies) ends in one call with one data object |
| Cutscenes | `PayloadPlay {CameraType 0x10, ID 0x14, Screen 0x18, EndFlag 0x20 and StartFlag 0x28: FlagInfo[] {GroupIndex, Index}, CoorsSettings 0x30: PlayerCoordSetting.Pack[], DataOwnerCode 0x38, EndPortrayal 0x3c}`; `emitPlayID` (0x1419328f0); `checkHasDone(Int32, Int32)` (0x140b6e2b0) | Pure data - no callbacks, no object references - made to be handed to another game (a dormant online design). The partner's game plays it through its own procPayloadPlay: its copy sets its own flags, places its players and continues its own scripted sequence (the data owner's EndPortrayal) |
| Triggers | `InteractTrigger.Work.executeTrigger(GameObject target, GimmickSensorUserData)` (0x14079c380) → `InteractTrigger.execute` (0x140827650), which calls the `_Execute` callbacks the GameObject's gimmicks and settings registered (`InteractHolder.initParamObjects`, 0x142fa5f60) | Every trigger InteractManager accepts, with the GameObject (body or head) that set it off |
| Triggers | `InteractTrigger {UniqueName 0x20, Succeed 0x28 (Once = 1)}`, `get_Type` (AreaHit = 1), `get_Owner`, `get_Hash` (0x140818680), `get_Done` (0x1400f7490), `recvDone(UInt32)` (0x1417cee90) | A play-once trigger is marked done (and saved with its gimmick) |
| Triggers | `InteractHolder.findTrigger(UInt32 hash)` (0x142f8be80); `via.Scene.findGameObject(System.Guid)` (0x140a89e60) | The same trigger in the partner's game: the GameObject's GUID (scene file) and the hash of the trigger's name |
| Skips | The skip button (`EventPauseSkipGuiBehavior`, through `PlayWork`'s GUI callback 0x1405b94f0) only sets `PlayWork.InputSkip` (0x35). `ClapperboardMediator.procSkip(PlayWork)` (0x1419b28a0) skips a camera that `canSkip()` with InputSkip set: `DoneSkip` (0x34) = 1, then `onRequestedSkip` (`PlayWorkTimeline`: 0x1439631b0). `_Plays` (0x28) holds one PlayWork per screen, with `CamType` (0x14) and `get_CameraID` | A skip is seen as DoneSkip turning on, and applied in the partner's game through the same InputSkip, so the game's own rules (unskippable cameras, the skip fade) apply |
| Gimmicks | `GimmickManager.loadGameSaveData` (0x140ff4010) starts with `clear()` (0x140fa76d0) of the whole manager, then for each saved record finds its context and calls `GimmickContext.loadSaveDataFromManager(SaveData)` (0x1411ecde0: `_SaveCur` = a clone, a new `_SaveBuff`, then the context's `onLoadedGameSave`) and `pushDirtyList` (0x14101f290). `findContext(ContextID)` (0x140fbd7a0); `saveGameSaveData` (0x14102d7c0) returns `share.SaveDataBase` | v0.6 applied partner states by rewriting the table and calling `loadGameSaveData` mid-game - a full clear of every gimmick. 0.9.1 applies one gimmick at a time the way that load does, without the clear |
| Doors | `GmDoor`: bit 0 of the context's first attribute = open (`Attr0Bit` Open 1, SideB 2, NoOne 4); `updateGimmick` (0x1428e67b0) opens a closed door whose bit is set; `updateOpen` (0x1428eb200) closes it - clearing the bit - once `checkClose` (0x142801830) finds no entry of `_NeedKeepOpenSelf` (0x1a0, `bool[]` by `NeedOpenSelfIndex` Host 0 / Guest 1) set and no forced keep-open. Host is our player (a timer refreshed in the doorway); Guest is only written by `recvGmParam(param_type, arg, user)` (0x1406b9720: `_NeedKeepOpenSelf[param_type] = arg != 0`) | A dormant two-player design: the partner's game opens the door when the shared state says so, but without the Guest slot nobody holds it there and it swings shut while it stays open for the player in it |
| Other doors | `GmKickOpenDoor` (a GmDoor that stays open once kicked). `GmAutoDoorBase` - `GmAutoDoor`, `GmAutoDoorMotion`, `GmElevatorDoor`, `GmTimingShutter`: `calcRoutine` (0x141cd1550) keeps it open while `_OpenTimer` (0xb4) > 0 or `_KeepOpen`; the sensor reloads the timer to `CloseWaitTime` by setting `_ActivateOpen` (0xb0), consumed each update; `_Rno0` (0xf0) Close 0 / Open 1. `GmBigDoor`: `updateOpened` (0x1410916b0) closes it once `IsAnyOneCloseToDoor` (0x164) is 0; `_Routine` Closed 0, Close 1, Open 2, Opened 3, ForceOpened 4. `GmShutter` is not of this kind: `updateOpen` (0x141091360) closes it only when it is locked again (a gimmick state the gimmick sync carries) | The same "open while someone is near" decision, each with its own switch |
| Events | `GmPortrayalAreaHit` → `PortrayalSettings.call(hash(UniqueName))`; `PortrayalSettings._Params._Params[]._CalleePlay/_CalleeEnd` are option parameters (`SetFlagSettings`, `ClapperboardSettings`, `MessageSettings`, `ObjectMoveSettings`, `PlDieSettings`, `InventorySettings`…) | What an area event runs, and so whether it is safe to run for both |

What v0.9.1 builds on that (protocol 10, config 10):

| Feature | How | Safety |
|---|---|---|
| Story flags | Both change handlers hooked: every flag change our game makes is seen. Flags turning on travel (FLAGS, ON) and trigger-kind flags that fire travel as PULSE; the partner applies them with `trySetBool` (else `requestSetFlag`) or `setTrigger` | Flags never travel *off*: a flag goes off only when a game loads an older state (a death, a checkpoint), which must not undo the partner's world; it is news again when it next turns on. While the partner's cutscene plays here, their flags wait for it to end (our copy sets its own start and end flags at its own time). Muting, echo suppression and the 400/s budget stay |
| Flag words | The full copy uses the save/load pair (now found). Live diffs carry only bits that turned on and are applied variable by variable through `_Group[]`; the live flag-table reload (`exp_table_reload`) is gone | A joining client still takes over the host's whole table |
| Cutscenes for both (default on) | `procPayloadPlay` hooked: the payload travels with where it started (CUTSCENE). The partner's game builds the same PayloadPlay and plays it through its own `procPayloadPlay` at once, wherever its player is (a partner more than 30 m away or in another stage is brought over when it ends, not before: travelling first made the partner's copy start seconds late). The transition gate counts a partner in an event anywhere as watching it with us | Never twice: `checkHasDone` (this save played it) and a 0.75 s grace in which the partner's own game may start it itself (the event trigger that started it arrives with it). Dropped in another chapter, after 5 refusals or 60 s. Our replays are not reported back |
| Skips for both (default on) | Every frame the adapter looks at `_Plays`: a camera whose DoneSkip turned on is reported once (CUTSCENE_SKIP: camera type and ID). The partner's game sets InputSkip on its PlayWork of the same camera - now, or when it starts there within 90 s (a replay that waits for the partner to arrive) | Our applications are not reported back. The partner's game decides with its own `canSkip`: a camera it does not let skip keeps playing |
| Doors for both (default on) | Every 0.1 s each game looks at the doors within 25 m of its player (by GameObject GUID): open or not, and held by its player. Changes travel as DOORS. The other game sets the same open bits (the door plays its own opening) and `recvGmParam(Guest, hold)`; automatic, elevator and shutter doors get `_ActivateOpen` every frame while the partner holds theirs (as if the partner stood in their sensor); big doors get +1 on `IsAnyOneCloseToDoor`. A player who walks out of range releases it | A door is open in both games while either player keeps it open, and closes in both when neither does. What a game does for the partner never counts as its own player's hold (else the two would keep each other's doors open forever). Everything is released when the partner leaves |
| Gimmicks (doors, locks, levers, puzzles) | The table is read through `saveGameSaveData` (now found). A partner state is written into a clone of the gimmick's own current SaveData (new arrays; accessory values only where ours has the same kind) and loaded into that one context with `loadSaveDataFromManager`, then `pushDirtyList` so the game saves it | Never `loadGameSaveData` while playing (it clears the manager). A gimmick not set up here yet keeps the state waiting (30 min) and gets it when its area loads. Not while loading or in a cutscene. An object already on screen may show the new state only after its area reloads |
| Level events for both (default on) | `executeTrigger` hooked: an area trigger our player set off is classified by its GameObject's components; an event travels as TRIGGER (GUID, name hash, play-once, chapter, stage, position). The partner's game, if its player is within 40 m in the same stage (or gets there, playable, within 20 s), finds the same trigger, marks it done the way InteractManager does and runs it with its own player | Only area triggers whose GameObject has an event component (portrayal, camera shot, mini demo, message, sound, flag, cutscene…) and no gimmick (`Gm*`, `Custom*`: doors, ladders, traps, levers) and no denied setting (deaths, inventory, item hand-outs, saves, game mode, tutorials), also checked in each portrayal's callees - and checked again by the receiving game with its own data. A partner far away is never forced: their game runs the event itself when their player walks in, so nothing that moves objects or colliders is skipped. Both setting it off at once is one event |

### 3.12 Giving items to the partner

A command of the game's own attache case moves an item from one player's case to the
other's. What re4.exe does (addresses of this build):

| Area | Member (address) | Finding |
|---|---|---|
| Command list | `InventoryManager.getItemCommandMenu(GetCommandMenuArgs {Item, SlotType, ...})` (0x142344820) | Builds a `Dictionary<ItemCommandType, Boolean>` (shown, enabled) with `Insert`; its only caller is `ItemWindowGuiState_AttacheCaseSelectCommand.onEnter` (0x1423733e0), which hands it to the case's command menu. `ItemCommandType` is fixed (Use 0 ... Store 13 ... WeaponRegist 27); `Store` is never offered by the case |
| Labels | `ItemCommandGui.drawCommand(cmd, selectable, item)` (0x1429d2760) writes the command's message into `_CommandText` (`via.gui.Text`) | A label can be replaced right after it is drawn (`set_Message`) |
| Choosing | `ItemWindowGuiState_AttacheCaseSelectCommand.decide` (0x14232f110): reads `_ItemCommandMenuGui.get_CurrSelectedCommandType`, checks `isSelectable`, then switches on the command; a command it has no case for ends in `ItemWindowGuiStateAcBase.transitAttacheCaseDefault` (0x142214b60) | Our command reaches `decide` and the game itself does nothing with it: back to the case |
| Taking it out | The discard's `AttacheCaseDiscard.onDecided` (0x1428686f0): `CsInventory.remove(Guid)` (0x142c94710) on the controller's `<_CsInventory>`, then `VirtualInventory.remove(Guid)` (0x142a44cd0) on `AttacheCaseManager.<AttacheCaseGuiDataHolder>._Inventory` (the open case GUI) | The same two calls take a given item out |
| Putting it in | `ChainsawGuiUtil.generateItem(ItemID, count, durability, ammo, ammoCount, bool)` (0x14329e0d0) - the factory gimmicks that hand out items use (`GmPowerOutage.getItem`); `ChainsawGuiUtil.getInventoryControllers(ContextID)` (0x1432a20a0) -> `InventoryController`; `CsInventoryController.add(Item, InventorySlotType)` -> `AddItemResult {ID, AddCount}` | The partner's game makes the item and adds it to its case; AddCount says how many fitted. (`InventoryControllersInfo.pickupItem` would open the "item get" screen, but needs a managed `Action<int>` the mod cannot build) |
| Item kinds | `ItemIDDefine.getItemType(ItemID)`: Key 0, Ammo 1, Hurb 2, Parts 3, Powder 4, Gun 5, Melee 6, Throwing 7, Durability 8, Treasure 9, CombinableTreasure 10, Money 11... `WeaponItem` carries ammo, parts and upgrade levels | Only Ammo, Hurb, Parts, Powder, Throwing and Treasure travel: an `Item` (ItemID + count) describes them completely |

What the mod does (protocol ITEM_GIVE 35 / ITEM_GIVE_RESULT 36, `give_sync.lua`, `game_give.lua`):
the "Give to <partner>" entry (`Store` with our label) is added last for a givable item while a
partner is connected; choosing it takes the whole stack out of the case and sends it. The
partner's game places it as soon as its case is closed and it is playable, and reports what
did not fit, which goes back into the giver's case. Items given to a partner who left before
confirming come back; an item that fits nowhere waits for room (the player is told).

### 3.13 The partner-hit crash and enemies that never spawned (0.9.1)

**Crash.** Windows kept four crash reports of re4.exe 1.5.9.0 from the co-op tests (Oct 11
18:11, 22:02, Oct 12 01:32, 03:33), all an access violation at the same instruction,
re4.exe+0x2009480, inside `chainsaw.HitController.playDamageSe(DamageInfo)` (0x142009440):

```
mov rdx, [r8+0x68]      ; DamageInfo.<AttackUserData>
mov rax, [rdx]          ; <- crashes when it is null
call [rax-0x10]+0x20    ; then DamageInfo.<AttackData> (+0x78) is read the same way
```

It runs inside `callbackDamageHit` whenever the hit character's HitController has a damage
sound container ([HitController+0x1c8]) - which is why the crash came "from one moment to the
next". The partner's hits and killing hits (§3.10) were run through `callbackDamageHit` with a
DamageInfo made by `sdk.create_instance` that carried every value of the original hit but no
`AttackUserData` / `AttackData` (`chainsaw.collision.AttackUserData` 0x68,
`AttackHitUserData.AttackData` 0x78, `DamageUserData` 0x70: the attack's and the damaged
part's data assets). Fix: the game that runs a partner's hit takes those objects from a real hit
of its own player (by WeaponID; any weapon otherwise; DamageUserData by enemy kind), keeps them
alive, and puts them into the hit it builds. Until its own player has hit something, a partner's
hit only changes HP and a partner's kill uses `HitPoint.dead()`. A pre-hook on `playDamageSe`
skips the sound of any hit we run that still lacks them.

**Second crash: the thrown body.** Oct 12 04:41, in the client: access violation at
re4.exe+0x37959f8 inside `chainsaw.RagdollUnit.onDamageHit(DamageInfo)` (0x143795890), right
after the client ran the host's killing hit on a `Ch1c0z0` (an enemy kind its own player had
never hit, so the hit carried no DamageUserData either):

```
mov rax, [rsi+0x78]     ; DamageInfo.<AttackData>, +0x34 = how the body is thrown (1/2 point, 5 blast)
mov rax, [rsi+0x48]     ; ContactInfo.<AttackGameObject>
mov rcx, [rax+0x20]     ; <- crashes when it is null (its position is the push's origin)
```

`addForceFromPointForce` (0x1437270e0), called next, reads `DamageInfo.<DamageUserData>` (+0x70)
`.Parts` (+0xa8, `chainsaw.character.BodyParts`) without a check too. A hit we build had both
null: AttackGameObject was only kept "if alive", and a fresh DamageInfo has none. Fix: a
replayed hit's AttackGameObject is our live body (like AttackOwnerObject); its DamageUserData and
DamageCollidable are the enemy's own, from `HitController.get_Colliders()` →
`via.physics.Colliders.getColliders(i)` → `Collidable.get_UserData()` (the `Chest` one when
there is one), else the template of that kind; without one the hit is not run (a kill uses
`HitPoint.dead()`). A pre-hook on `RagdollUnit.onDamageHit` skips any hit that still lacks
either (the original would crash; it only adds force).

**Enemies that never spawned.** Erasing an enemy already dead in the partner's world (§3.8)
used `CharacterContext.eliminate()`: that marks the character's backup eliminated for good -
the save keeps it - so after the host reloaded a checkpoint (its enemies alive again), or in
any later session on a save written meanwhile (two copies of the game on one PC share their
saves), those enemies never spawned again. Erasing now only invalidates the spawn param
(`invalidateSpawn(true)`), and the client makes it valid again (`invalidateSpawn(false)`) when
the host's world has the enemy alive again (its checkpoint reload, or its state stream).

**Diagnosis.** Two copies of the game on one PC share `reframework/data`: the copy that
survived overwrote the crashed one's breadcrumbs. While in a session each copy now writes its
own (`re4coop_breadcrumb_host.json`, `re4coop_breadcrumb_client.json`, same for the profiler).

### 3.14 Finishers on an enemy the partner's game runs (0.9.1)

**Report.** Player 1 grabbed and killed an enemy that had just appeared; in player 2's game it
was still alive, chased player 2, and died suddenly a while later.

**Cause.** With shared authority (§3.10) that enemy was run by player 2's game (it was chasing
player 2); player 1's game showed a puppet - AI head off (`GameObject.UpdateSelf(false)` on the
head), animation driver off. RE4's finishers are not hits:

- The player's `PlayerBehaviorTreeAction_MFSM_RequestFatal.onStart` (0x142c881b0; also
  `RequestFatalAO`) calls `PlayerHeadUpdater.requestFatal` (0x141d65b70, stealth kill / grab),
  `requestKnifeFatal` (0x141d66c00) or `requestStompFatal` (0x141d68730). Those are their only
  callers (plus `Ch3a8z0HeadUpdater.requestKnifeFatalAO`).
- `requestFatal` takes the target from the player's `PlayerTargetSelector`
  (`<LockonTarget>k__BackingField` +0x40, a `CharacterContext`; `_TargetType` +0x74 picks the
  kind) and hands the request to the target's AI head: `CharacterContext._HeadUpdater` (+0x250),
  virtual +0x5c8 (attacker, kind).
- The enemy's behaviour tree then plays it out (`EnemyBehaviorTreeAction_StealthKill`, types
  Stealth / Fatal, ending in `..._SelfDead` for the villagers) - in the game that updates that
  head.

On a puppet that head does not update: the request waited while the owner's game ran the
enemy on, and only when the enemy changed hands (player 1 now clearly closer, after the hold
time) did player 1's game run it - and the finisher's death was announced late.

**Fix.** A pre-hook on the three `PlayerHeadUpdater` requests reads `get_TargetSelectorDriver()
.get_LockonTarget()`. If enemy sync may give that enemy to our game (shared authority, or we
are the host), the puppet's head and animation driver go back on right there, before the
request reaches the head, and enemy_net takes the enemy over: the host at once, the client
with ENEMY_CLAIM (its game runs it from that moment; the host hands it over and keeps it with
the client). The enemy stays with the player doing the finisher for 10 s whoever is closer; if
both players start one, the host's wins. A death while the client's claim is unanswered is the
client's to announce. The partner's game shows the finisher on its puppet.

### 3.15 Joining from the title screen, and saves for both (0.9.1)

**Request.** A client joining a host who is already playing, from the title screen or the main
menu, had to pick *Load Game* or *New Game* itself (the mod only redirected whatever save was
loaded next into the host's chapter). It should load straight into the host's game; and the
autosaves and typewriter saves should save both players at the same time.

**How the game saves** (re4.exe, functions carved with `.pdata` and decompiled):

| What | Where | Finding |
|---|---|---|
| Slots | `share.AppSaveSlot` | Main story: 0 autosave (`Campaign1001_Auto`), 1-20 the Load Game list (`GameSaveStart`..`GameSaveEnd`), up to 99 reserved (`GameSaveLimit`); 100+ Separate Ways and other modes. `SaveDataManager.isAutoSaveDataIndex` = slot 0 or 100 |
| Every save | `chainsaw.SaveFlowController.start(Int32, SaveLoadRequestArgs)` (0x14363a5c0) | Its callers: `AutoSaveSetting.triggerProcess` (0x1436477b0, the autosave points: it records the checkpoint, then starts slot 0 or 100 with a new `ChainsawGameSaveRequestArgs`, after `SaveDataManager.setPlayLoadData(false)`), `GameStateInGameChapterChange.startAutoSave` (chapter end), `SaveLoadMenuGuiBehavior.lateUpdateOnActive` (the typewriter, the chosen slot) and the autosave error retry. `share.SaveDataManager.requestStartSaveGameDataFlow` (0x140ab6c60) is a jump to it. It checks the args are a `GameSaveRequestArgs`, queues the request; `onUpdate` (0x143612110) then writes the slot (`enqueueSaveRequest`), builds the slot's `SaveSlotInfo` (chapter, stage, difficulty, purpose...) into `SaveLoadMenuGuiManager` (`addSaveSlotInfo`) and writes the system save. Slot 0/100 only: `IsAutoSaveFlow` and `GuiManager._ContineCount` - 1 |
| Can save | `SaveDataManager.get_IsBusy` (0x142fa0a50), `checkExcludeGameSave` (0x140ac26b0 -> `isExcludeGameSave` 0x142faa4a0) | Busy unless idle with an empty queue; excluded while quitting or while any registered exclusion delegate says so |
| Continue | `SaveLoadMenuGuiManager.findContinueSave()` (0x141770390) | The newest file (`getSaveFileDetailList` timestamps) of slots 0-20, as a `gui.SaveSlotInfoDetail` (`IsEmpty` +0x10, `Info` +0x18: `SlotIndex` +0x10, `ChapterID`, `Stage` +0x18...). `getSaveSlotInfoDetail(Int32)` (0x141782c90) builds the same for any slot. The main menu's Continue (`GameStateMainMenu` phases 47-56: CheckGameClearData -> StartLoadLatestsave: `setPlayLoadData(slot == 0, slot)` + `enqueueLoadRequest(slot)` -> EndLoadLatestsave -> Decided) and the game-over Continue (`GameStateGameOver.update`) both load it |
| Menus | `GameStateMainMenu.onDecidedStoryMenu` (0x141b5c350) | Story menu: Continue (0) -> phase 47; Load Game (1) -> the load screen (37); New Game -> difficulty select |
| Game intent | `chainsaw.UDSManagerApp` `<RequestGameIntentMode>` +0x10 (MainGame 0), `<_IsRequestGameIntent>` +0x15 | The console "activity" start. With the request on: `GameStateTitle.update` (0x141da2c30) -> `skipStateGameIntent` (0x141d870c0): straight to the main menu state; `GameStateMainMenu.update` (0x141bc2070) / `updateRequestGameIntent` -> `onGameIntentEnterInMainMenu` (0x141b625e0) from any phase but the loading ones: phase 47 (Continue) with the story choice Continue. Decided then does not wait for the menu windows to close, marks the in-game setup `StartFromGameIntent` (it shows the extra-contents notice the story menu would have) and calls `resetRequestGameIntent` (0x142a4c630). A failed load (phases 52-54) goes to GameIntentWait and also resets it |

**Joining from the menus.** A pre-hook on both menu states' `update` asks the session every
frame; when the client is joining a host who is in game, the mod turns the game intent on once
(`set_RequestGameIntentMode(0)`, `set__IsRequestGameIntent(true)`) and arms the chapter switch
(§3.6). The menus run Continue on their own; a post-hook on `findContinueSave` returns
`getSaveSlotInfoDetail(co-op slot)` instead while that load runs, if that slot holds a save,
so the client loads its own progress with the host, not the newest file (two copies of the game
on one PC share their saves). `loadGameSaveData` then goes into the host's chapter, and the join
goes on as before (world state, warp). No save at all: the player is told to start one.

**Saving for both.** A pre-hook on `SaveFlowController.start` reports every save our game
starts (SAVE). The partner's game then saves the way an autosave point does
(`setPlayLoadData(false)`, `requestStartSaveGameDataFlow(slot, new ChainsawGameSaveRequestArgs)`):
the host into slot 0, the client into its co-op slot (setting, default 20: a list slot, so it
shows in Load Game and the game describes it). While connected, the client's own autosaves are
redirected there in the same pre-hook (`args[3]`): its single-player autosave is kept, and two
copies on one PC never write the same file at once; a typewriter save of the client goes where
it chose and is then copied to the co-op slot. A save within 10 s of our own counts as the same
one (both walked through the same autosave point; both changed chapter). A save waits until our
game can save (playing, no cutscene or loading, not dying, `IsBusy` and `checkExcludeGameSave`
false; a client also holds the host's world) for up to 90 s. Saves made for the partner are
never reported back. After a game over, a connected client whose co-op slot holds this
session's progress gets that slot from `findContinueSave` too.

**Limits.** A save made for the partner keeps our own last checkpoint (the restart point is set
by the autosave trigger, not by the save): loading it restarts there, and joining puts the
client next to the host. A redirected autosave skips the slot-0-only `_ContineCount` decrement
and shows the manual-save icon. Not run in the game yet.

### 3.16 The crash after a partner's killing hit, and enemies that ran their own AI (0.9.1)

**Report.** The client's game (a session over a VPN) crashed: `c0000005` at re4.exe+0x326e37f.
The breadcrumbs ended 50 ms before it, with no hit step.

**Stack** (minidump `re4.exe.22596.dmp`, read with a small parser: exception thread, ASLR
base from the module list, return addresses on the stack named from `.pdata` and the dump):
REFramework (dinput8.dll, our Lua) -> `HitController.callbackDamageHit` ->
`Ch1c0BodyHitDriverCommon.onHitDamage` -> `Ch1c0z0HeadUpdater.onHitDamage` ->
`EnemyHeadUpdater.onHitDamage` -> `Ch1c0HeadUpdaterCommon.onDead` -> `onPartsBreak` ->
`Ch1c0BodyUpdaterCommon.requestPartsBreak` -> `triggerPartsBreakEffect` ->
`EPVStandard.requestEffect` -> `EffectManager.createEffectAutoDestroy` ->
`WindManager.attachWindSettingEffect(AfterCreateEffectInfo)` (0x14326e050). It walks the new
effect's `Transform.get_Children()`; the enumerator (`r14`) had a zero header when its
`MoveNext` was called: freed memory. Every object of that call (`0x123dbdc11b0`, `…5fb0`,
`…ba30`, `…bae0`, `…c470`) sat side by side in the engine's per-thread heap of short-lived
objects.

**Cause.** The killing hit was ours (a partner's kill run here, §3.13). First suspect: the
`DamageInfo` made with `sdk.create_instance` had no engine reference (REFramework counts such a
new object only on the Lua side - `detail::add_ref`: a reference count <= 0 is a "local"
object - and its documentation asks for `add_ref()` on what `create_instance` returns). That
was fixed (below), but the client crashed twice more at the same address, each time when the
host killed a villager: the breadcrumbs, now written in time, end with `enemy.ai restore` and
`enemy.kill` (`Ch1c0z0Context`), and the second stack shows the way in:
`Ch1c0HeadUpdaterCommon.onDead` -> `lotteryBreakHead` (0x14197b0b0, the head-burst draw of a
death) -> `onPartsBreak` -> `requestPartsBreak` -> the break effect. Why the break effect of a
replayed killing hit leaves the effect's children list freed is not known (the copy had been a
puppet until that frame; the heap is not in the minidump). Separately, REFramework's log showed
`System.InvalidOperationException` in `via.GameObject.get_Transform` several times in the two
minutes before: `Game:go_alive` asked destroyed GameObjects (broken crates, animals) for their
transform, and the game threw.

**Fix.**
- No mutilation from a hit we run (the partner's hits and the killing hit of a death the
  partner's game decided): while `Game.replaying`, pre-hooks skip
  `Ch1c0HeadUpdaterCommon.lotteryBreakHead` (answers false), `Ch1c0HeadUpdaterCommon.onPartsBreak`,
  `Ch1c0BodyUpdaterCommon.requestPartsBreak`, `EnemyHeadUpdater.onPartsBreak`,
  `CharacterBodyUpdater.onPartsBreak` and `Ch1d4z0Head/BodyUpdater.onPartsBreak` - each with
  code of its own (`CharacterHeadUpdater.onPartsBreak` is 0x1400ae850, the empty method of
  ~60,000 methods, and is never hooked). The hit still makes its reaction and the death. Our own
  player's hits mutilate as always; in the partner's game a puppet stays whole. *Experimental →*
  `enemy_replay_mutilation` brings it back.
- `Game:hold(obj, seconds)`: `add_ref()` (an engine reference, dropped again by REFramework
  once Lua lets go of the object) and keep it for a while: the hit's DamageInfo (5 s), the
  save request (120 s), the warp's StageIdentifier and the game-over request.
- `Game:go_alive` reads liveness from memory: the GameObject's transform pointer (offset found
  once on the player's body, +0x18 expected) and the transform's owner pointer (+0x10, cleared
  when destroyed). `transform_of` and the animal lookup ask a GameObject for its transform only
  when it is alive. Without a matching layout it falls back to `get_Transform`.
- Breadcrumbs: `enemy.apply_hit` and `enemy.kill` are written even right after another write
  (`"now"`), so a crash in a hit always leaves its step.
- Enemy sync: a puppet the game adapter switched back on by itself (a finisher, a head the game
  linked again) is switched off again on the next control pass (`enemy_is_puppet`), instead of
  running its own AI in both games.

### 3.17 Attack data the game had freed (0.9.1)

**Report.** A crash at 16:35:46 on one of the engine's own worker threads (re4.exe+0x39e73be,
inside the runtime's object code, no game method in the stack; REFramework wrote
`reframework_crash.dmp`). Five minutes earlier REFramework's log had caught an access
violation (`VMContext: Caught exception code c0000005`) inside our call to
`chainsaw.collision.HitInfo.set_DamageUserData`.

**Cause.** That setter (0x1400b7a90, the shared setter of a field at +0x70) adds a reference to
the new value (0x1439d6ed0) before storing it: the value was a freed object, so the add wrote
into memory the engine had given to something else - the later crash in its own threads is the
likely consequence. The value came from `hit_templates`: data kept (with `add_ref`) from an
earlier hit of our player - the weapon's AttackUserData / AttackData and, per enemy kind, the
DamageUserData - used for every hit we run. They belong to resources (the weapon's, the enemy
kind's) that the game frees when it unloads them, whatever references we hold.

**Fix.**
- The damage data of a hit we run comes only from the enemy's own colliders, read at that
  moment; the per-kind cache is gone. No damage data: no hit is built (the HP and the death go
  through the fallbacks).
- Attack data templates record their types; before each use `still_valid` checks that the
  object is still a managed object (`sdk.is_managed_object`) of that type, and drops the
  template if not (the latest template and any other weapon's are tried next; our player's next
  hit gives fresh ones). The enemy's collider data is checked the same way.
- Kept objects are never let go of (`refs` only grows): releasing one the game freed would be
  another write into freed memory.

### 3.18 Traps (0.9.1)

**Request.** Every kind of trap in sync.

**The traps of the game** (types from the dump; behaviour from re4.exe, carved and decompiled):

| Trap | Type | How it works | In co-op |
|---|---|---|---|
| Bear trap | `chainsaw.GmLegHoldTrap` (`GmOMUnitBase`) | `_Routine` +0x90 / `_Rno` +0x94: Wait 0, Bite 1, Close 2, Closed 3, Hide 4, NpcBite 5, Rescue 6, OpenByEm 7. `initializeGimmick` (0x14196c4c0) starts it Closed when its gimmick flag is set. `onHitDamage` (0x141997070): open + enough break power -> Close (writes routine 2 / rno 0). `updateGimmick` (0x141a13450) Close: snap motion, sound, `setGmFlag(true)`, then Closed; Bite (0x141a0a270) holds the victim and ends in Closed **without** the flag. `requestSetClosed()` (0x140783760): Closed + flag. `requestOpenByEm()` (0x1407844c0): flag off, OpenByEm -> Wait. `onChangeGmFlag` only sends a notice | Synced |
| Villagers' bear traps | the same `GmLegHoldTrap`s, pooled | `Ch1c0z0LegHoldTrapManager` / `CustomLevel_Ch1c0z0LegHoldTrapConveyor`: a list of level trap ContextIDs (`TrapContextID`) reserved (`requestGetLegHoldTrapID`, `useLegHoldTrap`, `notifyTrapUse`); the villager carries an `EmShellLegHoldTrapDummy` (a rigid body, `setDrop`) | Closing/re-arming synced (level GUIDs); the placement is not |
| Sensor bomb (laser trip mine) | `chainsaw.GmSensorBomb` | `_Routine`: Wait 0, Bomb 1, ReleaseReady 2, Release 3, Done 4, Hide 5. `initializeGimmick` (0x1424ed450) starts it Done when flagged. `onHitDamage` (0x1425034a0) sets the flag; Wait (0x14255b050) turns a set flag into Bomb (explosion attack, sound, effect: 0x1425499f0) | Synced |
| Spike wall, drills, falling floors, laser rooms, ice axes, the trapped dog | `GmWallTrap`, `GmDrillTrap(_cp11)`, `GmFallingFloorTrap(2)`, `GmCountDownFallingFloor`, `GmAbyssFallingFloor`, `GmLaserTrap`, `GmQTELaserTrap(2/3)`, `GmIceAxeTrapControll`, `GmDogCaughtInTrap` | Started by the level's own triggers and scripted sequences (`initInteractTrigger`, `GmOption*` from portrayals); several set their gimmick flag at the end (`GmWallTrap.updateGimmick`, `GmLaserTrap.onActivate`/`onInActivate`, `GmCountDownFallingFloor.onEnd`...) | Each player's own game runs them when its player walks in; their saved state crosses through the gimmick table (§3.11) |

`GmBase.setGmFlag(Boolean, InteractTrigger, InteractActionArgs)` (0x141602d40) is the gimmick
flag of every gimmick: when the value changes it writes attribute 0 of the GimmickContext
(`pushAttr`) and calls the virtual `onChangeGmFlag` (557 call sites).

**Design.** Each game watches the traps within 60 m of its player (scene components by
GameObject GUID, rescanned every 2 s; `_Routine` read 5 times a second) and reports a bear trap
that closed (open -> any of Bite/Close/Closed/NpcBite/Rescue) or opened again, and a sensor
bomb that went off (armed -> Bomb/Done) - TRAPS. The partner's game applies it through the
trap's own code: a bear trap gets Close with `_Rno` 0 - exactly what a shot writes, so it
snaps with its sound and saves its flag; re-armed: `requestOpenByEm()`; a sensor bomb gets
`setGmFlag(true)` and goes off from its own Wait on the next update. A trap not loaded there
waits for its area (30 min); a report older than 20 s, and the snapshot of every closed or
gone trap a joining partner gets, are applied without playing them (`requestSetClosed()`;
the bomb straight to Done, then flagged). What the partner's report makes our trap do is not
reported back. Paired by GameObject GUID (scene data).

**Not covered yet.** The villagers' trap placement (the pooled trap is moved and shown in the
villager's owner game only); the scripted traps beyond their saved state. Not run in the game
yet.

### 3.19 Mechanisms: levers, big doors, valves, shelves, carts (0.9.1)

**Request.** Objects that move with an in-game camera shot in sync: big doors that open with a
short scene, a lever that opens a big door, the cart pushed out of the way, the shelf moved to
reach the next area, the chapter 2 valve that opens the door to Leon's equipment, and every
similar object.

**Before.** Only their saved state crossed (gimmick table, §3.11): the partner's game knew the
lever was pulled, but an object already loaded on the partner's screen kept its old pose until
its area loaded again - the door stayed shut, the shelf and the cart stayed in the way.

**How the game moves them** (re4.exe, carved and decompiled with REA):

* `chainsaw.PortrayalSettings.call(UInt32 keyhash, InteractTrigger, InteractActionArgs)`
  (0x142158ad0) is the scripted-sequence engine of a gimmick: it runs the parameter sets with
  that key (`_CalleePlay`: motions, the in-game camera, sounds, effects, other gimmicks' options,
  flags). Both other overloads, `call(String, InteractTrigger, InteractActionArgs)`
  (0x1409e48c0) and `call(String key, GameObject)` (0x1409e7ed0), hash the key and end in it.
  The game calls it with no trigger and no args itself: `GmLever.onUsed` (0x14396b630) and
  `GmLever.setUsed` (0x143986170) do `setGmFlag(true)`, then `call(key, null, null)`.
* `initializeGimmick` of a gimmick that loads already used calls
  `PortrayalSettings.makeFinish(key)` (`GmLever.initializeGimmick` 0x14393f570): the sequence's
  end pose without playing it. This is what a partner far away gets when the area loads.
* 263 gimmick types own a `PortrayalSettings`: `GmLever`, `GmLeverKeep`, `GmPowerSupplyLever`,
  `GmBigDoor`, `GmBigDoorLock`/`Padlock`, `GmHoldHandle` (the valves and cranks), `GmShelves`,
  `GmFallenShelf`, `GmStandFallenShelf`, `GmSlideGate`, `GmDrawbridge`,
  `GmCorrelatedShutterBase`, `GmWindmill`, `GmBrokenGate`... Some play it from their flag:
  `GmShelves.onChangeGmFlag` (0x1435fd3b0), `GmPortrayal.onChangeGmFlag` (0x1408b24d0).
  `GmLever.onGimmickOccupiedExcludeAcceptCh` (0x143957f90) keeps the partner's own player off
  a lever while it is in use.
* The pushed cart and shelf are `chainsaw.GmPushMove`, which has no portrayal: its gimmick flag
  is `IsMoved`. `onAcceptExecute` (0x141fa4af0), once the push is accepted:
  `setGmMotion(MotMove)` (0x142020be0), `moveEffectorShape(_Move)` (moves the AI map
  blocker along), `setGmFlag(true)`. `initializeGimmick` (0x141f97690), when flagged:
  `setGmMotion(MotMoved)` and the blocker moved. Its camera shot is a Clapperboard
  (PayloadPlay), which the cutscene sync already plays for both (§3.11).
* `PlMinorDemoSettings` in a sequence only turns the player toward the object; no player
  needed.

**Design.** Two hooks, both only recording. `PortrayalSettings.call(UInt32, ...)` records the
gimmick's GameObject GUID and the key; `GmBase.setGmFlag(true)` on a `GmPushMove` not moved yet
records a push. Each frame they become MECHANISMS (a sequence our game started while our area
was loading is the area setting itself up and is not sent). A portrayal is shared only when
its GameObject (or its parent) has a gimmick that is not deny-listed - doors, traps,
breakables and animals have their own sync; ladders, windows, jumps, item boxes, the
workbench, saving, mounted guns and vehicles are the player's own action - and its parameter
sets run nothing deny-listed; a portrayal with no gimmick is an event, which the level event sync handles (§3.11). The
partner's game plays the same sequence on the same object, the game's own way:
`call(key, null, null)` like `GmLever.onUsed`; a push gets what `onAcceptExecute` does without
the player (`MotMove`, the blocker, the flag). Never twice: for 15 s a sequence the partner's
report started is not reported back, and the same sequence our game starts itself (its own
reaction to the flag gimmick_sync brought) is skipped (`SKIP_ORIGINAL`); a partner's report
of a sequence our game started in the last 15 s is not played. An object not loaded waits 10 s
for its area, then its saved state finishes it when the area loads (`makeFinish`). Paired by
GameObject GUID (scene data).

**Not covered yet.** Not run in the game yet. The flag of a lever arrives with the gimmick
table (every few seconds), not with the sequence.

### 3.20 Enemies that walked on dead, and weak reactions to the partner's shots (0.9.1)

**Report.** An enemy one player killed sometimes kept walking (doing nothing) on the other
screen and only died seconds later, both ways; a death should cut whatever the enemy was
doing; enemies reacted weakly to the partner's shots and misbehaved when both players shot.

**How the game reacts to a hit and dies** (re4.exe, carved and decompiled with REA):

* `HitController.callbackDamageHit(DamageInfo)` (0x141f31970) plays the damage sound and
  effect, then calls the character's registered damage callback.
* `CharacterHeadUpdater.onHitDamage(DamageInfo)` (0x141202de0): `HitPoint.addDamage(Damage)`;
  the body part's own HitPoint (`DamageUserData.Parts` +0xa8 / `PartsSide` +0xac) takes the
  `Break` value and may break (`onPartsBreak`); then **only a hit with `IsKill` (+0xcd) set
  starts the death** (virtual `onDead`); any other hit gets a damage reaction - even one that
  took the last HP.
* `HitPoint.checkDead(damage)` (0x143408bc0): false while NoDamage, Immortal or NoDeath, or
  already dead; else `HP - damage <= 0`. `HitController.checkKill(damage)` (0x141f3ab30) asks it.
  `HitPoint.dead()` (0x14028f870) only writes HP 0: no death. `get_IsLive` is `HP > 0`.
* The reaction comes from the hit's **AttackData**: `getDamageAction` (0x1411ba810) /
  `EnemyHeadUpdater.findDamageReaction` (0x1413aa640) read `_AttackType` (+0x34),
  `_AttackPower` (+0x38) and `_Option` (+0x48, bit 8: no reaction) and look the reaction up in
  the character's table. `AttackData.doDeepCopy(src)` (0x141cf4250) copies every value and
  reference of `src` into the instance.
* `onDead` (`CharacterHeadUpdater` 0x1411f61d0, `EnemyHeadUpdater` 0x1413e6f90, villagers
  `Ch1c0HeadUpdaterCommon` 0x14198ad10) requests the death action, which replaces whatever the
  enemy was doing. `CharacterHeadUpdater.entryDeadAction()` (0x1411a5f60) requests the death
  action of the action table; many enemies' `onDead` call it (dogs, Ch1d2/Ch1d4/Ch1f*...).

**What went wrong.**
1. A partner's hit was run with the `IsKill` the shooter's game had computed against its own
   copy's HP. When the copies' HP differed (two players shooting, a hit in flight), a hit that
   took the owner's last HP arrived unmarked: a damage reaction at 0 HP - the enemy walked on
   until its AI noticed, seconds later, while the other game, told of the death at once,
   already showed it dead. A marked hit that did not kill here played a death with HP left.
2. A death applied without a buildable hit fell back to `HitPoint.dead()`: HP 0 and no death.
3. Every replayed hit carried our own weapon's AttackData (or any weapon's, before our player
   had used that one) and landed on the chest collider: a shotgun blast replayed as a pistol
   flinch, head and leg shots lost their stagger and kneel.
4. With both players shooting, the last shooter's 4 m advantage moved the enemy from game to
   game, and every change of hands cut its reaction short.

**Fix.**
1. The game that runs the hit decides the kill: `IsKill = HitController.checkKill(Damage)`
   (else `HitPoint.checkDead`) before `callbackDamageHit`.
2. A death always runs as a killing hit when one can be built (without the partner's values: a
   plain one at the chest, pushing the enemy back), with attack data from our player's hits or,
   before that, another character's; only without any, `HitPoint.dead()` +
   `entryDeadAction()`.
3. A hit carries the primitive values of its AttackData (31, by reflection, hashed as
   `AttackData.<name>`) and its body part and side (`DamageUserData.Parts/PartsSide`). The owner
   runs it with a copy of its template's AttackData (`doDeepCopy`) carrying the shooter's
   values (one copy per kind of attack, kept with its template) on the enemy's collider of the
   same part and side (else the chest).
4. While both players hit the enemy within 3 s it stays with its owner (unless a player goes
   out of range, down, or starts a finisher). The owner sends its state as soon as it ran a
   partner's hit, and for 1.5 s after its own hit the shooter's puppet plays the owner's newest
   animation instead of the interpolated one (its position keeps the smooth track).

### 3.21 Host enemies the client's game never spawned (0.9.1)

**Report.** The host could have enemies the client did not see - most of all when the client
loaded a save in which those enemies had died: the host saw them, the client did not until new
enemies spawned.

**How the game decides a level enemy exists** (re4.exe, carved and decompiled with REA):

* `CharacterSpawnParam.StatusFlag` (+0x58): Permitted 1, Readied 2, Activated 4, Invalidated 8.
  `permitSpawn`/`readySpawn`/`activateSpawn`/`invalidateSpawn(bool)` (0x142513710 / 0x142514420 /
  0x1424a6cf0 / 0x1424edb70) set or clear one bit and call `updateSpawn` (0x142559670), which
  creates the body and head (`requestCreateBody/Head`, `CharacterLinkCoordinator.requestSpawn`)
  when the flags are exactly Permitted|Readied|Activated without Invalidated, and destroys them
  otherwise.
* `onUpdate` (0x14250ffa0) sets Activated from `isNextSpawn` (0x1424f0410): false when
  Invalidated or not Permitted; it reads the character's live context
  (`CharacterManager.getContextRef`: `IsEliminated` +0x5a) or else its save backup
  (`getBackupData`: `CharacterBackup._IsEliminated` +0x48) and **if it is eliminated it
  invalidates the spawn param for good**; then the stage must be active (and Readied/addRef on
  the way).
* Permitted is given by the level: `CharacterSpawnPointController.permitSpawn` (waves) and five
  other callers (area and event logic).
* `CharacterManager.CharacterSpawnParamDB` (+0x68, `Dictionary<UInt32, CharacterSpawnParam>`,
  read-locked by `getSpawnParamRef(ContextID)` 0x14343a000: `TryGetValue(ContextID.Code)`) and
  `CharacterBackupDB` (+0x88, `ConcurrentDictionary<UInt32, CharacterBackup>`, with
  `ContainsKey`, `get_Item` and `IDictionary<TKey,TValue>.Remove(UInt32)`) are keyed by the
  ContextID code - our enemy uid. `ContextID(UInt32 code)` builds the key object.

So a save in which the client killed an enemy keeps that enemy from ever spawning in the
client's game, and an enemy whose spawn only the host's player triggered is never permitted
in the client's.

**Design.** The host's world decides which enemies exist. The client watches the host's
enemies it receives (ENEMY_STATE): a level enemy (uid) the host runs, alive, within 80 m of the
client's player, that the client's game has neither alive nor as a corpse and that did not die
in the client's game in the last 15 s, and that is still missing after 1.5 s, is spawned:
its save backup is removed if it says the enemy died (the enemy comes back as the level places
it; the save no longer holds it dead), an invalidated spawn param is validated again and an
unpermitted one permitted (`invalidateSpawn(false)`, `permitSpawn(true)`); the game's own update
spawns it. When it shows up it pairs by uid, is moved to where the host's enemy is, and from
then on is one enemy run by one game like any other. A spawn param that is not loaded (another
area) only gets the save's death forgotten, so it spawns when its area loads. Not while the
client's area loads or the host is in another region; at most 4 tries per tick, one every 3 s
per enemy. *Diagnostics*: `enemy_revive`; the *enemies* counters `spawn_spawning`,
`spawn_forgotten`, `spawn_missing`, `spawn_dead_here`, `revived`. Setting `enemy_spawn_missing`.

**Not covered.** Enemies the host's game created at runtime (no uid: summoned, scripted
additions) are still only seen where they spawned. A wave controller on the client may count
an enemy it did not choose itself. Not run in the game yet.

### 3.22 Scoped weapons on the partner's model (0.9.1)

**Report.** When a player bought or carried a scoped weapon, the partner's game showed the
scope's view: the weapon copy on the partner's model rendered through its scope.

**Why.** A scoped weapon's prefab carries `chainsaw.ScopeController` (dump: `_CameraRef` and
`_WeaknessCameraRef` `via.Camera`, `_WeaknessCameraGameObject` `via.GameObjectRef`,
`_RenderOutputRef` `via.render.RenderOutput`, `_CustomFilterRef`, `_DepthOfField`,
`_LDRPostProcess`, `_ToneMapping`, `_VolumetricFog`, `_ScopeRTT`): the scope's own camera with
its render output and post effects. The model's sanitizing switched off every `chainsaw.`
component - the controller - but left the engine's camera and render output running, and only
looked three levels deep.

**Fix.** Sanitizing a spawned copy now also switches off every `via.render.RenderOutput`, and
every component of any GameObject that holds a `via.Camera` (which then stops updating),
through the whole weapon prefab (8 levels), plus the cameras a ScopeController references
(`_WeaknessCameraGameObject`, and `_CameraRef`/`_WeaknessCameraRef` once set). The meshes - the
rifle and its scope - stay drawn. *Diagnostics*: `puppet_cameras`. Not run in the game yet.

### 3.23 One Ashley for both players (0.9.1)

**Request.** Only one Ashley in the shared world, with the host at first; a tap of Alt sends
her to the other player (she follows them from then on), at most once every 5 s.

**How the game runs Ashley** (re4.exe, carved functions decompiled with REA):

* She is `CharacterKindID.ch2_a1z0` = 200030 (the enum's literal values;
  `PartnerBattleParamUserData.Ch2a3z0IAParam.GivingAmmoLimit` marks ch2_a3z0 as Luis).
  `CharacterManager.getPartnerContextRef` (0x1434306b0) returns the first entry of
  `PartnerContextList` (+0x98) - or, in one game mode with several partners, the one of kind
  200032 - so the mod walks `PartnerContextList` and picks kind 200030.
* Her context is a `PartnerBaseContext`: `IsKidnapped` +0x460, `IsPermitKidnapped` +0x470,
  `IsPermitAttacked` +0x471, `_ThinkEnable` +0x430, `_PartnerState` +0x440 (`Npc.State` bits:
  Down 1, Rescue 2^17, HidingLocker 2^54, UseGmHandle 2^57...).
* Her AI is her head: `Ch2a1z0HeadUpdater` (a `PartnerHeadUpdater`).
  `updateFollowTargetPosition` (0x1420642f0) takes the first context of CharacterManager's
  player list (+0x90) and puts the follow target next to it. There is no general "far away"
  warp: `IntelligentActionLeavePlayer` only steps away from a player who crowds her.
* `PartnerNpcActionUpdaterUnit.updateKidnapped` (0x14108c470), part of her head, writes
  `IsPermitKidnapped = _ThinkEnable` (or false during some states) **every frame**. A scan of
  every byte write to +0x470 in `.text` found only it, `PartnerMoveTargetGimmick.onUpdate` and
  `requestGimmick` among the partner's code. With her head off, nothing sets it again.
* Enemies take her through `Ch1c0NPCTargetDriver_Ch2a1z0`: `startTarget` (0x14253f4d0)
  gets the partner, checks kind 200030 and **only goes on while `IsPermitKidnapped` is set**;
  `searchTargetContext` and `isExistPartnerNPC` use the same lookup.
  `EnemyBehaviorTreeCondition_MFSM_CheckCautionAshleyKidnap` reads `IsCautionKidnap` (+0x479).
* `CharacterContext.setTransform(vec3, Quaternion)` (0x1421f2ef0) stores the transform in the
  context (+0x60/+0x70) and calls every listener of its change list (+0x230): the game's own
  character teleport.
* `HitPoint.NoDamage` (+0x19, `set_NoDamage`) makes `checkDead` false and the damage none.
* Keyboard: Alt is RE4's default "zoom" key for scopes (Ctrl commands Ashley), per a controls
  guide ([ProGameTalk](https://progametalk.com/resident-evil-4-remake/controls-key-bindings/)).

**Design** (`ashley_sync.lua`, `game_ashley.lua`). Each game has its own Ashley; exactly one
game runs her, the owner (the host's at first). The owner's Ashley is the game's own and
follows the owner's player; it sends her state ~20 Hz (ASHLEY: position, rotation, HP, three
animation layers). In the other game she is a **puppet** like an enemy the partner runs:
head `set_UpdateSelf(false)`, `via.motion.MotionFsm2` off, `IsPermitKidnapped` and
`IsPermitAttacked` cleared (re-asserted every tick), `NoDamage` on (its old value kept); her
transform (+ `CharacterController.warp`) and motion layers follow the owner's, interpolated, and
her HP too (never below 1: the owner decides whether she goes down). A tap of the key
(press and release within 1 s, no Tab/Enter/F4/Esc meanwhile, not while aiming: Alt zooms;
REFramework records Alt from `WM_SYSKEYDOWN` as `VK_MENU` but clears every key on
`WM_KILLFOCUS`, so an Alt+Tab looks like a tap: the game window must still be the foreground
window 0.25 s after the release - `re4coop_net.window_focused`, `GetForegroundWindow`)
asks for a switch: the host switches (epoch + 1) or refuses - cooldown (5 s, the host's
setting), she is busy (kidnapped, down, hiding, on a gimmick, grappled), the other game has no
Ashley or its player is in a cutscene, down or loading; a client's request about an old epoch
is answered with the current owner, so two presses at once switch once. Whoever stops running
her puts her head and animation back (her permissions come back from her head's next update);
whoever takes her over more than 20 m from its player brings her 1.5 m behind the player with
`setTransform`. If the game running her has had no Ashley for 5 s while in game (a part of the
story without her) and the other has one, she goes over by herself. *Diagnostics*: `ashley`,
`ashley_puppet`, `ashley_warp`; counters `switches`, `refused`, `stale`, `warps`, `auto`.

**Not covered.** In the game that does not run her she cannot be hurt by that game (not even by
its player's stray shots), and doors or jumps that need her nearby only work for her player.
Scripted moments that move her (cutscenes, `warpPartner`) happen in each game; the owner's
state takes over again afterwards. Not run in the game yet.

### 3.24 What one player completes, the other completes too (0.9.1)

**Report.** Doors and the like crossed, but: a puzzle one player solved stayed unsolved for the
other; objectives did not update; after El Gigante died the host's game moved on but the client's
did not; an item placed in a slot to open a door opened it only for the player who placed it (the
other could not pass).

**What the game does** (re4.exe, carved and decompiled with REA):

* **Gimmick state vs. the object on screen.** The gimmick sync wrote the partner's record into the
  gimmick's context (`GimmickContext.loadSaveDataFromManager` 0x1411ecde0: `_SaveCur`, `_SaveBuff`,
  `onLoadedGameSave` - data only). The object already on screen reacts only to the game's own
  paths: `GmBase.setGmFlag(value, trigger, args)` (0x141602d40) writes attribute 0 and calls the
  gimmick's `onChangeGmFlag` (vtable +0xd0) - 48 gimmick types react there: `GmUseItem`,
  `GmUseItemGate`, `GmKeyHole`, `GmShutterItemInsertionPoint` (items set in slots), `GmLever`,
  `GmShelves`, `GmPortrayal`, `GmUnlockPuzzle`, `GmStonePiecePuzzle`, `GmHoneyCombPuzzle`,
  `GmClosingBoardLock`, `GmBigDoorPadlock`, `GmDoorCardKey`, `GmWindmill`... Some poll the flag
  in their update (`GmCrestPuzzleDoor.updateGimmick` 0x142066b30 opens when it turns on); others
  read it only in `initializeGimmick` (when their area loads).
* **The write blocked the game's own reaction.** `GmUseItem.updateGimmick` (0x143011520) watches
  a story flag (`_Flag`) and, when it is set, does `setGmFlag(true)` - its own reaction to the
  flag the partner's game set. But it returns at once when its gimmick flag is already on, and
  our record write had turned it on: the item never appeared and the door stayed locked.
* **Sequences that move items were never shared.** Using an item runs the slot's sequence
  (`PortrayalSettings.call`), whose parameter sets include `ReduceInventoryItemSettings` (the
  item leaves the inventory), often `InventorySettings` (a reward), `ForceGetFileSettings`... The
  mechanism sync (§3.19) refused any sequence with such an effect. Each effect runs through its
  parameter's `triggerProcess` (`PortrayalSettings.Param.triggerProcess` 0x1437f7b10 runs
  `_CalleePlay`); the end effects later, from `PortrayalSettings.update` (0x142222200) ->
  `Param.onFinish` (0x14379c580: `_CalleeEnd` with no trigger). `ReduceInventoryItemSettings`'
  `triggerProcess` and `makeFinish` are one function (0x140640ff0 -> `apply` 0x1438e64c0).
  `InventorySettings.Param.triggerProcess` (0x1407631d0) adds the item (Process 0) or opens the
  case (1); its `makeFinish` is the game's empty method (0x1400ae850) - so loading an area that
  is already done never hands anything out.
* **The game's latent network design.** `GimmickManager.PayloadGmFlag / PayloadAttr /
  PayloadAttrAll / PayloadAccessory / PayloadGmParam / PayloadDetect`, `GimmickContext.recvAttr`
  (0x1404694b0: `pushAttr`, data only), `GmBase.recvAccessory`, `recvGmParam`, and
  `share.AppSendPacketInfo` (`via.network.protocol.SendOption`): a dormant way to replicate
  gimmicks between players, in which a flag change is replayed as `setGmFlag` on the receiver.
* **Objectives.** `PurposeManager.onUpdate` (0x1428830b0) asks `GameConditionCollector` for the
  current purpose statement - conditions on story flags, **items held** (`ConditionItem.check`),
  sub-progress, chapter, HP, UI - and takes it only if its `Priority` is higher than the current
  one's (`updateMainPurpose` 0x1428e96f0: a copy of the `PurposeGuiItem`, then the objective
  banner). A key item exists once in co-op, so the player without it kept the old objective.
  `PurposeID` encodes the chapter: 2203 = ChapterID 22200's third objective.
* **El Gigante** (`Ch1f0z0HeadUpdater`): `onDead` (0x142a15090) sets a story flag
  (`requestSetFlag`), starts its death cutscene (`callTimelineEvent` -> `ClapperboardMediator
  .requestPlayWithID` 0x1419baa60) or, when it cannot yet, `RequestDieDemo` (+0x473) for
  `onLateUpdate`; the cutscene's end removes the character. In the game that runs it, it can
  leave the enemy list that way without the list ever showing it dead (HP at 0). The partner's
  copy was then *released* to its own AI - the client went on fighting a Gigante the host had
  killed.

**Design.**

* **Muting the partner's player's effects** (`game_world.lua` `install_mute_hooks`): the
  `triggerProcess` (and `makeFinish` where it does something) of every dangerous effect type -
  items given or taken, deaths, chapter/campaign processes, game modes, tutorials, files, drops
  (World.DENY_COMPONENTS) - is hooked and skipped while we replay the partner's action; a
  sequence we replayed keeps its end effects muted until it finishes (`Param.onFinish` hooked).
  The game's empty method is never hooked. An effect type that cannot be muted keeps its sequence
  from being shared. *Diagnostics*: `mute_effects`.
* **Sequences with such effects are shared now**: the item slot's sequence (the item appears,
  the lock opens) and a puzzle's solution play in the partner's game; the item is not taken from
  the partner, no reward is handed out twice. Level events too (§3.11): an event whose sequence
  kills the player runs for the partner without the death.
* **The gimmick reacts first** (`gimmick_react`): when the partner's record turns a gimmick's
  flag on and the gimmick is on our screen and set up, `setGmFlag(true)` runs on it (muted) - the
  same reaction it has in the partner's game - and then the record is written. Its sequence
  counts as played, so the partner's MECHANISMS report of it does not play it twice. Not for doors
  (door sync), traps, breakables, animals, pushed objects or the player's own actions
  (World.MECH_DENY). A gimmick not on screen gets the record, and its area's load sets it up.
  Setting `gimmick_reactions`; *Diagnostics*: "reacted live", "partner effects muted".
* **Objectives** (`purpose_sync.lua`, PURPOSE): each game reports its objective when it changes
  (and every 20 s); a game whose objective has a lower priority in the same chapter takes the
  partner's through `updateMainPurpose` - the banner shows it as when its own conditions change.
  Setting `sync_purposes`; *Diagnostics*: `purposes`, *objectives* counters.
* **Bosses that vanish dead** (`enemy_net.lua` `check_vanished_deaths`): an enemy whose death
  our game decides that leaves our list while alive is checked once: if our game has it
  eliminated (`Game:enemy_eliminated`: its live context, else its save backup in
  `CharacterBackupDB`), it died - announced like any death (before the host retires its number),
  so the partner's copy dies instead of being released. An enemy that only unloaded with its
  area is not eliminated and is released as before. *Diagnostics*: *enemies* `vanished_deaths`.

**Not covered.** Gimmicks that read their state only when their area loads (no reaction, no
polling) show the partner's change when that area loads again; the partner's progress *inside*
an unsolved puzzle (pieces moved but not solved) is not shown live. Not run in the game yet.

## 4. Sync architecture

```
 PC A (host)                                          PC B (client)
 RE4 + REFramework                                    RE4 + REFramework
 ┌────────────────────────┐   UDP 33040 (direct IP)   ┌────────────────────────┐
 │ re4coop.lua            │ ◄───────────────────────► │ re4coop.lua            │
 │  session ─ enemy_net   │   PLAYER (20 Hz, unrel.)  │  session ─ enemy_net   │
 │   items, drops, gate   │   POSE / AVATAR / ACTIONS │   items, drops, gate   │
 │   flag/gimmick/object/ │   ENEMY_STATE (20 Hz)     │   flag/gimmick/object/ │
 │   animal/cutscene/     │   ENEMY_ROSTER, ANIMALS   │   animal/cutscene/     │
 │   trigger sync, travel │   ENEMY_HIT/DEATH/OWNER   │   trigger sync, travel │
 │  game / game_world /   │   FLAGS, FLAG_WORDS,      │  game / game_world /   │
 │  game_pause (sdk)      │   GIMMICKS, OBJECTS,      │  game_pause (sdk)      │
 │  puppet (partner model)│   CUTSCENE,TRIGGER,WORLD_*│  puppet (partner model)│
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
* **Enemies: one shared set, one owner each** (§3.10).
  * Identity: every level enemy's own ContextID (its spawn param's, level data) is its **uid**
    on both machines; the host numbers its enemies for the wire and the client pairs by uid.
    Runtime enemies are paired by kind + spawn point (§3.8).
  * Authority: each enemy is run by one game, its owner - by default the game of the player it
    is closer to, so enemies attack both players; the host decides and every change bumps the
    enemy's ownership epoch. The other game's copy is a puppet (AI head and animation state
    machine off) that follows the owner's stream: position, full rotation, up to three
    animation layers, visibility, HP.
  * Hits: a hit on an enemy the partner runs is sent with every DamageInfo value and run through
    the owner's own hit code (same damage, same reaction); our game never kills a puppet.
  * Deaths: the owner announces each death with the killing hit; the other game kills its copy
    with that hit where it died. The host's **graveyard** keeps every enemy dead in its world
    (also from its save), and an enemy dead in the partner's world is killed or erased wherever
    it appears (§3.8).
  * Each player rolls their own loot from every enemy that dies in their game (§3.7).
* **Animals: the host's** (§3.9). The client's copies of the host's animals near both players
  follow them, AI off the game's update; deaths cross both ways.
* **World: event + state replication** (§3.6, §3.11): scenario flags by GUID through the
  game's own setter (on only), gimmick records by ContextID, breakables and animal deaths by
  GameObject GUID, cutscenes as the game's own PayloadPlay, level event triggers by GameObject
  GUID and name hash. Both sides can change the world (the client has to open doors
  too); the host's state is what a joining or reloading client takes over.
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

### 4.2 Known limitations (v0.9.1)

* v0.6 crashed in game; v0.7 removes the causes we found (§3.7), but has not been run in game
  yet. After a crash, `re4coop_breadcrumb.json` names the last thing the mod did.
* Most of this has not been verified in the running game yet. The riskiest assumptions are that the
  body prefab can be spawned outside the game's character spawner once its logic is disabled
  (*Build partner from meshes only* is the escape hatch), that switching an enemy's AI head off
  leaves its body and HitController working (*Enemies your partner's game runs stand and move
  where theirs are* switches puppets off), that disabling `via.motion.MotionFsm2` lets the
  written animation play (*…with their own animation state machine switched off*), that a
  DamageInfo built from the partner's values runs like a real hit (`hit_apply` in
  *Diagnostics*; without it the owner applies HP), and that the probed flag/gimmick/cutscene
  methods are the ones named in §3.6. The enemy identity, kill and erase calls of §3.8 come from
  the game's code, but have not run in the game yet either.
* Enemies the client's *own* save has eliminated but the host's world has alive cannot be
  brought back in the client's game: the host fights them alone (the client sees nothing
  there). Joining with an older save than the host avoids it.
* After a host checkpoint reload the host's enemies come back; enemies the client already
  removed stay gone in the client's game.
* The partner's character is visual only: no collision, enemies of your game don't see it,
  bullets pass through it. Enemies attack the partner because the partner's game runs the
  enemies near them (§3.10); an enemy fighting both players at the same distance belongs to one
  game and attacks that game's player. With *Who runs enemies: host* only the host is attacked.
* Ragdolls, AI-spawned effects and grab reactions are each game's own (§3.10).
* Animal puppets rely on `GimmickManager.unregisterMove`/`registerMove` (§3.9), not yet run in
  the game; *Options → Animals near both players…* switches them off. Animals placed at runtime
  (not from the scene file) may have GUIDs that differ between the games: those run on their own.
* Sounds the engine plays without going through the reflected `trigger` methods are not
  replayed. Thrown grenades, projectiles, bullet impacts and blood happen only in the thrower's
  game.
* Cutscene and event trigger sync (§3.11) have not run in the game yet. The game members they
  use were read in re4.exe's code, not probed by name, but whether a PayloadPlay built by the
  mod and a trigger run with the partner's player behave like the game's own is unproven.
  A skip follows the partner's game's own skip rules. Events that change items, kill, save or
  switch modes never run for the partner; their flags still cross. A gimmick state the partner
  changed is applied to the gimmick's record at once; whether an object already on screen
  redraws it before its area reloads depends on that object.
* A checkpoint reload (death, Retry) happens only in that player's game.
* Joining from another chapter while playing, and following the host into the next one, need a
  save load (any save, or *Continue*); the automatic game-over reload is experimental. Joining
  from the title screen or the main menu loads on its own (§3.15); with no save at all the
  player has to start one.
* Saves for both (§3.15): a save made for the partner restarts at that game's own last
  checkpoint; a partner's save that cannot be made within 90 s is dropped.
* The partner's loot rolls are confirmed only by the research log so far: if `drop_calls`
  shows another argument layout than §3.7 describes, the *loot* line in *Diagnostics* stays at
  "waiting for the first enemy drop" and nobody gets extra loot.
* Damage dealt to an enemy before your game has observed it once (the first ~50 ms after it
  spawns) is not reported.
* Both players need the same game version, REFramework build and mod version. A protocol
  mismatch is detected and reported.

## 5. Roadmap

1. **In-game validation of v0.9.1** with the checklist in [TESTING.md](TESTING.md), enemies
   first (steps 12-14: `enemy_uid`, `enemy_puppet`, `hit_values`, `hit_apply`, `enemy_motion`,
   `enemy_erase`, `enemy_backups`), the shared world's events (flags, cutscenes, event
   triggers: `flag_hooks`, `cutscene_hooks`, `trigger_hooks`), then the profiler's
   numbers, the breadcrumb file after any crash, `drop_calls` in the research log, and the
   experimental features one at a time.
2. Enemy positions through `CharacterContext.setTransform` (the game's own character teleport)
   if the transform write proves jittery in game; root motion switched off on puppets if it
   fights the transform writes.
3. Shared checkpoints: when one player dies, both reload (RE5/RE6 style), or the other revives
   them.
4. Replicate thrown objects (grenades, eggs, bolts) and hit effects on enemies.
5. Enemies that can target both players in one game: the partner's model as a target
   (`HateController.find/addHate` on a stand-in character), so an enemy between the players can
   switch targets without changing hands.
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
