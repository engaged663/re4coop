# re4coop: LAN co-op for Resident Evil 4 (2023)

An open-source [REFramework](https://github.com/praydog/REFramework) mod that connects two
copies of **Resident Evil 4 (2023)** directly by IP address over UDP, so two players can go
through the campaign together on a LAN, or over the internet with a forwarded port or a VPN.

> **Status: v0.5, experimental.** The networking, sync logic and scripts are covered by
> automated tests, including end-to-end runs against a mock of REFramework. They have **not yet
> been verified inside the running game.** Some RE4 method names are probed at runtime (see
> [docs/RESEARCH.md](docs/RESEARCH.md)). Please run the
> [in-game checklist](docs/TESTING.md#in-game-acceptance-checklist) and report what you find.

## What it does

| Feature | How |
|---|---|
| **Direct IP connection** | Host on a UDP port (default `33040`). The partner joins with `IP` or `IP:port`. Optional session password |
| **See your partner** | As their real character: the mod finds their body prefab automatically (Leon is `_chainsaw/appsystem/character/ch0a0z0/ch0a0z0_body.pfb`), dresses it in the costume parts they wear, and copies their full skeleton pose ~30 times a second. Every state animates (walk, run, crouch, aim, shoot, reload, knife, kicks, ladders, grabs, deaths) because the final pose itself is sent, not animation ids. Name tag, distance and HP bar on top |
| **Their weapons, shots and sounds** | Their weapon is spawned from its prefab (`wp4000.pfb`…) and held by the same hand joint, slide and all. Gunshots, reloads, footsteps and voice are replayed on the model's own sound containers, and shots get a muzzle flash |
| **Shared enemies** | The host is authoritative. Damage you deal is applied to the host's copy, and HP and kills sync back during the fight. Enemies are paired by spawn point and, once proven reliable, by their level spawner's ID. Rooms the host already cleared stay cleared for a partner who arrives later |
| **See your partner's hits** | When your partner shoots an enemy, your copy of it flinches and staggers, and a tracer line shows the shot |
| **Identical enemy drops** | The host's roll decides what an enemy drops, for both players (switches itself off if spawning the item doesn't work) |
| **Key items exist once** | Whoever picks up a key item keeps it, and it disappears from the partner's world. Pickups are confirmed by the game's own "item obtained" flag |
| **Wait for each other (RE5/6 style)** | Reach a cutscene or the next chapter part first and the game holds you there until your partner arrives (they get an instant teleport prompt). **F8** continues alone |
| **Never stuck** | When your partner has been far away, or in another stage, for a few seconds (e.g. they opened a door that needs their key item), press **F6** to teleport to them, or **F7** to hide the prompt |
| **Teleport to partner** | One click, for after doors and cutscenes |
| **Chat & notices** | In the REFramework menu. "Partner is down", "teleported to you"… |
| **Survives hiccups** | Reliable channel with retransmits. Pauses and loading screens don't drop you. Rejoin after a disconnect or game restart. "Reset Scripts" keeps the session |
| **Diagnostics** | A capability list and a one-click research dump that collects game internals across runs, for fixing things after game patches and building the next features |

How it works and why: [docs/RESEARCH.md](docs/RESEARCH.md). Wire format: [docs/PROTOCOL.md](docs/PROTOCOL.md).

### Current limitations

* The partner's model is a visual copy: it does not collide, enemies on your machine don't see
  it, and your bullets pass through it.
* Thrown grenades, bullet impacts and blood on enemies happen only in the thrower's/shooter's
  game. Sounds the engine plays internally (outside the reflected `trigger` calls) may not be
  replayed; *Diagnostics* counts what gets through.
* Each game runs its own enemy AI: enemies attack the player on their own machine, and enemy
  positions differ between the two games. You see your partner shoot and your enemies flinch
  from their hits, but not enemies attacking your partner. Making enemies target both players
  is the next step ([plan](docs/RESEARCH.md#35-fourth-research-round-31-runs-in-chapter-1-v05)).
* Wooden boxes and other breakables are not synced yet. Only enemy drops are identical.
* Story events, doors and cutscenes are not synced. Key items are shared once, and the F6
  prompt regroups you.
* Pausing or opening the inventory pauses only your own game.

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

1. Both players load **the same chapter** (the same save, ideally).
2. **Host**: open *RE4 Co-op (LAN)*, set your name, click **Host game**. The panel lists your
   LAN addresses, for example `192.168.1.20:33040`. Tell your partner one of them.
3. **Partner**: type that address into *Host IP* and click **Join game**.
4. The HUD in the top-left shows the connection, ping and distance. Your partner's character
   appears when you're both in game, in the same chapter (the first time it can take a moment
   while their model loads).

Windows may ask to allow `re4.exe` through the firewall the first time you host. Allow it on
**private networks**. If nobody can connect, add an inbound rule for **UDP 33040**.

**Over the internet**: forward UDP `33040` on the host's router, then the partner joins with
the host's public IP. Or skip port forwarding: both install a VPN such as Tailscale, ZeroTier
or Radmin VPN, and use the host's VPN IP.

**Bandwidth**: about 50–70 KB/s each way with the default 30 character poses per second (most
of it is the skeleton). *Options* → *Character pose updates per second* trades smoothness for
bandwidth.

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
matching tag (`git tag v0.5.0 && git push origin v0.5.0`). CI builds the MSVC zip, checks the
versions and attaches `re4coop-v0.5.0.zip` + `.sha256` to a draft GitHub Release for you to
publish.

## Repository layout

```
plugin/src/net/        UDP transport: handshake, reliable + unreliable channels, timeouts
plugin/src/lua_api.*   `re4coop_net` Lua bindings (plain Lua C API)
plugin/src/plugin_main.cpp  REFramework plugin entry points
plugin/tests/          native transport tests + Lua test runner
lua/reframework/autorun/re4coop.lua   entry script (REFramework autoloads it)
lua/reframework/autorun/re4coop/      protocol, session, enemy_sync, items_sync, interp, config,
                                      ui, game (RE4 adapter: capture, prefabs, sound mirror, HP,
                                      pickups), avatar (character sync), puppet (partner model),
                                      overlay
tests/lua/             Lua tests, including a REFramework/RE4 mock and an end-to-end UDP test
third_party/           Lua 5.4.3 (identical to REFramework's) and REFramework's API.h
docs/                  research, protocol, testing
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Panel says `re4coop_net.dll is not loaded` | The DLL isn't in `reframework/plugins/`, or REFramework is too old. Check `re2_framework_log.txt` in the game folder |
| "could not reach host" | Wrong IP or port, the host didn't click *Host game*, or a firewall is blocking it (see above). Both must be on the same network or VPN |
| "Partner runs re4coop X…" | Install the same release on both PCs |
| No partner model, but connected | The partner is on the title screen or loading, or in a different chapter (the HUD warns you). Check *Options*. *Diagnostics* → *Partner model* says what was built (`prefab` or `mirror`) or why it failed |
| Partner model looks wrong or misbehaves | Tick *Build partner from meshes only* in *Options* (skips the body prefab). Then click *Write research dump* and open an issue with `reframework/data/re4coop_typedump.json` and `re4coop_research_log.json`: they list your character's objects, meshes and joints |
| Enemies not syncing | Open *Diagnostics*. If `enemy_set_hp`/`enemy_list` show `[--]` after a few hits, click *Write research dump* and send `reframework/data/re4coop_typedump.json` and `re4coop_research_log.json` |
| Teleport prompt shows too often or too late | *Options → Progression*: distance and seconds sliders, or switch it off |

## Credits

* [praydog/REFramework](https://github.com/praydog/REFramework): the framework this builds on.
* RE4 type research from [GreenComfyTea/RE4-Health-Bars](https://github.com/GreenComfyTea/RE4-Health-Bars),
  [resyst/re4r](https://github.com/resyst/re4r) / [Joydurn/re4r-SRT](https://github.com/Joydurn/re4r-SRT),
  [alphazolam/EMV-Engine](https://github.com/alphazolam/EMV-Engine) (spawning, meshes, joint posing in
  RE Engine) and [SilverEzredes/Advanced-Weapon-Framework](https://github.com/SilverEzredes/Advanced-Weapon-Framework)
  (RE4 weapon objects). Prefab paths from the RE4 file list in
  [Ekey/REE.PAK.Tool](https://github.com/Ekey/REE.PAK.Tool).

Unofficial fan project, not affiliated with or endorsed by Capcom. It only touches the local
single-player game and does not use Capcom's online services. MIT licensed. Third-party
licenses are listed in [third_party/README.md](third_party/README.md).
