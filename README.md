# re4coop: LAN co-op for Resident Evil 4 (2023)

An open-source [REFramework](https://github.com/praydog/REFramework) mod that connects two
copies of **Resident Evil 4 (2023)** directly by IP address over UDP, so two players can go
through the campaign together on a LAN, or over the internet with a forwarded port or a VPN.

> **Status: v0.2, experimental.** The networking, sync logic and scripts are covered by
> automated tests, including end-to-end runs against a mock of REFramework. They have **not yet
> been verified inside the running game.** Some RE4 method names are probed at runtime (see
> [docs/RESEARCH.md](docs/RESEARCH.md)). Please run the
> [in-game checklist](docs/TESTING.md#in-game-acceptance-checklist) and report what you find.

## What it does

| Feature | How |
|---|---|
| **Direct IP connection** | Host on a UDP port (default `33040`). The partner joins with `IP` or `IP:port`. Optional session password |
| **See your partner** | Their real skeleton is drawn as a "ghost" (interpolated, 20 Hz), with name tag, distance and HP bar |
| **Shared enemies** | The host is authoritative. Damage you deal is applied to the host's copy, and HP and kills sync back during the fight. Enemies are paired by the game's own `ContextID`. Rooms the host already cleared stay cleared for a partner who arrives later |
| **Key items exist once** | Whoever picks up a key item keeps it, and it disappears from the partner's world |
| **Never stuck** | When your partner has been far away for a few seconds (e.g. they opened a door that needs their key item), press **F6** to teleport to them, or **F7** to hide the prompt |
| **Teleport to partner** | One click, for after doors and cutscenes |
| **Chat & notices** | In the REFramework menu. "Partner is down", "teleported to you"… |
| **Survives hiccups** | Reliable channel with retransmits. Pauses and loading screens don't drop you. Rejoin after a disconnect or game restart. "Reset Scripts" keeps the session |
| **Diagnostics** | A capability list and a one-click type dump to fix things after game patches |

How it works and why: [docs/RESEARCH.md](docs/RESEARCH.md). Wire format: [docs/PROTOCOL.md](docs/PROTOCOL.md).

### Current limitations

* Your partner appears as a ghost skeleton, not a 3D character. An experimental model puppet
  is off by default.
* Each game runs its own enemy AI: enemies attack the player on their own machine, and you
  don't see your partner's fight. Outcomes (HP, deaths) are what's shared. Making enemies
  target both players needs game internals that the in-game research dump will provide.
* Random drops are rolled separately on each machine (same reason).
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
4. The HUD in the top-left shows the connection, ping and distance. Your partner's ghost
   appears when you're in the same area.

Windows may ask to allow `re4.exe` through the firewall the first time you host. Allow it on
**private networks**. If nobody can connect, add an inbound rule for **UDP 33040**.

**Over the internet**: forward UDP `33040` on the host's router, then the partner joins with
the host's public IP. Or skip port forwarding: both install a VPN such as Tailscale, ZeroTier
or Radmin VPN, and use the host's VPN IP.

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
matching tag (`git tag v0.2.0 && git push origin v0.2.0`). CI builds the MSVC zip, checks the
versions and attaches `re4coop-v0.2.0.zip` + `.sha256` to a draft GitHub Release for you to
publish.

## Repository layout

```
plugin/src/net/        UDP transport: handshake, reliable + unreliable channels, timeouts
plugin/src/lua_api.*   `re4coop_net` Lua bindings (plain Lua C API)
plugin/src/plugin_main.cpp  REFramework plugin entry points
plugin/tests/          native transport tests + Lua test runner
lua/reframework/autorun/re4coop.lua   entry script (REFramework autoloads it)
lua/reframework/autorun/re4coop/      protocol, session, enemy_sync, interp, game (RE4 adapter), ghost, ui, config
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
| No ghost, but connected | The partner is on the title screen or loading, or in a different chapter (the HUD warns you). Check the *Options* toggles |
| Enemies not syncing | Open *Diagnostics*. If `enemy_set_hp`/`enemy_list` show `[--]` after a few hits, click *Write research dump* and send `reframework/data/re4coop_typedump.json` |
| Teleport prompt shows too often or too late | *Options → Progression*: distance and seconds sliders, or switch it off |

## Credits

* [praydog/REFramework](https://github.com/praydog/REFramework): the framework this builds on.
* RE4 type research from [GreenComfyTea/RE4-Health-Bars](https://github.com/GreenComfyTea/RE4-Health-Bars),
  [resyst/re4r](https://github.com/resyst/re4r) / [Joydurn/re4r-SRT](https://github.com/Joydurn/re4r-SRT)
  and [alphazolam/EMV-Engine](https://github.com/alphazolam/EMV-Engine).

Unofficial fan project, not affiliated with or endorsed by Capcom. It only touches the local
single-player game and does not use Capcom's online services. MIT licensed. Third-party
licenses are listed in [third_party/README.md](third_party/README.md).
