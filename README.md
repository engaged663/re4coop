# re4coop: LAN co-op for Resident Evil 4 (2023)

An open-source [REFramework](https://github.com/praydog/REFramework) mod that connects two
copies of **Resident Evil 4 (2023)** directly by IP address over UDP, so two players can go
through the campaign together on a LAN, or over the internet with a forwarded port or a VPN.

> **Status: v0.9.1, experimental.** v0.9.1 makes what one player sets off happen for both:
> **cutscenes play in both games** and **scripted events** (an area you walk into that starts a
> camera shot, a voice line, a scene) **run for the partner too**, and every story flag the
> game changes now reaches the partner ([why and how](docs/RESEARCH.md#311-v091-player-events-for-both-players)).
> v0.9 replaced the enemy sync with a new one built from
> scratch ([why and how](docs/RESEARCH.md#310-v09-enemy-sync-rebuilt-from-scratch)): every
> enemy is run by one game - by default the game of the player it is closer to, so **enemies
> attack both players** - and the other game shows it moving, turning and animating exactly
> like it; hits on it are run in its owner's game with every value of the original hit (same
> damage, same reaction), and its death comes with the killing hit, in the same place, in both
> games. The networking, sync logic and scripts are covered by automated tests, including
> end-to-end runs against a mock of REFramework, but most of it has **not yet been verified
> inside the running game.** Some RE4 method names are probed at runtime (see
> [docs/RESEARCH.md](docs/RESEARCH.md)). Please run the
> [in-game checklist](docs/TESTING.md#in-game-acceptance-checklist) and, after any crash, send
> `reframework/data/re4coop_breadcrumb_host.json` or `_client.json` (what the mod did last;
> `re4coop_breadcrumb.json` outside a session), `re2_framework_log.txt` and the crash report.

## What it does

| Feature | How |
|---|---|
| **Direct IP connection** | Host on a UDP port (default `33040`). The partner joins with `IP` or `IP:port`. Optional session password |
| **See your partner** | As their real character: the mod finds their body prefab automatically (Leon is `_chainsaw/appsystem/character/ch0a0z0/ch0a0z0_body.pfb`), dresses it in the costume parts they wear, and copies their full skeleton pose ~30 times a second. Every state animates (walk, run, crouch, aim, shoot, reload, knife, kicks, ladders, grabs, deaths) because the final pose itself is sent, not animation ids. Name tag, distance and HP bar on top |
| **Their weapons, shots and sounds** | Their weapon is spawned from its prefab (`wp4000.pfb`…) and held by the same hand joint, slide and all. Gunshots, reloads, footsteps and voice are replayed on the model's own sound containers, and shots get a muzzle flash |
| **Shared enemies** | Every enemy, dogs and bosses included, is matched with its copy in the partner's game by the ID the level gives it (the same on both PCs), wherever each game placed it |
| **Dead stays dead** | An enemy dead in the host's world never appears for the partner: killed in front of you it dies with its own death animation; one that only now spawns in your game, or is far away, is removed the way the game removes a finished enemy (no corpse, and it never comes back). That includes enemies the host killed before you joined (read from the host's save), and after your own game reloads a checkpoint. Enemies you killed where the host was not yet never appear for the host either |
| **Enemies fight both players** | Each enemy is run by exactly one game, with that game's real AI: by default the game of the player it is closer to (it changes hands smoothly when the other player has been clearly closer for a moment, and the player who keeps shooting it draws it). So the enemies near you attack you, and the ones near your partner attack them. *Who runs enemies: host* gives every enemy to the host's game instead |
| **Same position, rotation, animation and state** | The game that runs an enemy sends its full state 20 times a second: position, full rotation, velocity, HP, visibility and up to three animation layers (motion, frame, speed). In the other game the copy is a puppet: its AI and its own animation state machine are off, it stands, turns and animates exactly like the original, smoothly |
| **Same hits, same damage, same reactions** | Your hit on an enemy your partner's game runs is sent with every value of the game's own hit and run through the enemy's hit code in their game: the same damage, flinch, stagger, knock-down or part break, which you then see on your copy. Your shot still shows blood and takes the HP at once on your screen, but never kills there: the enemy's game decides. A yellow tracer shows each shot your partner lands |
| **Same deaths** | Only the game that runs an enemy decides its death, and sends it with the killing hit: in the other game the enemy dies where it died, from the same hit, with its own death animation and loot |
| **Your own loot from every enemy** | Every enemy that dies gives each player their own loot roll, tailored to that player's inventory like in the normal game, also the enemies your partner killed. You see your loot, your partner sees theirs |
| **Give items to your partner** | In the attache case, every item you can share (ammo, herbs and sprays, gunpowder and resources, grenades, weapon attachments, treasures) gets a last command, **Give to <partner>**: the item leaves your case and goes into your partner's, wherever they are. What does not fit in their case comes back to yours; nothing is ever lost. Key items, weapons and knives stay with you |
| **Key items exist once** | Whoever picks up a key item keeps it, and it disappears from the partner's world. Pickups are confirmed by the game's own "item obtained" flag |
| **One shared world** | The story progress lives in the game's scenario flags (objectives, map reveals, doors unlocked, items taken, events seen) and its gimmick table (locks, keys used, levers, shutters, puzzles). Every flag the game turns on, whatever turned it on, is applied in the partner's game through the game's own setter within a fraction of a second, both ways. A flag going back off (a checkpoint reload) never undoes the partner's world |
| **Cutscenes for both** | A cutscene or movie one player's game starts plays in the partner's game too: the game's own description of it (camera, flags it sets, the scripted sequence it continues, where it puts the players) is sent and played by the partner's game exactly as if their player had started it, **at once, wherever the partner is**: a partner who was far away watches it right away and is brought next to you when it ends. Never twice: a cutscene that save already played is skipped. **Skipping it skips it for both** (in the partner's game the same way its own skip button does) |
| **Scripted events for both** | When a player walks into an area that starts an event (a camera shot, a voice line, objects that move, a scene), the partner's game runs the same event with its own player if they are nearby. A partner far away gets it from their own game when they walk in, as always. Only pure events travel: doors, items, traps, deaths, saves and tutorials never run for the other player |
| **Doors that match** | A door your partner opens swings open in your game at once and stays open while they are in it, and closes in both games when neither of you is - normal and kick-open doors (RE4's own two-player door slots), automatic and elevator doors, timed shutters and big double doors |
| **Breakables and animals** | Break a crate, a barrel or a pot, shoot a crow: it breaks or dies in your partner's game too (animals fall dead, they don't vanish), and stays that way for an area they only reach later. Crows, chickens, fish, bats and rats near both players move as in the host's game: the same crow takes off and lands the same way on both screens |
| **No pauses in co-op** | While you host or are connected, the inventory, map, files and pause menu no longer freeze the world (the partner keeps playing). Cutscenes, loading screens, saving at a typewriter and the merchant still pause. Back to normal when you leave |
| **Join where the host is** | Joining takes over the host's world state (flags, doors, broken objects) and puts you next to the host. **Join from the title screen or the main menu and your game loads straight into the host's game**: no "load a save or start a new one" - it loads your co-op save (or, the first time, your latest save) into the host's chapter on its own, through the game's own Continue. In another chapter while playing, load any save (or *Continue*) and the game goes into the host's chapter |
| **Saves for both** | When either game saves - an autosave point, a chapter end, or a typewriter - the partner's game saves too: the host into its autosave, the client into its **co-op slot** (slot 20, it shows in Load Game). The client's own autosaves go there as well while connected, and a typewriter save it makes is copied there, so the co-op slot always holds the client's latest progress with the host (its inventory, weapons, money). Next time it joins, that is the save that loads |
| **Wait for each other (RE5/6 style)** | Reach a cutscene or the next chapter part first and the game holds you there until your partner arrives (they get an instant teleport prompt). **F8** continues alone |
| **Teleport to partner, any time** | Press **F6** (or the panel's button) whenever you want to be next to your partner - same area, another area (the game's own warp loads it) or, as the client, another chapter. It recharges for 3 s, and when it cannot work right now it says why (a cutscene playing, your partner loading, already next to them). The HUD always shows the key |
| **Never stuck** | When your partner has been far away, or in another stage, for a few seconds (e.g. they opened a door that needs their key item), the HUD reminds you of F6 (**F7** hides the reminder; it can be switched off in *Options*) |
| **Chat & notices** | In the REFramework menu. "Partner is down", "teleported to you"… |
| **Survives hiccups** | Reliable delivery with retransmits (sounds and effects on a lane of their own, so a lost packet never holds back the world). 1200-byte datagrams that pass through VPN tunnels unsplit. Pauses and loading screens don't drop you. Rejoin after a disconnect or game restart. "Reset Scripts" keeps the session |
| **Diagnostics** | *Performance*: what the mod costs per frame, its worst frame and its busiest parts (also written to `re4coop_perf.json`). A crash breadcrumb file. A capability list and a one-click research dump that collects game internals across runs |
| **Experimental** (off by default) | Features that change the game in ways not yet proven safe, each with its own switch in *Options → Experimental*: cross-stage warps, loading the partner's chapter automatically through game over, forcing breakable objects' state machines |

How it works and why: [docs/RESEARCH.md](docs/RESEARCH.md). Wire format: [docs/PROTOCOL.md](docs/PROTOCOL.md).

### Current limitations

* Most world features have not been seen working in the running game yet: the names of the game
  methods they use come from the game's type database and from another published RE4 mod, and
  are checked at runtime (*Diagnostics* lists each one as `[ok]` or `[--]`, and every feature
  has its own switch in *Options*). See [what is verified and what is probed](docs/RESEARCH.md#36-fifth-round-the-shared-world-v06).
* v0.6 crashed in game. v0.7 removes every cause we could find (see
  [the crash analysis](docs/RESEARCH.md#37-v07-crashes-stutter-lag-and-loot)) and puts the riskiest
  features behind *Experimental* switches, but it is not proven crash-free yet: the breadcrumb
  file names the last thing the mod did before a crash.
* **An enemy attacks the player of the game that runs it.** RE4's enemy AI only targets the
  player of its own game, so v0.9 gives each enemy to the game of the player it is closer to. An
  enemy standing between both players at the same distance attacks only one of them until it
  changes hands. With *Who runs enemies: host* only the host is attacked.
* Ragdolls, effects the enemies spawn themselves and grab reactions are simulated in each game
  on its own and can look different.
* The partner's model is a visual copy: it does not collide and your bullets pass through it.
* Thrown grenades, bullet impacts and blood on enemies happen only in the thrower's/shooter's
  game. Sounds the engine plays internally (outside the reflected `trigger` calls) may not be
  replayed; *Diagnostics* counts what gets through.
* Joining while you play another chapter, or following the host into the next one, needs a
  save load: load any save (or pick *Continue* after a game over) and it goes into the host's
  chapter. With *Experimental → Load the partner's chapter automatically* the mod triggers it.
  Joining from the title screen or the main menu loads on its own. With no save at all, start a
  New Game first.
* Saving for both (0.9.1) has not run in the game yet. A save from the partner waits until your
  game can save (no cutscene, no loading screen, not dying; the client also waits until it holds
  the host's world) and is dropped after 90 s. The client's co-op slot restarts at its own last
  checkpoint, like any save; joining then puts it next to the host. With the two copies of the
  game on one PC (they share their save files), the host's own slot 20 is the client's co-op
  slot: choose another in *Options → Saving* if you use it.
* Cutscene, skip, scripted-event and gimmick sync (0.9.1) have not run in the game yet. If one
  misbehaves, untick it in *Options → Shared world*; *Diagnostics* counts what was seen, sent,
  played, skipped and refused. A cutscene the game does not let you skip is not skipped for the
  partner either.
* A door or lever your partner changed takes the new state in your game at once, but an object
  already on your screen may only show it once its area reloads.
* Events that hand out or take items, kill, save or change the game mode are never run for the
  partner; their results (flags) still cross. A partner far from an event sees it when their
  own player walks in.
* If one player dies and reloads a checkpoint, only that player's game goes back. A partner who
  reloads takes the host's world again (enemies the host killed stay dead); when the host
  reloads, its enemies come back, but ones the partner's game already removed stay gone there.
* Enemies that only the partner's *own* save has dead (the partner joined with a save further
  ahead than the host's) cannot come back in the partner's game; joining with an older save
  avoids it.

## Install

Both players do this, with the **same game version and the same re4coop version**.

1. Install **REFramework** for RE4: get `RE4.zip` (or the universal `REFramework.zip`) from
   [REFramework nightly releases](https://github.com/praydog/REFramework-nightly/releases) or
   [Nexus](https://www.nexusmods.com/residentevil42023/mods/12). Put `dinput8.dll` next to
   `re4.exe`.
2. Download `re4coop-<version>.zip` from this repository's Releases or the CI artifacts.
   Extract it into the game folder so you get:
   ```
   <RE4 folder>/reframework/plugins/re4coop_net.dll
   <RE4 folder>/reframework/autorun/re4coop.lua
   <RE4 folder>/reframework/autorun/re4coop/*.lua
   ```
3. Start the game. Press **Insert** for the REFramework menu. You should see **RE4 Co-op (LAN)**.

## Play

1. **Host**: load your save, open *RE4 Co-op (LAN)*, set your name, click **Host game**. The
   panel lists your LAN addresses, for example `192.168.1.20:33040`. Tell your partner one of
   them. From now on your menus and inventory no longer pause the game.
2. **Partner**: from the title screen or any save, type that address into *Host IP* and click
   **Join game**. Your game goes to the host:
   * on the title screen or the main menu, it loads on its own, straight into the host's
     chapter: your co-op save (slot 20) if you have one, else your latest save;
   * in another chapter while playing, load any save and it loads into the host's chapter;
   * then the host's world state (doors, objectives, map, broken objects...) is applied and you
     appear next to the host. The HUD says what it is doing at each step.
3. The HUD in the top-left shows the connection, ping and distance. Your partner's character
   appears when you're both in game, in the same chapter (the first time it can take a moment
   while their model loads).

Windows may ask to allow `re4.exe` through the firewall the first time you host. Allow it on
**private networks**. If nobody can connect, add an inbound rule for **UDP 33040**.

**Over the internet**: forward UDP `33040` on the host's router, then the partner joins with
the host's public IP. Or skip port forwarding: both install a VPN such as Tailscale, ZeroTier
or Radmin VPN, and use the host's VPN IP.

**Bandwidth**: about 60–90 KB/s each way with the default 30 character poses per second (most
of it is the skeleton) and a room full of enemies. *Options* → *Character pose updates per
second* trades smoothness for bandwidth.

## Build from source

The plugin needs a C++17 compiler and CMake ≥ 3.20. Everything else is vendored (`third_party/`).

**Windows (Visual Studio 2022):**
```bat
cmake -S . -B build -A x64
cmake --build build --config Release
:: plugin:  build\Release\re4coop_net.dll
cmake --install build --config Release --prefix dist   :: assembles dist\reframework\...
```

**Linux (tests only), or cross-compiling the DLL with MinGW.** Use MinGW builds for development
only. Release DLLs are built with MSVC, the same toolchain REFramework uses, so Lua's
`longjmp`-based errors cross the plugin boundary safely:
```sh
cmake -S . -B build && cmake --build build -j && (cd build && ctest --output-on-failure)
cmake -S . -B build-win -DCMAKE_TOOLCHAIN_FILE=cmake/mingw-w64.cmake && cmake --build build-win -j
```

**Releasing:** bump the version in `lua/reframework/autorun/re4coop/protocol.lua`
(`MOD_VERSION`), `plugin/src/lua_api.hpp` (`kVersion`) and `CMakeLists.txt`, then push a
matching tag (`git tag v0.9.1 && git push origin v0.9.1`). CI builds the MSVC zip, checks the
versions and attaches `re4coop-v0.9.1.zip` + `.sha256` to a draft GitHub Release for you to
publish.

## Repository layout

```
plugin/src/net/        UDP transport: handshake, ordered + unordered reliable lanes, unreliable, timeouts
plugin/src/lua_api.*   `re4coop_net` Lua bindings (plain Lua C API)
plugin/src/plugin_main.cpp  REFramework plugin entry points
plugin/tests/          native transport tests + Lua test runner
lua/reframework/autorun/re4coop.lua   entry script (REFramework autoloads it)
lua/reframework/autorun/re4coop/      protocol, session, enemy_net, animal_sync, items_sync,
                                      drop_sync, gate, flag_sync, gimmick_sync, object_sync,
                                      cutscene_sync, trigger_sync, door_sync, give_sync, save_sync, travel,
                                      pause_policy, interp, config, ui, overlay, perf (profiler,
                                      crash breadcrumbs),
                                      game (RE4 adapter: player, prefabs, sound mirror, HP,
                                      pickups), game_enemies (enemies, puppets, hits), game_world (flags, gimmicks, breakables,
                                      cutscenes, event triggers, warps, chapters), game_give (items to the
                                      partner), game_save (saves, loading on join), game_pause (menu pauses),
                                      reflect (shape-based lookups), avatar, puppet
tests/lua/             Lua tests, including a REFramework/RE4 mock and an end-to-end UDP test
third_party/           Lua 5.4.3 (identical to REFramework's) and REFramework's API.h
docs/                  research, protocol, testing
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The game crashed | Send `reframework/data/re4coop_breadcrumb_host.json` / `_client.json` (in a session; `re4coop_breadcrumb.json` otherwise) (the last things the mod did, with the frame number), `re2_framework_log.txt` and the crash dump, and say what was happening. Then switch off the feature the breadcrumb names (every feature has a switch in *Options*) |
| Stutter or low frame rate in co-op | *Diagnostics → Performance* shows the mod's cost per frame and its busiest part; send `reframework/data/re4coop_perf.json`. *Options*: lower *Character pose updates per second*, or untick *Enemies your partner's game runs stand and move where theirs are* or *Animals near the client…* |
| Panel says `re4coop_net.dll is not loaded` | The DLL isn't in `reframework/plugins/`, or REFramework is too old. Check `re2_framework_log.txt` in the game folder |
| "could not reach host" | Wrong IP or port, the host didn't click *Host game*, or a firewall is blocking it (see above). Both must be on the same network or VPN |
| "Partner runs re4coop X…" | Install the same release on both PCs |
| No partner model, but connected | The partner is on the title screen or loading, or in a different chapter (the HUD warns you). Check *Options*. *Diagnostics* → *Partner model* says what was built (`prefab` or `mirror`) or why it failed |
| Partner model looks wrong or misbehaves | Tick *Build partner from meshes only* in *Options* (skips the body prefab). Then click *Write research dump* and open an issue with `reframework/data/re4coop_typedump.json` and `re4coop_research_log.json`: they list your character's objects, meshes and joints |
| Enemies not syncing | Open *Diagnostics*. `enemy_uid` must read `[ok] N of N enemies have a level identity`, and *enemy sync* shows the pairs made by ID; *enemy owners* shows how many enemies each game runs. If `enemy_uid`, `enemy_set_hp`, `enemy_list`, `enemy_puppet`, `enemy_motion`, `hit_values`, `hit_apply` or (after a partner's kill) `enemy_erase` show `[--]`, click *Write research dump* and send `reframework/data/re4coop_typedump.json` and `re4coop_research_log.json` |
| Enemies the partner killed still appear | *Diagnostics → enemy deaths* counts the dead in the shared world. On the host, `enemy_backups` must read `[ok]` after the partner joined. Untick *Enemies your partner already killed never appear in your game* to have them die visibly instead |
| Teleport prompt shows too often or too late | *Options → Progression*: distance and seconds sliders, or switch it off |
| A menu still pauses the game in co-op | *Options → Pauses*: tick *Also refuse pause requests*. *Diagnostics* lists which pause types were neutralised |
| Something in the shared world misbehaves (a door, a flag that keeps flipping, a cutscene, an event) | Switch that part off in *Options → Shared world* and keep playing. *Diagnostics* shows the counters for flags, cutscenes, event triggers, gimmicks and objects; flags that flip back and forth are muted automatically |
| A cutscene or an event shows for only one player | *Diagnostics*: `flag_hooks`, `cutscenes`, `cutscene_hooks`, `triggers` and `trigger_hooks` must be `[ok]`. The line *seen in our game* must count up when you set one off; *cutscenes* / *event triggers* say what was sent, played, refused or missed (a partner more than 40 m away runs an event when they walk in themselves) |
| Enemies jitter, freeze in a pose or slide | *Options → Enemies and animals*: raise *Enemy smoothing* a little; untick *…with their own animation state machine switched off*; then *…and play their animation*; then *…stand and move where theirs are* (each game then moves its own copies; HP, hits and deaths still sync). Tell us which one fixed it |
| Enemies change hands too often, or never attack you | *Who runs enemies* must read *shared* on the **host** (its setting decides). *enemy owners* in *Diagnostics* counts the hand-overs |
| Your shots do not make the partner's enemies react | *Diagnostics*: `hit_apply` on the partner's PC must be `[ok]` (without it their game only subtracts HP); `hit_values` lists how many hit values travel |
| Animals freeze, slide or behave oddly on the client's screen | Untick *Animals near both players… move as in the host's game* (they run on their own again; deaths still sync). *Diagnostics*: `animal_puppets` must be `[ok]`, and the *animals* line counts the ones following |
| Joining does not go to the host's chapter | *Diagnostics*: `chapter_switch` must be `[ok]`; then load any save while the HUD says it is joining. Without it, load the host's chapter yourself and use *Teleport to partner* |
| Joining from the title screen does not load anything | The host must be in game (the HUD says "Waiting for partner position" otherwise). *Diagnostics*: `join_load` must be `[ok]`; the *saves* line shows "menu asked 1" once the mod asked the game. With no save at all, start a New Game. *Options → Joining and travelling* can switch it off |
| The partner's game does not save with mine | *Diagnostics*: `save_sync` must be `[ok]`. A save waits while that game is in a cutscene, loading or (client) still taking over the host's world, and is dropped after 90 s. *Options → Saving* |
| No loot from enemies your partner killed | *Diagnostics*: `drop_hook` and `drop_request` must be `[ok]` and the *loot* line must not say "waiting for the first enemy drop" (kill an enemy yourself first: that proves the game's own rolls are seen) |

## Credits

* [praydog/REFramework](https://github.com/praydog/REFramework): the framework this builds on.
* RE4 type research from [LiterallyMetaphorical/RE4R-AP-Wizard](https://github.com/LiterallyMetaphorical/RE4R-AP-Wizard)
  (scenario flags, warps, chapter loads, game over, scene GUIDs),
  [GreenComfyTea/RE4-Health-Bars](https://github.com/GreenComfyTea/RE4-Health-Bars),
  [resyst/re4r](https://github.com/resyst/re4r) / [Joydurn/re4r-SRT](https://github.com/Joydurn/re4r-SRT),
  [alphazolam/EMV-Engine](https://github.com/alphazolam/EMV-Engine) (spawning, meshes, joint posing in
  RE Engine) and [SilverEzredes/Advanced-Weapon-Framework](https://github.com/SilverEzredes/Advanced-Weapon-Framework)
  (RE4 weapon objects). Prefab paths from the RE4 file list in
  [Ekey/REE.PAK.Tool](https://github.com/Ekey/REE.PAK.Tool).

Unofficial fan project, not affiliated with or endorsed by Capcom. It only touches the local
single-player game and does not use Capcom's online services. MIT licensed. Third-party
licenses are listed in [third_party/README.md](third_party/README.md).
