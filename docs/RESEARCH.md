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
| **Method hooks**: `sdk.hook(method, pre, post)` | Not needed in v0.1. Enemy damage is detected by polling (see §4) |
| **Application-entry callbacks**: `re.on_application_entry("LateUpdateBehavior", fn)` | Game-thread tick for networking and sync |
| **Drawing**: `re.on_frame` + `draw.world_to_screen/line/text/...` | Partner "ghost", name tag, HUD |
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
  in §4.

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
| `Context.get_BodyGameObject()` / `get_HeadGameObject()` | Confirmed | REFramework `RE4.lua` | Transform, joints, warping |
| `chainsaw.HitPoint` (`get_CurrentHitPoint`, `get_DefaultHitPoint`, `get_IsLive`, `get_HitPointRatio`, `get_CurrentDamagePoint`) | Confirmed | SRT overlay, Health Bars | HP read |
| `HitPoint.dead()`, `HitPoint.set_Invincible(bool)` | Reported by mods (method names published on Nexus, mods 6165 and 7363) | Search summaries of *True Invincible* and *RE4 Mod Menu* | Killing an enemy (probed; falls back to HP 0) |
| `HitPoint` HP setter (`set_CurrentHitPoint`, `setHitPoint`, …) or backing field | **Verified at runtime** | No public source names it. v0.1's fixed-name probe did not find a working one in game (partial damage didn't sync) | Applying synced HP. Since v0.2 candidates come from `HitPoint`'s own methods/fields and one is trusted only after reading HP back proves it wrote the value (§3.2) |
| `chainsaw.EnemyManager.notifyHitDamage(damageInfo, enemyCtx)` / `notifyDead(...)` | Confirmed | Health Bars hooks (`args[3]`, `args[4]`) | Not used in v0.1; candidate for event-driven damage sync |
| `chainsaw.GuiManager.get_IsPlayingEvent()`, `get_IsHudOff()`, `get_GuiOpenCloseData()` | Confirmed | Health Bars `gui_handler.lua` | Cutscene flag |
| `chainsaw.GameStatsManager.getKillCount()`, `InventoryManager.get_CurrPTAS()`, `InGameShopManager.get_CurrSpinelCount()`, `GameRankSystem.get_GameRank()` | Confirmed | SRT overlay | Not used yet (possible shared-stats features) |
| Chapter/area getter (`chainsaw.CampaignManager.get_CurrentChapter`, …) | **Probed** | The autosplitter reads chapter IDs by raw offset only | "You are in different chapters" warning |
| `via.GameObject.get_Transform`, `getComponent(System.Type)`, `destroy` | Confirmed (engine) | REFramework, every RE Engine mod | Transforms, components, puppet cleanup |
| `via.Transform.get_Position/set_Position/get_Rotation/set_Rotation/get_Joints/getJointByName` | Confirmed (engine) | REFramework bindings, Health Bars | Positions, ghost skeleton |
| `via.Joint.get_Name/get_Position/get_Parent` | Confirmed (engine) | Health Bars, REFramework | Ghost skeleton |
| `via.physics.CharacterController.warp()` | Engine convention (RE2/RE3/RE8 teleport mods) | Probed at call time | Teleport without physics snapping back |
| `via.Prefab` (`set_Path`, `set_Standby`, `get_Ready`, `instantiate(via.vec3)`) | Confirmed | REFramework discussion #1112 (RE4 enemy spawn). Paths are relative, e.g. `_chainsaw/appsystem/character/ch8g2z0/ch8g2z0_body.pfb` | Experimental partner puppet |
| Animation banks `_chainsaw/Animation/ch/cha0/motbank/cha0.motbank` (Leon), `cha1` (Ashley), … | Confirmed | EMV Engine RE4 resource list | Future: animated puppet |

