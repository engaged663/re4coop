# re4coop: LAN co-op for Resident Evil 4 (2023)

An open-source [REFramework](https://github.com/praydog/REFramework) mod that connects two
copies of **Resident Evil 4 (2023)** directly by IP address over UDP, so two players can go
through the campaign together on a LAN, or over the internet with a forwarded port or a VPN.

> **Status: v0.8, experimental.** v0.8 rebuilds enemy sync after the in-game tests of v0.7
> (killed enemies still alive for the partner, wrong enemy positions, different spawns): enemies
> are now identified, killed and removed the way RE4 itself does it (see
> [the research](docs/RESEARCH.md#38-v08-enemy-sync-on-the-games-own-identities)), and the
> host's game runs every enemy and animal while the partner's game shows them
> ([why and how](docs/RESEARCH.md#39-v08-one-authority---everything-follows-the-host)). The networking, sync logic
> and scripts are covered by automated tests, including end-to-end runs against a mock of
> REFramework, but most of it has **not yet been verified inside the running game.** Some RE4
> method names are probed at runtime (see [docs/RESEARCH.md](docs/RESEARCH.md)). Please run the
> [in-game checklist](docs/TESTING.md#in-game-acceptance-checklist) and, after any crash, send
> `reframework/data/re4coop_breadcrumb.json` (what the mod did last) and `re2_framework_log.txt`.

## What it does

| Feature | How |
|---|---|
| **Direct IP connection** | Host on a UDP port (default `33040`). The partner joins with `IP` or `IP:port`. Optional session password |
| **See your partner** | As their real character: the mod finds their body prefab automatically (Leon is `_chainsaw/appsystem/character/ch0a0z0/ch0a0z0_body.pfb`), dresses it in the costume parts they wear, and copies their full skeleton pose ~30 times a second. Every state animates (walk, run, crouch, aim, shoot, reload, knife, kicks, ladders, grabs, deaths) because the final pose itself is sent, not animation ids. Name tag, distance and HP bar on top |
| **Their weapons, shots and sounds** | Their weapon is spawned from its prefab (`wp4000.pfb`…) and held by the same hand joint, slide and all. Gunshots, reloads, footsteps and voice are replayed on the model's own sound containers, and shots get a muzzle flash |
| **Shared enemies** | Every enemy, dogs and bosses included, is matched with its copy in the partner's game by the ID the level gives it (the same on both PCs), wherever each game placed it. The host is authoritative: damage the partner deals is applied to the host's enemy, and HP and kills sync back during the fight |
| **Dead stays dead** | An enemy dead in the host's world never appears for the partner: killed in front of you it dies with its own death animation; one that only now spawns in your game, or is far away, is removed the way the game removes a finished enemy (no corpse, and it never comes back). That includes enemies the host killed before you joined (read from the host's save), and after your own game reloads a checkpoint. Enemies you killed where the host was not yet never appear for the host either |
| **One game runs every enemy** | The host's game runs every enemy: its AI, movement, health and death. Nothing ever changes hands. In the partner's game each of those enemies follows the host's: same place, same facing, same animation, with its own AI switched off. Enemies the host's game has not loaded yet (the partner ran ahead) run in the partner's game until the host's level spawns them. RE4's enemies only target their own game's player, so they go for the host's character (see *Current limitations*) |
| **See your partner's hits** | A tracer line shows each shot your partner lands, and the enemy reacts on your screen the way it reacts in the host's game. Replaying the hit on your copy as well is an experimental switch |
| **Your own loot from every enemy** | Every enemy that dies gives each player their own loot roll, tailored to that player's inventory like in the normal game, also the enemies your partner killed. You see your loot, your partner sees theirs |
| **Key items exist once** | Whoever picks up a key item keeps it, and it disappears from the partner's world. Pickups are confirmed by the game's own "item obtained" flag |
| **One shared world** | The story progress lives in the game's scenario flags (objectives, map reveals, doors unlocked, items taken, events seen) and its gimmick table (locks, keys used, levers, shutters, puzzles). Every change on one side is applied on the other through the game's own setters, within a fraction of a second, both ways |
| **Breakables and animals** | Break a crate, a barrel or a pot, shoot a crow: it breaks or dies in your partner's game too (animals fall dead, they don't vanish), and stays that way for an area they only reach later. Crows, chickens, fish, bats and rats near both players move as in the host's game: the same crow takes off and lands the same way on both screens |
| **No pauses in co-op** | While you host or are connected, the inventory, map, files and pause menu no longer freeze the world (the partner keeps playing). Cutscenes, loading screens, saving at a typewriter and the merchant still pause. Back to normal when you leave |
| **Join where the host is** | Joining takes over the host's world state (flags, doors, broken objects) and puts you next to the host. If you are in another chapter, load any save (or *Continue*) and the game goes into the host's chapter |
| **Wait for each other (RE5/6 style)** | Reach a cutscene or the next chapter part first and the game holds you there until your partner arrives (they get an instant teleport prompt). **F8** continues alone |
| **Never stuck** | When your partner has been far away, or in another stage, for a few seconds (e.g. they opened a door that needs their key item), press **F6** to teleport to them, or **F7** to hide the prompt |
| **Teleport to partner** | One click, or F6 when the prompt shows |
| **Chat & notices** | In the REFramework menu. "Partner is down", "teleported to you"… |
| **Survives hiccups** | Reliable delivery with retransmits (sounds and effects on a lane of their own, so a lost packet never holds back the world). 1200-byte datagrams that pass through VPN tunnels unsplit. Pauses and loading screens don't drop you. Rejoin after a disconnect or game restart. "Reset Scripts" keeps the session |
| **Diagnostics** | *Performance*: what the mod costs per frame, its worst frame and its busiest parts (also written to `re4coop_perf.json`). A crash breadcrumb file. A capability list and a one-click research dump that collects game internals across runs |
| **Experimental** (off by default) | Features that change the game in ways not yet proven safe, each with its own switch in *Options → Experimental*: replaying the partner's hits on your enemies, starting the partner's cutscenes in your game, cross-stage warps, loading the partner's chapter automatically through game over, live flag-table reloads, forcing breakable objects' state machines |

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
* **Enemies only attack the host.** The host's game runs every enemy, and RE4's enemy AI only
  targets the player of its own game: enemies chase and attack the host's character, and the
  partner (client) is not attacked by enemies the host's game has loaded, only by enemies it
  meets before the host's game has spawned them. The client still shoots, damages and kills
  enemies normally. Making the partner a target is on the [roadmap](docs/RESEARCH.md#5-roadmap).
* The partner's model is a visual copy: it does not collide and your bullets pass through it.
* Thrown grenades, bullet impacts and blood on enemies happen only in the thrower's/shooter's
  game. Sounds the engine plays internally (outside the reflected `trigger` calls) may not be
  replayed; *Diagnostics* counts what gets through.
* Joining from another chapter, or following the host into the next one, needs a save load:
  load any save (or pick *Continue* after a game over) and it goes into the host's chapter.
  With *Experimental → Load the partner's chapter automatically* the mod triggers it.
* Cutscenes are not started in the partner's game by default (experimental): each player
  watches a cutscene when they reach it, and the transition gate makes both arrive together.
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
   * in another chapter (or on the title screen), load any save and it loads into the host's
     chapter;
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
matching tag (`git tag v0.8.0 && git push origin v0.8.0`). CI builds the MSVC zip, checks the
versions and attaches `re4coop-v0.8.0.zip` + `.sha256` to a draft GitHub Release for you to
publish.

## Repository layout

```
plugin/src/net/        UDP transport: handshake, ordered + unordered reliable lanes, unreliable, timeouts
plugin/src/lua_api.*   `re4coop_net` Lua bindings (plain Lua C API)
plugin/src/plugin_main.cpp  REFramework plugin entry points
plugin/tests/          native transport tests + Lua test runner
lua/reframework/autorun/re4coop.lua   entry script (REFramework autoloads it)
lua/reframework/autorun/re4coop/      protocol, session, enemy_sync, animal_sync, items_sync,
                                      drop_sync, gate, flag_sync, gimmick_sync, object_sync,
                                      cutscene_sync, travel,
                                      pause_policy, interp, config, ui, overlay, perf (profiler,
                                      crash breadcrumbs),
                                      game (RE4 adapter: player, enemies, prefabs, sound mirror,
                                      HP, pickups), game_world (flags, gimmicks, breakables,
                                      cutscenes, warps, chapters), game_pause (menu pauses),
                                      reflect (shape-based lookups), avatar, puppet
tests/lua/             Lua tests, including a REFramework/RE4 mock and an end-to-end UDP test
third_party/           Lua 5.4.3 (identical to REFramework's) and REFramework's API.h
docs/                  research, protocol, testing
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The game crashed | Send `reframework/data/re4coop_breadcrumb.json` (the last things the mod did, with the frame number), `re2_framework_log.txt` and the crash dump, and say what was happening. Then switch off the feature the breadcrumb names (every feature has a switch in *Options*) |
| Stutter or low frame rate in co-op | *Diagnostics → Performance* shows the mod's cost per frame and its busiest part; send `reframework/data/re4coop_perf.json`. *Options*: lower *Character pose updates per second*, or untick *Client: enemies stand and move where the host's are* or *Animals near both players…* |
| Panel says `re4coop_net.dll is not loaded` | The DLL isn't in `reframework/plugins/`, or REFramework is too old. Check `re2_framework_log.txt` in the game folder |
| "could not reach host" | Wrong IP or port, the host didn't click *Host game*, or a firewall is blocking it (see above). Both must be on the same network or VPN |
| "Partner runs re4coop X…" | Install the same release on both PCs |
| No partner model, but connected | The partner is on the title screen or loading, or in a different chapter (the HUD warns you). Check *Options*. *Diagnostics* → *Partner model* says what was built (`prefab` or `mirror`) or why it failed |
| Partner model looks wrong or misbehaves | Tick *Build partner from meshes only* in *Options* (skips the body prefab). Then click *Write research dump* and open an issue with `reframework/data/re4coop_typedump.json` and `re4coop_research_log.json`: they list your character's objects, meshes and joints |
| Enemies not syncing | Open *Diagnostics*. `enemy_uid` must read `[ok] N of N enemies have a level identity`, and *enemy sync* shows the pairs made by ID. If `enemy_uid`, `enemy_set_hp`, `enemy_list` or (after a partner's kill) `enemy_erase` show `[--]`, click *Write research dump* and send `reframework/data/re4coop_typedump.json` and `re4coop_research_log.json` |
| Enemies the partner killed still appear | *Diagnostics → enemy deaths* counts the dead in the shared world. On the host, `enemy_backups` must read `[ok]` after the partner joined. Untick *Enemies your partner already killed never appear in your game* to have them die visibly instead |
| Teleport prompt shows too often or too late | *Options → Progression*: distance and seconds sliders, or switch it off |
| A menu still pauses the game in co-op | *Options → Pauses*: tick *Also refuse pause requests*. *Diagnostics* lists which pause types were neutralised |
| Something in the shared world misbehaves (a door, a flag that keeps flipping, a cutscene) | Switch that part off in *Options → Shared world* and keep playing. *Diagnostics* shows the counters for flags, gimmicks, objects and cutscenes; flags that flip back and forth are muted automatically |
| Enemies jitter or stand still on the client's screen | *Options → Enemies and animals*: raise *Client: enemy smoothing* a little, untick *Client: enemies and animals play the host's animation*, then *Client: enemies stand and move where the host's are* (the client's game then moves its own copies; HP and deaths still sync) |
| Animals freeze, slide or behave oddly on the client's screen | Untick *Animals near both players… move as in the host's game* (they run on their own again; deaths still sync). *Diagnostics*: `animal_puppets` must be `[ok]`, and the *animals* line counts the ones following |
| Joining does not go to the host's chapter | *Diagnostics*: `chapter_switch` must be `[ok]`; then load any save while the HUD says it is joining. Without it, load the host's chapter yourself and use *Teleport to partner* |
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
