# re4coop: LAN co-op for Resident Evil 4 (2023)

An open-source [REFramework](https://github.com/praydog/REFramework) mod that connects two
copies of **Resident Evil 4 (2023)** directly by IP address over UDP, so two players can go
through the campaign together on a LAN, or over the internet with a forwarded port or a VPN.

> **Status: v0.11.2, experimental.** (0.11.2: **a client who joins late appears next to the host** - from the title screen, the main menu or Join Game (the lobby gives way by itself when the host is playing) the client's game loads straight into the host's chapter and part of the map, at the host's place; without a save it starts a new game at the start of the host's chapter part; already in game, it reloads there through the game's own Load Game instead of asking for a save ([why and how](docs/RESEARCH.md#334-a-late-client-loads-straight-into-the-hosts-place-0112)); 0.11.1: **no more black screen for the client after the bell in the village** - a cutscene that ends a chapter part sends both games through their own chapter change, and the mod no longer saves, travels, freezes or applies the partner's world in the middle of it; a screen left black after one is brought back ([why and how](docs/RESEARCH.md#333-the-clients-black-screen-after-the-bell-in-the-village-0111)); 0.11: **Multijugador in the game's own main menu** - Host Game / Join Game / Multiplayer Options, a lobby with chat, co-op saves, chapter, difficulty, options and loadouts, and both maps starting together once both have loaded ([why and how](docs/RESEARCH.md#331-v011-the-lobby-in-the-games-own-main-menu)); 0.10.3: the host's enemies react to the client's shots and die from them; 0.10.2 fixed the client running at 2 fps.) v0.10 gives **every enemy to the host**: nothing is shared
> and nothing changes hands - the host's game runs every enemy's AI, and the client's game shows
> it moving, turning and animating exactly like it. The client's player is **a second player in
> the host's game** ([why and how](docs/RESEARCH.md#325-v010-the-client-as-a-second-player-in-the-hosts-game)):
> the host's enemies see the client, hear the client's shots and steps, chase the client and
> attack the client with their own AI, exactly as they do the host; their blows land on the
> client's character, and the client takes them in its own game. The client's shots, kicks,
> stealth kills and knife finishes run on the host's enemies as if the host's player had made
> them. v0.10.1 adds the rest ([why and how](docs/RESEARCH.md#326-v0101-the-hosts-shots-parries-grabs-and-bosses-against-the-client)):
> the host's enemies warn the client of their attacks and **the client's parries stagger them**,
> they **grab the client**, who breaks free in their own game, **bosses go for the client** when
> the client is the one they hate most, and **the host's bullets pass the client's character**. v0.9.1 made what one player sets off happen for both: **cutscenes play in both games**
> and **scripted events run for the partner too**
> ([why and how](docs/RESEARCH.md#311-v091-player-events-for-both-players)). The networking,
> sync logic and scripts are covered by automated tests, including
> end-to-end runs against a mock of REFramework, but most of it has **not yet been verified
> inside the running game.** Some RE4 method names are probed at runtime (see
> [docs/RESEARCH.md](docs/RESEARCH.md)). Please run the
> [in-game checklist](docs/TESTING.md#in-game-acceptance-checklist) and, after any crash, send
> `reframework/data/re4coop_breadcrumb_host.json` or `_client.json` (what the mod did last;
> `re4coop_breadcrumb.json` outside a session), `re2_framework_log.txt` and the crash report.

## What it does

| Feature | How |
|---|---|
| **Multijugador in the game's menu** | The main menu gets a **Multijugador** entry above *Opciones*, a real entry of the game's own list. It opens the section **Host Game**, **Join Game**, **Multiplayer Options** and **Back** |
| **Lobby** | Host Game opens a lobby over the menu, in the style of the game's menus: the host picks a **co-op save** of its own (3 files, list slots 17-19 by default; the single-player autosave is never touched), new game or continue, the **chapter** (any of the 16), the difficulty and the game's options; each player picks a **loadout** (weapons added to the case at the start); **chat**; both mark **ready** and the host starts. Join Game: type the host's address and land in its lobby. Keyboard, mouse and pad |
| **Start together** | Both games load the agreed game (a new game from the chosen chapter's start, or the co-op saves). Two **loaders** sit in the bottom left corner; the map that loads first waits, frozen under a veil, until the other has loaded too, then both start at once |
| **Direct IP connection** | Host on a UDP port (default `33040`). The partner joins with `IP` or `IP:port`. Optional session password |
| **See your partner** | As their real character: the mod finds their body prefab automatically (Leon is `_chainsaw/appsystem/character/ch0a0z0/ch0a0z0_body.pfb`), dresses it in the costume parts they wear, and copies their full skeleton pose ~30 times a second. Every state animates (walk, run, crouch, aim, shoot, reload, knife, kicks, ladders, grabs, deaths) because the final pose itself is sent, not animation ids. Name tag, distance and HP bar on top |
| **Their weapons, shots and sounds** | Their weapon is spawned from its prefab (`wp4000.pfb`…) and held by the same hand joint, slide and all. Gunshots, reloads, footsteps and voice are replayed on the model's own sound containers, and shots get a muzzle flash |
| **Shared enemies** | Every enemy, dogs and bosses included, is matched with its copy in the partner's game by the ID the level gives it (the same on both PCs), wherever each game placed it |
| **Dead stays dead** | An enemy dead in the host's world never appears for the partner: killed in front of you it dies with its own death animation; one that only now spawns in your game, or is far away, is removed the way the game removes a finished enemy (no corpse, and it never comes back). That includes enemies the host killed before you joined (read from the host's save), and after your own game reloads a checkpoint. Enemies you killed where the host was not yet never appear for the host either |
| **The host runs every enemy** | Every enemy is run by the host's game, with its real AI, always: nothing changes hands, however close the client gets or however long it shoots. In the client's game every enemy is a puppet of the host's; one the host's world does not have (not spawned there yet, or its area unloaded) waits, still and unseen, until it does |
| **Enemies fight both players** | In the host's game the client's character is a second player: the host's enemies **see** it (it carries the player's target marker), **hear** the client's shots, steps and reloads (they are made by its character in the host's world), turn on it when the client hits them, **chase and attack** it with their own AI. Their blows land on the client's character there and the client takes them in its own game - the same attack, damage and reaction, its own dodges and invincibility included - when its copy of the enemy shows the blow. The client sees which enemies are after it |
| **Same position, rotation, animation and state** | The host sends the full state of its enemies 20 times a second: position, full rotation, velocity, HP, visibility and up to three animation layers (motion, frame, speed). In the client's game the copy is a puppet: its AI and its own animation state machine are off, it stands, turns and animates exactly like the original, smoothly |
| **The client plays like the host** | The client's hit on an enemy is sent with every value of the game's own hit and run through the enemy's hit code in the host's game, with the client's character as the attacker: the same damage, flinch, stagger, knock-down or part break, and the enemy turns on the client. Its shot still shows blood and takes the HP at once on its screen, but never kills there: the host decides. Finishers too: the prompts the client gets come from what the host's enemy says (kick, stealth kill, knife finish), and acting on one makes the host's enemy play its side with the client as the attacker. A yellow tracer shows each shot your partner lands |
| **Same deaths** | Only the host's game decides a death, and sends it with the killing hit: in the client's game the enemy dies where it died, from the same hit, with its own death animation and loot (and it counts as the client's kill when the client's hit or finisher killed it) |
| **Your own loot from every enemy** | Every enemy that dies gives each player their own loot roll, tailored to that player's inventory like in the normal game, also the enemies your partner killed. You see your loot, your partner sees theirs |
| **Give items to your partner** | In the attache case, every item you can share (ammo, herbs and sprays, gunpowder and resources, grenades, weapon attachments, treasures) gets a last command, **Give to <partner>**: the item leaves your case and goes into your partner's, wherever they are. What does not fit in their case comes back to yours; nothing is ever lost. Key items, weapons and knives stay with you |
| **One Ashley for both** | There is only one Ashley in the shared world. She starts with the host: she follows the host's player, and in the partner's game she is right there with the host too, walking, running and animating the same way (every animation of hers, not only walking). **Tap Alt** (or the panel's button) and she goes to the other player: from then on she follows them, in both games. Either player can tap it, with 5 s between two switches. She does not change hands while kidnapped, down or hiding, or while the other player is in a cutscene. Taken over far away, she is brought next to her new player. There is never a second Ashley: in the game that does not run her she only appears where the shared one is, and any other Ashley that shows up in either game is removed |
| **What one completes, both complete** | An item one player places in a slot appears there in the partner's game too and the lock opens for both; a puzzle one solves is solved for both (with its sequence on screen); levers, mechanisms and scripted events play for both. Those sequences run in the partner's game without handing out their items again or taking items from them. The objective on screen is the more advanced of the two. A boss killed in one game (El Gigante) dies in the other too |
| **Key items exist once** | Whoever picks up a key item keeps it, and it disappears from the partner's world. Pickups are confirmed by the game's own "item obtained" flag |
| **One shared world** | The story progress lives in the game's scenario flags (objectives, map reveals, doors unlocked, items taken, events seen) and its gimmick table (locks, keys used, levers, shutters, puzzles). Every flag the game turns on, whatever turned it on, is applied in the partner's game through the game's own setter within a fraction of a second, both ways. A flag going back off (a checkpoint reload) never undoes the partner's world |
| **Cutscenes for both** | A cutscene or movie one player's game starts plays in the partner's game too: the game's own description of it (camera, flags it sets, the scripted sequence it continues, where it puts the players) is sent and played by the partner's game exactly as if their player had started it, **at once, wherever the partner is**: a partner who was far away watches it right away and is brought next to you when it ends. Never twice: a cutscene that save already played is skipped. **Skipping it skips it for both** (in the partner's game the same way its own skip button does) |
| **Scripted events for both** | When a player walks into an area that starts an event (a camera shot, a voice line, objects that move, a scene), the partner's game runs the same event with its own player if they are nearby. A partner far away gets it from their own game when they walk in, as always. Only pure events travel: doors, items, traps, deaths, saves and tutorials never run for the other player |
| **Doors that match** | A door your partner opens swings open in your game at once and stays open while they are in it, and closes in both games when neither of you is - normal and kick-open doors (RE4's own two-player door slots), automatic and elevator doors, timed shutters and big double doors |
| **Levers, big doors, valves, shelves, carts for both** | When a player pulls a lever, turns a valve, opens a big door, moves a shelf or pushes the cart out of the way, the object moves in your partner's game too, with its in-game camera shot - no more door that stays shut or shelf that stays in the way on the other screen. If your partner is far away, it is already open/moved when they get there |
| **Traps for both** | A bear trap that bites someone or is shot shut snaps shut in your partner's game too (with its own snap and sound), and opens again there when a villager re-arms it. A sensor bomb (laser trip mine) that is shot or set off goes off in both games - the explosion hurts whoever stands next to it in each game. Traps your partner already closed or set off before you joined are closed or gone in yours |
| **Breakables and animals** | Break a crate, a barrel or a pot, shoot a crow: it breaks or dies in your partner's game too (animals fall dead, they don't vanish), and stays that way for an area they only reach later. Crows, chickens, fish, bats and rats near both players move as in the host's game: the same crow takes off and lands the same way on both screens |
| **Invincibility for testing** | *Options → Testing → Invincibility*: while either player has it on, neither takes damage, is grabbed, dies or gets a game over (also playing alone). For trying things out |
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
* **The client as a second player (0.10, not run in the game yet).** RE4's enemy AI only fights
  characters of its own game; the host's enemies fight the client's character because the mod
  gives it a player context of the host's game, a target marker, its damage colliders and a
  place in the game's hit system (docs/RESEARCH.md 3.25). Whether every enemy kind behaves well
  against it is unproven: *Diagnostics* shows each piece (`partner_context`, `partner_seen`,
  `partner_hits`, `partner_heard`, `partner_damage`, `partner_fatal`) and the client's model can
  be taken out of the fight with *Options → …see, hear, chase and attack your partner too*.
  Bosses go for the client when their own hate puts the client first; attacks of theirs that
  read "the player" directly still aim at the host.
* Grabs on the client (0.10.1, not run in the game yet): the client's character is held by the
  enemy's copy in the client's game; if it freezes in a pose, untick *...may grab your partner*
  on the client (then only the grab's damage reaches it). A **parry** by the client lands in the
  host's game one round trip after the client's screen shows it.
* The host's shots and blows pass the client's character; your shots never hurt your partner.
* Enemies near the client only exist where the host's game has loaded them: a client far ahead
  of the host meets no enemies until the host's game spawns them.
* Ragdolls, effects the enemies spawn themselves and grab reactions are simulated in each game
  on its own and can look different.
* Traps (0.9.1, not run in the game yet): bear traps and sensor bombs are in sync. A bear trap
  a villager places appears only in the game that runs that villager; spike walls, drills,
  falling floors and laser rooms run in each player's game when that player walks in.
* Mechanisms (0.9.1, not run in the game yet): a lever, big door, valve, shelf or cart moved by
  one player moves in the other's game with its camera shot. An object your partner is not near
  is set in its final position when its area loads instead.
* Your partner's hits and kills make the enemy react and die in your game, but never burst its
  head or break a limb there (the break effect of a replayed hit crashed the game); your own
  hits mutilate as always. The reaction is the one of your partner's weapon and of the body part
  they hit (0.9.1, not run in the game yet).
* Scoped weapons (0.9.1, not run in the game yet): your partner's rifle is only a model in your
  game - its scope never renders its view on your screen.
* The host's world decides which enemies exist (0.9.1, not run in the game yet): an enemy alive
  for the host that the client's game never spawned - the client's save had it dead, or only the
  host triggered it - appears for the client too, where the host's is. Enemies the game creates
  on the fly (no level identity) still appear only where they spawned.
* One Ashley for both (0.9.1, not run in the game yet): in the game that does not run her she
  cannot be grabbed, attacked or hurt (that game's enemies leave her alone), and your shots
  there do not hurt her. Doors and jumps that need her nearby only work for the player she
  follows. Alt also zooms a scope: a tap while aiming does not switch her (*Options* can change
  the key).
* What one completes, both complete (0.9.1, not run in the game yet): a gimmick that only reads
  its state when its area loads shows the partner's change after that area reloads, and a
  puzzle the partner is still working on (pieces moved, not solved) is not shown live.
* The partner's model does not collide with you. In the host's game it is a target of the
  enemies (above); in the client's game it is only a visual copy (your bullets pass through it).
* Thrown grenades, bullet impacts and blood on enemies happen only in the thrower's/shooter's
  game. Sounds the engine plays internally (outside the reflected `trigger` calls) may not be
  replayed; *Diagnostics* counts what gets through.
* Joining late (0.11.2, not run in the game yet) loads on its own wherever you are: from the
  title screen, the main menu or Join Game your game loads your co-op save (else your latest)
  into the host's chapter, at the host's place; with no save at all a new game starts at the
  beginning of the host's chapter part (Standard difficulty unless the host's lobby chose
  another). Playing another chapter, or a part of the host's chapter far away, your game reloads
  that save in game the way the pause menu's *Load Game* does and you appear next to the host -
  progress since that save is not kept. Following the host into the next chapter works the same
  way. Both can be switched off in *Options → Joining and travelling*.
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
matching tag (`git tag v0.10.0 && git push origin v0.10.0`). CI builds the MSVC zip, checks the
versions and attaches `re4coop-v0.10.0.zip` + `.sha256` to a draft GitHub Release for you to
publish.

## Repository layout

```
plugin/src/net/        UDP transport: handshake, ordered + unordered reliable lanes, unreliable, timeouts
plugin/src/lua_api.*   `re4coop_net` Lua bindings (plain Lua C API)
plugin/src/plugin_main.cpp  REFramework plugin entry points
plugin/tests/          native transport tests + Lua test runner
lua/reframework/autorun/re4coop.lua   entry script (REFramework autoloads it)
lua/reframework/autorun/re4coop/      protocol, session, enemy_net, partner_target, animal_sync, items_sync,
                                      drop_sync, gate, flag_sync, gimmick_sync, object_sync,
                                      cutscene_sync, trigger_sync, door_sync, trap_sync, mechanism_sync, give_sync, save_sync, travel,
                                      pause_policy, interp, config, ui, overlay, perf (profiler,
                                      crash breadcrumbs), hookguard (no hook on a shared stub body),
                                      game (RE4 adapter: player, prefabs, sound mirror, HP,
                                      pickups), game_enemies (enemies, puppets, hits), game_partner (the
                                      client as a second player in the host's game), game_world (flags, gimmicks, breakables,
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
| Stutter or low frame rate in co-op | *Diagnostics → Performance* shows the mod's cost per frame and its busiest part; send `reframework/data/re4coop_perf.json`. *Options*: lower *Character pose updates per second*, or untick *Client: the host's enemies stand and move where they are in the host's game* or *Animals near the client…* |
| Panel says `re4coop_net.dll is not loaded` | The DLL isn't in `reframework/plugins/`, or REFramework is too old. Check `re2_framework_log.txt` in the game folder |
| "could not reach host" | Wrong IP or port, the host didn't click *Host game*, or a firewall is blocking it (see above). Both must be on the same network or VPN |
| "Partner runs re4coop X…" | Install the same release on both PCs |
| No partner model, but connected | The partner is on the title screen or loading, or in a different chapter (the HUD warns you). Check *Options*. *Diagnostics* → *Partner model* says what was built (`prefab` or `mirror`) or why it failed |
| Partner model looks wrong or misbehaves | Tick *Build partner from meshes only* in *Options* (skips the body prefab). Then click *Write research dump* and open an issue with `reframework/data/re4coop_typedump.json` and `re4coop_research_log.json`: they list your character's objects, meshes and joints |
| Enemies not syncing | Open *Diagnostics*. `enemy_uid` must read `[ok] N of N enemies have a level identity`, and *enemy sync* shows the pairs made by ID and how many the host numbered for the client. If `enemy_uid`, `enemy_set_hp`, `enemy_list`, `enemy_puppet`, `enemy_motion`, `hit_values`, `hit_apply` or (after a partner's kill) `enemy_erase` show `[--]`, click *Write research dump* and send `reframework/data/re4coop_typedump.json` and `re4coop_research_log.json` |
| Enemies the partner killed still appear | *Diagnostics → enemy deaths* counts the dead in the shared world. On the host, `enemy_backups` must read `[ok]` after the partner joined. Untick *Enemies your partner already killed never appear in your game* to have them die visibly instead |
| Teleport prompt shows too often or too late | *Options → Progression*: distance and seconds sliders, or switch it off |
| A menu still pauses the game in co-op | *Options → Pauses*: tick *Also refuse pause requests*. *Diagnostics* lists which pause types were neutralised |
| Something in the shared world misbehaves (a door, a flag that keeps flipping, a cutscene, an event) | Switch that part off in *Options → Shared world* and keep playing. *Diagnostics* shows the counters for flags, cutscenes, event triggers, gimmicks and objects; flags that flip back and forth are muted automatically |
| A cutscene or an event shows for only one player | *Diagnostics*: `flag_hooks`, `cutscenes`, `cutscene_hooks`, `triggers` and `trigger_hooks` must be `[ok]`. The line *seen in our game* must count up when you set one off; *cutscenes* / *event triggers* say what was sent, played, refused or missed (a partner more than 40 m away runs an event when they walk in themselves) |
| Enemies jitter, freeze in a pose or slide | *Options → Enemies and animals*: raise *Enemy smoothing* a little; untick *…with their own animation state machine switched off*; then *…and play their animation*; then *…stand and move where theirs are* (each game then moves its own copies; HP, hits and deaths still sync). Tell us which one fixed it |
| The host's enemies ignore the client, or never hurt it | On the **host**, *Diagnostics* must show `partner_context`, `partner_seen` and `partner_hits` `[ok]` and *client as a target: ON* while the client is in the host's area (its model built from the body prefab: not *Build partner from meshes only*). `partner_damage` counts the enemy hits sent; on the client, *hits from the host's enemies* counts what it took or dodged. *enemy finishers of the client* counts finishers run or refused |
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