Character IDs are not needed by the current code. `cha0` is Leon's animation/model family and
`cha1` is Ashley's. Per-character prefab paths should be read from the game files (or from
REFramework's object explorer) rather than guessed. That is why the experimental puppet takes
the path as user input.

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
| Exact enemy pairing | `chainsaw.ContextID` first, with spatial fallback | Tests with spawns 8–12 m apart, ID+kind mismatch, ID too far away |
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

### 3.1 Prior art

* **claybtv's "Multiplayer Mod"** ([Nexus 6539](https://www.nexusmods.com/residentevil42023/mods/6539),
  open beta June 2026) runs two game instances with a host and a joining partner. It syncs
  enemies, story events, doors and switches. Reported issues are lag and choppy enemies, and
  the pause/inventory menu breaking the session. The author announced a **LAN version is in
  progress**. That validates the two-instance approach this project uses. This project is an
  independent, open implementation focused on direct IP/LAN play.

## 4. Sync architecture

```
 PC A (host)                                          PC B (client)
 RE4 + REFramework                                    RE4 + REFramework
 ┌────────────────────────┐   UDP 33040 (direct IP)   ┌────────────────────────┐
 │ re4coop.lua            │ ◄───────────────────────► │ re4coop.lua            │
 │  session ─ enemy_sync  │   PLAYER (20 Hz, unrel.)  │  session ─ enemy_sync  │
 │  game.lua (sdk)        │   ENEMY_SNAPSHOT (10 Hz)  │  game.lua (sdk)        │
 │  ghost (draw)          │   ENEMY_DAMAGE/DEAD (rel.)│  ghost (draw)          │
 │ re4coop_net.dll        │   CHAT/NOTIFY/HELLO (rel.)│ re4coop_net.dll        │
 └────────────────────────┘                           └────────────────────────┘
```

* **Two full game instances.** Each player runs their own RE4 with their own Leon, camera and
  inputs. Both load the **same chapter** from a save.
* **Partner presence: the ghost.** Each side sends position, rotation, HP, flags and up to 40
  joint positions (int16 cm offsets) at 20 Hz. The receiver interpolates 100 ms in the past and
  draws a skeleton through the partner's real joints, plus a name tag, distance and HP bar. This
  needs no model spawning, so it works in every chapter and with every costume.
* **Enemies: host-authoritative outcomes.** The level spawns the same enemies on both machines,
  and each machine runs its own AI.
  * The host numbers its enemies. Every 100 ms it broadcasts `{id, kind, ContextID, position,
    spawn position, HP, alive}`, plus recently killed enemies every 0.5 s for up to 3 min.
  * The client pairs each host enemy with its own copy by **`chainsaw.ContextID`**, falling back
    to **kind + spawn point** (deterministic level spawns), never current position, because the
    two copies chase different players.
  * Damage the client deals is detected by HP polling (`expected HP − current HP`). It is sent
    as `ENEMY_DAMAGE`, which the host applies. The client never *raises* HP to the host's value
    (that would undo damage still in flight). It only lowers HP and applies deaths. Deaths are
    sent reliably and re-advertised, so a partner who arrives late finds the room already
    cleared.
  * Optional position snapping (off by default) pulls the client's copies to the host's
    positions.
* **Key items exist once** (§3.2): whoever picks one up keeps it, and the partner's copy is
  removed.
* **Left-behind prompt** (§3.2): offers a teleport (F6) when the partner has been far away for a
  while, so the player without the key item is never stuck.
* **Utilities**: teleport to partner (transform + `CharacterController.warp`), chat, notices
  ("partner is down", "teleported to you"), and a diagnostics panel with the research dump.

### 4.1 Known limitations (v0.2)

* The partner is a ghost overlay, not a 3D character model. The experimental prefab puppet
  only follows position and rotation and is not animated.
* Enemies only target the local player, so each machine's copy of an enemy fights its own
  player. You don't see the partner's fight, and enemies don't choose between the two players.
  Positions are not synced except by optional snapping. This needs the research dump (§3.2).
* Random drops are rolled separately on each machine (§3.2).
* Story flags, doors and cutscenes are not synced. Key items are shared once, and the
  left-behind prompt brings the other player along.
* Pausing or opening the inventory pauses only your game. The connection survives because the
  network thread keeps running.
* Damage dealt to an enemy before your game has observed it once (the first ~50 ms after it
  spawns) is not reported.
* Both players need the same game version, REFramework build and mod version. A protocol
  mismatch is detected and reported.

## 5. Roadmap

1. **In-game validation of v0.2** with the checklist in [TESTING.md](TESTING.md), and collecting
   `re4coop_typedump.json` from the research dump.
2. With the dump: partner as an enemy target on the host (`HateController`), then client enemies
   as host puppets (AI off, transform + motion layer from the host), then identical drops
   (`DropItemManager`/`RandomDrop`).
3. Event-driven damage via `chainsaw.EnemyManager.notifyHitDamage` hooks, to remove polling
   latency.
4. An animated partner puppet: spawn the partner's character body prefab with AI components
   disabled, and drive its motion layer (`via.motion.Motion`) from the partner's current motion
   ID and frame.
5. Shared progression: sync door/gimmick interactions and story flags; host-driven chapter
   transitions.
6. Optional Steam networking transport for NAT traversal.

## Sources

* REFramework source: [`include/reframework/API.h`](https://github.com/praydog/REFramework/blob/master/include/reframework/API.h), [`src/mods/ScriptRunner.cpp`](https://github.com/praydog/REFramework/blob/master/src/mods/ScriptRunner.cpp), [`src/mods/bindings/Sdk.cpp`](https://github.com/praydog/REFramework/blob/master/src/mods/bindings/Sdk.cpp), [`src/mods/PluginLoader.cpp`](https://github.com/praydog/REFramework/blob/master/src/mods/PluginLoader.cpp), [`scripts/utility/RE4.lua`](https://github.com/praydog/REFramework/blob/master/scripts/utility/RE4.lua), [`examples/example_plugin`](https://github.com/praydog/REFramework/tree/master/examples/example_plugin)
* [REFramework discussion #1112: creating a prefab instance in RE4](https://github.com/praydog/REFramework/discussions/1112)
* [resyst/re4r `srt-overlay.lua`](https://github.com/resyst/re4r/blob/master/srt-overlay.lua) and [Joydurn/re4r-SRT](https://github.com/Joydurn/re4r-SRT/blob/master/srt-overlay.lua)
* [GreenComfyTea/RE4-Health-Bars](https://github.com/GreenComfyTea/RE4-Health-Bars)
* [alphazolam/EMV-Engine](https://github.com/alphazolam/EMV-Engine) (RE4 resource lists)
* [alphazolam/RE_RSZ `rszre4.json`](https://github.com/alphazolam/RE_RSZ) (RE4 type names and serialized fields)
* [resyst/re4r `re4r.asl`](https://github.com/resyst/re4r/blob/master/re4r.asl) (key item IDs)
* [Ekey/REE.PAK.Tool `RE4_STM_Release.list`](https://github.com/Ekey/REE.PAK.Tool) (RE4 resource paths, used for prefab paths)
* [RE4 Mod Menu (Nexus 7363)](https://www.nexusmods.com/residentevil42023/mods/7363), [True Invincible (Nexus 6165)](https://www.nexusmods.com/residentevil42023/mods/6165)
* claybtv Multiplayer Mod coverage: [Nexus 6539](https://www.nexusmods.com/residentevil42023/mods/6539), [Screen Rant](https://screenrant.com/resident-evil-4-remake-co-op-mod/), [Rely on Horror](https://www.relyonhorror.com/latest-news/resident-evil-news/resident-evil-4-remake-gets-full-co-op-mode-thanks-to-new-mod/), [Retro Dodo](https://retrododo.com/resident-evil-4-remake-now-has-a-co-op-mode-mod/)
