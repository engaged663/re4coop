# Wire protocol

Two layers: the **transport** (C++, `plugin/src/net`) moves datagrams between exactly two
peers. The **game messages** (Lua, `re4coop/protocol.lua`) ride inside transport payloads.
All integers are little-endian.

## Transport (network protocol version 2)

Every datagram starts with a 10-byte header:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `0x50433452` (`"R4CP"`) |
| 4 | 1 | protocol version (`2`) |
| 5 | 1 | packet type |
| 6 | 4 | session token (0 until accepted) |

Packets whose magic doesn't match are ignored. After the handshake, packets from the wrong
address or with the wrong token are ignored too.

| Type | Name | Body | Notes |
|---|---|---|---|
| 1 | ConnectRequest | `u32 nonce, str name, str password` | Client → host every 250 ms until answered (10 s timeout) |
| 2 | ConnectAccept | `u32 nonce, str host_name` | Header token = the new session token |
| 3 | ConnectReject | `u32 nonce, u8 reason, str message` | reason: 1 full, 2 bad password, 3 version mismatch. Clients read it whatever its version |
| 4 | Disconnect | `u8 reason` | 1 requested, 2 timeout, 3 kicked. Sent 3× on leave |
| 5 | Ping | `u32 id, u64 time_us` | Every 0.5 s |
| 6 | Pong | `u32 id, u64 time_us` | Echo, used for RTT |
| 7 | Unreliable | `u16 seq, payload` | Delivered as is. `seq` is only used to count reordering |
| 8 | Reliable | `u16 seq, payload` | The ordered lane. Acked. First retransmit after `clamp(2·RTT + 10 ms, 50 ms, 1 s)`, then each packet's own timeout doubles with every resend (up to 1 s). Delivered once, in order (4096-entry reorder window) |
| 9 | Ack | `u8 count, u16 seq × count` | Selective acks for the ordered lane, batched per network tick |
| 10 | ReliableUnordered | `u16 seq, payload` | The unordered lane (own sequence numbers): acked and retransmitted like Reliable, delivered once as soon as it arrives, never waiting for earlier packets. Used for ACTIONS |
| 11 | AckUnordered | `u8 count, u16 seq × count` | Acks for the unordered lane |

`str` = `u8 length` + bytes (≤ 255). Maximum datagram: **1200 bytes** (below the MTU of VPN
tunnels such as ZeroTier, Tailscale or Hamachi, so no datagram is split into IP fragments).
Maximum message payload: **1188 bytes** (`re4coop_net.max_payload()`). Version 1 used 1400 /
1388 bytes and had no unordered lane.

Session rules:

* The host accepts one partner. A second machine gets `Full`. The same IP with a new nonce (the
  partner restarted the game) replaces the old link.
* 10 s without any packet = disconnected. The host returns to listening. The client goes idle.

## Lua API (`re4coop_net`)

| Function | Returns |
|---|---|
| `host(port, name, password)` | `true` or `nil, err` |
| `join(address, port, name, password)` | `true` or `nil, err` (the result arrives later through `poll`) |
| `stop()` | Disconnects politely and stops the thread |
| `send(bytes, reliable[, unordered])` | `true` or `nil, err`. `unordered` (with `reliable`): the unordered lane |
| `poll([max])` | Array of `{type="connected"\|"disconnected"\|"rejected"\|"message", data, reliable, peer, name}` |
| `state()` / `role()` | `"idle"\|"listening"\|"connecting"\|"connected"` / `"none"\|"host"\|"client"` |
| `stats()` | Table: `rtt_ms, peer, peer_name, bytes_sent, bytes_recv, resends, reliable_in_flight, out_of_order, unordered_duplicates, …` |
| `local_addresses()` | Array of this PC's LAN IPv4 addresses |
| `time()` | Monotonic seconds (`os.clock` is CPU time, so don't use it for networking) |
| `max_payload()`, `version()` | `1188`; `"0.11.3", 2` |
| `new_session()` | An independent session object with the same methods (tests/tools) |
| `window_focused()` | Whether a window of this process is the foreground window (true off Windows): the Ashley key only counts while the game has the focus |

## Game messages (game protocol version 15)

Mod 0.11.3 keeps version 15: a CUTSCENE_SKIP is applied only once the receiving game could skip
that cutscene itself, and a cutscene is one cutscene whatever camera kind (movie or timeline)
reported it ([RESEARCH.md](RESEARCH.md) section 3.36).

Mod 0.11.2 keeps version 15 too: a client joining late now loads straight into the host's
place ([RESEARCH.md](RESEARCH.md) section 3.34), from the PLAYER messages it already gets (the
host's chapter, stage, position and rotation while it plays - not dead, not in a cutscene).

Mod 0.11.1 keeps version 15 (a 0.11.0 partner can play with it). PLAYER flag 2 (CUTSCENE) is
now also set while the sender's game changes chapter, is over or reloads (its own transitions,
[RESEARCH.md](RESEARCH.md) section 3.33): the partner treats that like an event (no wait at a
transition, no teleport to it, no enemy targeting it).

Version 15 (mod 0.11.0) adds the lobby in the game's main menu and the synchronized start
(`lobby.lua`, [RESEARCH.md](RESEARCH.md) section 3.31): LOBBY_SETTINGS (53) the host's choices,
LOBBY_PLAYER (54) each player in the lobby, LOBBY_START (55) the agreed game, LOAD_STATE (56)
how far each game is with loading it, LOAD_GO (57) both have loaded.
Version 14 (mod 0.10.1) adds parries and grabs of the client's player in the host's game:
ACTION_SIGN (49) carries a host enemy's warning to the client's character (the parry/dodge
prompt), ENEMY_PARRY (50) the client's parry of a host enemy, PLAYER_GRAB (51) a host enemy's
hold on the client's character, GRAB_ESCAPE (52) the client breaking free; PLAYER_DAMAGE has
flag 4 (a grab) and the grab's priority. See [RESEARCH.md](RESEARCH.md) section 3.26.
Version 13 (mod 0.10.0) gives every enemy to the host: nothing changes hands any more, and the
client's player is a second player in the host's game (`partner_target.lua`, `game_partner.lua`).
ENEMY_STATE travels host → client only and carries, per enemy, what it says about the client's
character (partner info: the finishers it allows, whether it targets it) and the finisher type
it offers; ENEMY_FATAL (46) replaces ENEMY_CLAIM (37, retired): a finisher of the client's player
the host runs; PLAYER_NOISE (47) carries the noises the client's player made, which the host's
enemies hear; PLAYER_DAMAGE (48) carries a hit the client's character took in the host's game.
ENEMY_DEATH has flag 16 (the client's kill); ENEMY_HIT flag 4 (bounce) is retired.
Version 12 (mod 0.9.1) carries Ashley's animation in full: ASHLEY has her motion's bank variant
and up to 8 layers with blend rate, joint mask and blend mode; ASHLEY_BANKS (45) carries the
dynamic motion banks her motion has loaded.
Version 11 (mod 0.9.1) adds Ashley for both players (`ashley_sync.lua`): ASHLEY (41),
ASHLEY_OWNER (42) and ASHLEY_SWITCH (43); and objectives for both (`purpose_sync.lua`): PURPOSE
(44).
Version 10 (mod 0.9.1) makes player events happen in both games: FLAGS only carries flags that
turned on, plus trigger-kind flags that fired (PULSE); FLAG_WORDS changes only carry bits that
turned on; CUTSCENE carries the game's own `ClapperboardMediator.PayloadPlay` (camera, flags,
data owner, next portrayal, movie placements) instead of a timeline event ID and a method
name; TRIGGER (32) is new: a level event trigger the sender's player set off; CUTSCENE_SKIP
(33) is new: the sender's player skipped a cutscene.
Version 9 (mod 0.9.0) replaced the enemy sync with a new one (`enemy_net.lua`): every enemy has
one **owner**, the game that runs it, and an ownership **epoch** that the host bumps whenever it
gives the enemy to the other game. The owner sends the enemy's full state (ENEMY_STATE, 27);
hits the other player lands travel to the owner with every value of the game's DamageInfo
(ENEMY_HIT, 28); the owner announces the death with its killing hit (ENEMY_DEATH, 29); the host
assigns owners (ENEMY_OWNER, 30) from what the client has (ENEMY_ROSTER, 31). ENEMY_GRAVE (25)
stays. Retired: ENEMY_SNAPSHOT (4), ENEMY_DAMAGE (5), ENEMY_DEAD (6), the old ENEMY_HIT (15) and
ENEMY_CLIENT (17).
Version 8 (mod 0.8.0) paired enemies by the game's own identity (uid) and let the host run every
enemy; it added ENEMY_GRAVE (25) and ANIMALS (26).
Version 7 (mod 0.7.0): OBJECTS up to 50 events (everything fits the 1188-byte payload), ACTIONS
travel on the unordered lane, and ITEM_DROPPED is retired (each player rolls their own loot).

The first byte is the message type. Formats use Lua `string.pack` notation.

| Type | Name | Channel | Direction | Format |
|---|---|---|---|---|
| 1 | HELLO | reliable | both, on connect | `<B I2 s1 s1 s1 B`: type, game protocol version, mod version, player name, chapter/area, flags (1 = reply requested) |
| 2 | PLAYER | unreliable, 20 Hz | both | `<B d fff ffff ff B I4 i4 i4`: time, position, rotation quaternion (x,y,z,w), HP, max HP, flags (1 dead, 2 cutscene, 4 aiming, 8 has stage, 16 has chapter, 32 waiting at a transition, 64 invincibility asked for: both players are invincible), area hash, `chainsaw.StageID` (valid with flag 8), `chainsaw.ChapterID` (valid with flag 16) |
| 3 | *(retired)* | | | SKELETON in protocols 1–3 (the stick-figure ghost) |
| 4 | *(retired)* | | | ENEMY_SNAPSHOT in protocols 1–8 |
| 5 | *(retired)* | | | ENEMY_DAMAGE in protocols 1–8 |
| 6 | *(retired)* | | | ENEMY_DEAD in protocols 1–8 |
| 7 | CHAT | reliable | both | `<B s2`: text (≤ 512 bytes) |
| 8 | NOTIFY | reliable | both | `<B B s1`: code (1 died, 2 revived, 3 teleported, 4 info), text |
| 9 | ITEM_TAKEN | reliable | both | `<B I4 fff B i4 i4 B B i4`: item ID, position, flags (1 has ContextID, 2 it was the only copy in the sender's scene, 4 has stage), ContextID of the `chainsaw.DropItem` (level IDs only), its `chainsaw.StageID`. The receiver removes its copy of that key item |
| 10 | FRAG | reliable | both | `<B I2 B B` + bytes: message id, piece index (1-based), piece count, a slice of a reliable message longer than one datagram. Pieces arrive in order and are concatenated |
| 11 | AVATAR | reliable (fragmented) | both | see below: how the sender's character is built |
| 12 | GEAR | reliable | both | see below: the weapons the character carries |
| 13 | POSE | unreliable, 30 Hz | both | see below: root placement, every joint's local rotation, weapon placement |
| 14 | ACTIONS | reliable, unordered lane | both | see below: sound/effect calls and shots to replay |
| 15 | *(retired)* | | | the old ENEMY_HIT (protocols 5–8: tracers and a cosmetic replay) |
| 16 | *(retired)* | | | ITEM_DROPPED in protocols 4–6 (the host's roll spawned on the client); still decoded, ignored |
| 17 | *(retired)* | | | ENEMY_CLIENT in protocols 6–8 |
| 18 | FLAGS | reliable | both | `<B B` + n × (`guid` + `<B`): scenario flags that changed in the sender's game (≤ 64 per message), with their value: 1 on, 2 pulse (a trigger-kind variable fired once: the receiver fires it with `setTrigger`). Version 10 senders never send 0 (off): a flag going off is a reload, and receivers ignore it |
| 19 | FLAG_WORDS | reliable | both | `<B I2 B B B B` (sync id, mode, chunk, chunks, item count) + per item `<s1 I2 I2` (group name, first word, count) + words. Mode 1 = full copy: `<I4` words. Mode 2 = changes: `<I2 I4 I4` (word index, bits set, bits cleared; version 10 sends and applies only bits set) |
| 20 | GIMMICKS | reliable | both | `<B I2 B B B B` (sync id, mode, chunk, chunks, count) + per gimmick: `ctx` (`<i4 i4 B B>`: group, index, kind, category), `<s1` attribute bytes, `<B` + n × `<I4 I4` (trigger save ID, done), `<B` detected, `<B` + n × (`<B` kind, `<f` or `<I4` value) accessory values. Mode 1 = the whole table, 2 = records that changed, 3 = records that appeared (applied only where the receiver has no record of that gimmick) |
| 21 | OBJECTS | reliable | both | `<B B` + n × (`guid` + `<B i4`): scene object (GameObject GUID), event (1 destroyed, 2 state changed), value (the `_Routine` it ended in, or -1) |
| 22 | CUTSCENE | reliable | both | `<B B i4 i4 I4 I4 i4 i4 fff B>`: camera type (1 timeline event, 2 movie), camera ID, screen, data owner code (ContextID code of the level object whose scripted sequence continues when it ends; `0xFFFFFFFF` none), end portrayal (that next step), chapter, stage, position where it started, flags (1 = started by the sender's game); then start flags and end flags, each `<B>` count (≤ 48) + n × `<i4 i4>` (flag group index, bit index: `ScenarioFlagManager.FlagInfo`); then `<B>` count (≤ 8) + n × `<i4 ffff B B B>` player placements of a movie (`PlayerCoordSetting.Pack`: player kind, position, Y rotation, reset camera, NPCs only, players only). The receiver builds the same `PayloadPlay` and plays it through its own `ClapperboardMediator.procPayloadPlay`, unless its save already played it (`checkHasDone`) |
| 23 | WORLD_REQUEST | reliable | client → host | `<B I2 B`: sync id, what (1 flags, 2 gimmicks, 4 enemies, 8 objects) |
| 24 | WORLD_DONE | reliable | host → client | `<B I2 B I4 I4`: sync id, what, flag groups sent, gimmicks sent. Follows the FLAG_WORDS / GIMMICKS / OBJECTS of a full transfer (the ordered lane keeps them in order). A request with sync id 0 (enemies only, from a client without a world adapter) gets no WORLD_DONE |
| 25 | ENEMY_GRAVE | reliable | host → client | `<B B B I2` + n × `<I4>`: chunk, chunks, count (≤ 290), uids. Every enemy dead in the host's world: the deaths it saw, the client's kills of enemies it had not loaded, and the enemies its save has eliminated (`CharacterManager.CharacterBackupDB`). Sent after a WORLD_REQUEST with bit 4 (joining, the client's game reloading), once the host has read its save (a few ticks). The first message replaces what the client knew |
| 26 | ANIMALS | unreliable, 10 Hz | host → client | `<B d B B B` + n × (`guid` + `<fff I4 i4 I4 I4 f B>`) (49 B): time, chunk, chunks, count (≤ 23); then the host's animals (`chainsaw.GmAnimal`: crows, chickens, fish, bats, rats) within 50 m of both players, nearest to the client first, at most 24: GameObject GUID, position, packed rotation, `_Routine`, motion bank, motion ID, motion frame, flags (1 has animation, 2 dead: its routine reached Die/Dead, 4 has routine). The client's copies follow them with their own AI off the game's update; a dead one dies in the client's game with its own death. Animal kills travel as OBJECTS |
| 27 | ENEMY_STATE | unreliable, 20 Hz | host → client | `<B d B B B>` (time, chunk, chunks, count) + n entries, packed into as few datagrams as fit. Entry `<I2 B I2 I4 I4 fff I4 hhh f f I2 B B B>` (48 B): net id, epoch, flags (1 alive, 2 has uid, 4 hidden: the host's game does not draw it, 8 has spawn point), uid, kind hash, position, packed rotation (full quaternion), velocity (cm/s), HP, max HP, hit ack (the last of the client's hits the host ran on this enemy), partner info (what the enemy says about the client's character in the host's game: 1 a kick or grab finisher is allowed, `EnemyHeadUpdater.isEnableFatal`; 2 a knife finish, `isEnableKnifeFatal`; 4 a stealth kill, `isEnableStealthKill`; 8 its current target is the client's character; 128 known: the host asked it. Finishers are asked of enemies within 8 m of the client's character, the target of those within 60 m), finisher type (`PlayerDefine.FatalType` it offers the client, `getAvailableFatalType`), layer count; then `<fff>` spawn point (flag 8: enemies without a uid), then per animation layer (≤ 3) `<I4 I4 f f>`: motion bank, motion id, frame, speed. Every enemy the host runs, also those the client has not loaded; always at least one message. The client's copies follow them: position and rotation every frame, animation corrected when a layer plays another motion or drifted more than 4 frames, HP, visibility. The client's copy of an enemy shows the finisher prompts its partner info allows (none without bit 128 or without a state younger than 2 s) |
| 28 | ENEMY_HIT | reliable | both | `<B I2 B B I4 I4 fff f f I2>` + values: net id (0 = not paired), epoch, flags (1 apply: the host runs the hit, 2 critical, 4 retired (bounce, protocols 9–12), 8 lethal in the sender's game, 16 has uid), uid, kind hash, identity position (spawn point), damage, the enemy's HP before the hit in the sender's game, sequence number; then the hit's values `<B>` count (≤ 64) + per value `<I4 B>` (FNV-1a of the `chainsaw.HitController.DamageInfo` field name, tag) and the value by tag: 1 `i4`, 2 `f`, 3 `B` bool, 4 `fff` vector, 5 `I4`, 6 `i8`, 7 `d`. Client → host, flag 1: every hit the client's player lands on a host enemy (paired, or with a uid); the host runs it through `HitController.callbackDamageHit` with these values and the client's character as the attacker (the same damage and reaction, and the enemy turns on the client); without values it subtracts the damage. A plain damage report (an explosion hurt the client's puppet) is a hit with flag 1 and no values. Host → client, without flag 1 and without values: a hit the host's player landed, for the shot tracer |
| 29 | ENEMY_DEATH | reliable | host → client | `<B I2 B B I4 I4 fff I4>` + values: net id, epoch, flags (1 has uid, 2 reset, 4 erased, 8 has the killing hit, 16 the client's kill: the killing hit or finisher was the client's player's, within 3 s and after the host's own last hit), uid, kind hash, position and packed rotation where it died, then the killing hit's values (as in ENEMY_HIT). An enemy that died in the host's game (also a corpse the host finds); the client puts its copy there and kills it with the same hit, or removes it later (graveyard). Flag 2 (net id 0): the host reloaded a checkpoint: forget every death it reported, and its net ids |
| 30 | ENEMY_OWNER | reliable | host → client | `<B B>` count (≤ 95) + per entry `<I2 B B I4 f>`: net id, epoch, owner (0 host; 255 retired: the host no longer has that enemy and its number is free; 1, the client, is never sent since protocol 13), uid, the host's HP of the enemy when it was numbered (0 = none). The host's numbering of its enemies: epoch 0 until the client reports a copy (ENEMY_ROSTER), then 1, with the host's HP - lowered first to the copy's if the client's player hurt it before the host's level spawned it. A retired enemy's copy waits on the client, still and unseen |
| 31 | ENEMY_ROSTER | unreliable, 5 Hz | client → host | `<B d I2>` (time, count ≤ 160) + per entry `<I2 B f>`: net id, flags (1 alive; 2 local run, never set since protocol 13), HP. The host enemies the client has a copy of; at least one message. The host numbers only these, and reads the animation of these only |
| 32 | TRIGGER | reliable | both | `<B c16 I4 B B i4 i4 fff>`: the trigger's GameObject GUID (scene file), `InteractTrigger.get_Hash` (hash of its name), trigger type (1 area), flags (1 play once, 2 set off by the player's head GameObject), chapter, stage, the sender's position. An event trigger (portrayal, camera shot, mini demo... never a gimmick, item, death or save) the sender's player walked into. The receiver runs the same trigger (`InteractHolder.findTrigger` on `via.Scene.findGameObject(guid)`) with its own player if that player is within 40 m in the same stage, or gets there within 20 s; otherwise it leaves it to its own game |
| 33 | CUTSCENE_SKIP | reliable | both | `<B B i4>`: camera type (1 timeline event, 2 movie), camera ID. The sender's player skipped that cutscene (its `PlayWork.DoneSkip` turned on). The receiver sets `InputSkip` on its PlayWork of the same camera, now or when it starts playing there within 90 s; its game skips it if it can be skipped |
| 34 | DOORS | reliable | both | `<B B>` count (≤ 60) + n × (`guid` + `<B B>`): door GameObject GUID, flags (1 open, 2 held open by the sender's player), its first attribute byte (`GmDoor.Attr0Bit`: open, side B, opened by no one). Doors within 25 m of the sender's player whose state changed, and doors it walked away from (held = 0). The receiver sets the same open bits on its door and its Guest keep-open slot (`GmDoor.recvGmParam`) |
| 35 | ITEM_GIVE | reliable | both | `<B I4 I4 i4 i4>`: sequence number, ItemID, count, durability (-1 none). An item the sender's player gave the receiver from the attache case (already out of the sender's case). The receiver makes it (`ChainsawGuiUtil.generateItem`) and puts it in its case (`CsInventoryController.add`) once its case is closed and it is playable |
| 36 | ITEM_GIVE_RESULT | reliable | both | `<B I4 i4>`: sequence number, how many did not fit. The giver puts those back into its own case |
| 37 | *(retired)* | | | ENEMY_CLAIM in protocols 10–12 (a finisher of the client handed the enemy to the client's game) |
| 39 | TRAPS | reliable | both | `<B B>` count (≤ 60) + n × (`guid` + `<B B>`): trap GameObject GUID, kind (1 bear trap `GmLegHoldTrap`, 2 sensor bomb `GmSensorBomb`), event (1 fired: it closed / went off - the receiver's plays it; 2 re-armed: a bear trap opened again; 3 spent: closed / gone before - set without playing it, for a joining partner or a report older than 20 s). Traps within 60 m of the sender's player whose state changed |
| 40 | MECHANISMS | reliable | both | `<B B>` count (≤ 50) + n × (`guid` + `<B I4>`): gimmick GameObject GUID, kind (1 a scripted sequence: `PortrayalSettings.call(key)`; 2 a pushed cart or shelf: `GmPushMove`), key (the sequence's key hash; 0 for a push). A lever pulled, a big door, valve or shelf moved in the sender's game; the receiver plays the same sequence on the same object (`call(key, null, null)`), or moves the pushed object (`MotMove`, flag). Never sent back for what a MECHANISMS started |
| 41 | ASHLEY | unreliable | both | `<B d B B fff I4 i4 i4 I4 B>` time, ownership epoch, flags (1 present: the sender's game has an Ashley; 2 owner: the sender's game runs her; 4 alive; 8 kidnapped; 16 busy: she cannot change hands - kidnapped, down, hiding, on a gimmick - or the sender's player cannot take her: cutscene, down; 32 hidden), position, packed rotation, HP, max HP, her motion's bank variant (`via.motion.Motion.TargetBankType`), layer count (≤ 8), then per layer `<I4 I4 f f f I4 B>` motion bank, motion id, frame, speed, blend rate (-1: none), joint mask (0xFFFFFFFF: none), blend mode (0xFF: none). The owner sends her full state ~20 Hz; the other game only its presence (no layers) every 0.5 s. Nothing while the sender's game loads |
| 42 | ASHLEY_OWNER | reliable | host → client | `<B B B f B B>` owner (0 host, 1 client), ownership epoch, seconds until she may switch again, reason (0 switched on a player's request, 1 switched because the game running her has had no Ashley for 5 s while the other has one, 2/3/4 refused: cooldown / she is busy / the other game has no Ashley or its player cannot take her, 5 the current owner repeated: to a client that just connected or asked about an old epoch), who asked (0 host, 1 client) |
| 43 | ASHLEY_SWITCH | reliable | client → host | `<B B>` ownership epoch the client knew. The client's player tapped the switch key: Ashley should go to the other game than the one running her at that epoch. The host switches (or refuses) and answers with ASHLEY_OWNER; a request about an older epoch is answered with the current owner |
| 45 | ASHLEY_BANKS | reliable | owner → other | `<B B B>` ownership epoch, count (≤ 64), then per bank `<I4 I4 I4 i4 B s2>` bank ID, bank type, bank type mask bit, order, flags (1 OverwriteBankID, 2 OverwriteBankType, 4 OverwriteBankTypeMaskBit), motlist path. The dynamic motion banks (`via.motion.DynamicMotionBank`) Ashley's motion has in the owner's game: sent when they change, after each switch and every 10 s; may need FRAG pieces. The other game's puppet loads the same motlists and adds the banks it lacks (`MotionController.addDynamicMotionBank`), and takes away the ones it added that the owner no longer has |
| 44 | PURPOSE | reliable | both | `<B I4 i4 c16 f f B>` purpose ID (`chainsaw.gui.PurposeID`; the chapter is ID / 100, as in ChapterID's chapter part), priority, message GUID (16 raw bytes), display time, delay, flags (1 request mediate). The sender's current objective, when it changes and every 20 s. A receiver whose own objective has a lower priority, in the same chapter, takes it (`PurposeManager.updateMainPurpose`) |
| 38 | SAVE | reliable | both | `<B B>`: kind (1 autosave, 2 the player's own save). The sender's game started a save (`SaveFlowController.start`); never sent for a save made because of a SAVE. The receiver's game saves too through its own save flow once it can (playing, no cutscene or loading screen, save system idle; a client also holds the host's world), unless it saved within the last 10 s: the host into its autosave (slot 0), the client into its co-op slot (default 20) |
| 46 | ENEMY_FATAL | reliable | client → host | `<B I2 B I4 I4 B i4 fff f>`: net id, epoch, uid, kind hash, kind (1 kill: `requestFatalKill`, a knife finish or stomp; 2 stealth: `requestStealthKill`; 3 normal: `convertNormalFatalAction`, a kick or a grab finisher), finisher type (`PlayerDefine.FatalType` of kind 3), position and yaw of the client's player. The client's player started a finisher on its copy of a host enemy: the copy's AI head answered the prompt queries from the host's partner info and did nothing itself. The host asks its enemy's AI head the same, with the client's character (its stand-in player context) as the attacker; the enemy plays its side in the host's game and the result comes back as ENEMY_STATE / ENEMY_DEATH |
| 47 | PLAYER_NOISE | unreliable, ≤ 10 Hz | client → host | `<B B>` count (≤ 16) + per noise `<fff f f f f>`: position, radius, height, volume, volume lost per second. The noises (`chainsaw.SoundDetectionInfo`: shots, steps, reloads, a breaking crate...) the client's game registered for its player (`SoundDetectionManager.registerSound`). The same noise again within 0.25 s and 0.5 m (each footstep) is sent once. The host registers each in its game, made by the client's character, while that character is a target there; its enemies hear the client |
| 48 | PLAYER_DAMAGE | reliable | host → client | `<B I2 I2 B I4 I4 i4 I4 i4>` + values: sequence number, net id of the attacking enemy (0 = none or not numbered), flags (1 has uid, 2 from an enemy, 4 a grab), uid, kind hash, attack id (`AttackUserData._AttackHitDataID`, -1 none), key hash (`AttackUserData._KeyNameHash`), grab priority (`GrappleUserData._GrapplePriority`, 0 unless a grab), then the hit's values (as in ENEMY_HIT: `DamageInfo`, `AttackData` and body part values). A hit an enemy of the host's landed on the client's character in the host's game (the character itself takes nothing there). The client lands it on its own player one enemy interpolation delay later (when its copy of the enemy shows the blow), through its own player's `HitController` with the copy of the enemy as the attacker: the same attack, damage and reaction, the client's own dodge and invincibility checks included (`HitController.callbackCheckDamageHit`). Dropped while the client is dead, loading or in a cutscene, or when its option *...and their attacks on your partner hurt them* is off. A grab runs through the client's own `HitManager.hitSetting` with its copy of the enemy as the grabber. A hit of an enemy the client parried less than 1 s before is not taken |
| 49 | ACTION_SIGN | unreliable, every frame of the warning | host → client | `<B I2 B I4 I4 i4 i4>`: net id, flags (1 just timing, 2 act timing, 4 angle check, 8 has uid), uid, kind hash, sign type (`chainsaw.ActionSignType`), button (`chainsaw.ActionSignButton`). A host enemy's attack warns the client's character (`EnemyActionSignUtility.sendActionSignInfo` to it, or the enemy's armed sign while its target is the client's character, within the sign's reach). The client hands it to its own player's head (`PlayerHeadUpdater.onHitActionSign`, its copy of the enemy as the owner) one enemy interpolation delay later, every frame until the host stops repeating it for 0.15 s |
| 50 | ENEMY_PARRY | reliable | client → host | `<B I2 I4 I4 B i4>`: net id, uid, kind hash, kind (1 parry: `onParry`; 2 the press: `onParryInput`), sign type. The client's player parried its copy of a host enemy; the host runs `EnemyBodyUpdater.onParry` with the client's character on its enemy (it staggers) |
| 51 | PLAYER_GRAB | reliable | host → client | `<B I2 I4 I4 B B B I4>`: net id, uid, kind hash, held (0 let go), presses that break free (0 = unknown: the client uses 8), knife (a knife breaks free), the grab's action hash. A host enemy holds the client's character (its `<GrappleTarget>`); repeated each second while it lasts, and when it changes; at most 15 s. Applied one enemy interpolation delay later |
| 53 | LOBBY_SETTINGS | reliable | host → client | `<B I2 B B B B I2 i4 B I2 B>`: revision (changes with every choice), co-op save file (1-3), mode (0 new game, 1 continue the file's save), chapter (new game: 1-16; continue: 0 = where the save is, else the chapter to go to), difficulty (`chainsaw.CampaignManager.Difficulty`: 10 Assisted, 20 Standard, 30 Hardcore, 40 Professional), option bits (`Lobby.OPTIONS`: 1 enemies attack both, 2 one Ashley, 4 shared key items, 8 saves for both, 16 transition gate, 32 no pause, 64 giving items, 128 invincibility), the file's save: `ChapterID`, difficulty, save count, empty (1). Sent while the host's lobby screen is open, on every change and to a client that connects. A new revision makes the client confirm "ready" again |
| 54 | LOBBY_PLAYER | reliable | both | `<B B B B s1>`: in the lobby screen, ready, loadout (`Lobby.LOADOUTS` id), name. When it changes and on connecting |
| 55 | LOBBY_START | reliable | host → client | `<B I2 B B B B i4 i4>`: start id, mode, file, chapter (as in LOBBY_SETTINGS), difficulty, start point (`chainsaw.CampaignInitialSettingKey` of a new game: the chapter's start), `ChapterID` both play (the chosen chapter, or the one of the host's save). Both games start now: a new game from that start point (both the same), or the host's co-op save and the client's own co-op slot (in that chapter; without a co-op save, a new game from that chapter's start) |
| 56 | LOAD_STATE | reliable, on change and every 1 s | both | `<B I2 B B>`: start id, phase (1 starting: still on the menu, 2 loading, 3 syncing: a client taking over the host's world, 4 ready: in the map and held, 5 playing, 6 failed: the start did not happen there), progress (0-100, unused). Drives the two loaders and the hold |
| 57 | LOAD_GO | reliable | host → client | `<B I2>`: start id. Both games are ready: the client's map runs (the host's already does) |
| 52 | GRAB_ESCAPE | reliable | client → host | `<B I2 I4 I4 B>`: net id, uid, kind hash, how (1 mashing, 2 the knife). The client's player broke free; the host enemy's escape check succeeds on its next update (else its grab is undone as a rejected one after 0.5 s) |

`guid` is 16 raw bytes: the 32 hex digits of the canonical GUID string, in order. Scenario
flags are addressed by GUID in the game itself; scene objects by their GameObject GUID, which
comes from the scene file and is the same on both machines.

Enemies (protocol 13): the host's game runs every enemy, always; the client's game never runs
one. The host numbers its enemies (net ids, epoch 0, then 1 once the client has a copy) and
sends their state; the client's copies are puppets (AI head and animation state machine off).
A host enemy the client's game has not spawned within 1.5 s (and within 80 m of the client's
player) is spawned there; one the host retires waits, still and unseen. The hit values of
ENEMY_HIT / ENEMY_DEATH / PLAYER_DAMAGE also carry the attack's AttackData values (hashed
`AttackData.<field>`) and the body part and side it hit (`DamageUserData.Parts`,
`DamageUserData.PartsSide`); the host decides whether the client's hit kills
(`HitController.checkKill`). In the host's game the client's character is a second player:
while the client is in the host's area and neither is in a cutscene or loading, its model
(built from the body prefab) carries a stand-in player context, the player's target marker and
tag, its damage colliders, and a place in `HitManager`'s list, so the host's enemies find it,
hear it (PLAYER_NOISE), hate it, attack it, and their hits on it travel to the client
(PLAYER_DAMAGE). See [RESEARCH.md](RESEARCH.md) section 3.25.

Ashley: one game runs her, the host's at first (epoch 0); each new owner bumps the epoch.
Either player can ask for a switch; the host decides, so two requests at once switch once. A
switch waits `ashley_cooldown` (5 s, the host's setting) after the last one. In the other game
her AI head is off and she follows the owner's ASHLEY stream (interpolated like enemy puppets),
with the owner's bank variant and dynamic motion banks (ASHLEY_BANKS) so all her motions play.

Joining: once the client is in the host's chapter it sends WORLD_REQUEST; the host answers
with full FLAG_WORDS and GIMMICKS, the OBJECTS destroyed so far and WORLD_DONE, and then
ENEMY_GRAVE; the client applies them and then warps next to the host. A client whose game
reloads a checkpoint later sends WORLD_REQUEST again (in the host's chapter only).

Compatibility: only the `version` field of HELLO is guaranteed across game protocol versions.
A peer with a different version gets an "update both" message, and its game messages are
ignored.

### ContextIDs on the wire

`chainsaw.ContextID` is `{category, kind, group, index}` with a 32-bit code (`get_Code()`).

* **Enemy identity (uid)**: every enemy the level places is created by a
  `chainsaw.CharacterSpawnParam` whose `_ContextID` is serialized in the scene file, and the
  game uses that ID as the character's own `_ID` (and as its `SpawnerID`): `0:0:12:312` is level
  data, the same on both PCs. An enemy's uid on the wire is that ID's code. Characters created
  at runtime get `ContextID(Character, 0, 1, counter & 0x7FF)`
  (`CharacterManager.generateDynamicContextID`): group 1, never sent; those enemies are paired
  by kind and spawn point. The evidence is in [RESEARCH.md](RESEARCH.md) section 3.8.
* **Animals and breakables** are addressed by their GameObject GUID (`guid`), which comes from
  the scene file ([RESEARCH.md](RESEARCH.md) section 3.9).
* **Items**: level-placed items carry level IDs (`3:0:40210:13`, group = stage); spawned drop
  items get IDs in group 12 handed out at runtime (`2:0:12:486`). ITEM_TAKEN carries a
  ContextID only if it is a level ID.

### Quaternions

Rotations in AVATAR/POSE/ANIMALS/ENEMY_STATE/ENEMY_DEATH travel as 32 bits, "smallest three": bits 31–30 hold the index (x, y,
z, w) of the largest component, which is dropped (its sign is made positive, since q and −q are
the same rotation); the other three are 10 bits each (bits 29–20, 19–10, 9–0), mapped from
[−1/√2, 1/√2] to 0…1022 with 511 = 0. The receiver rebuilds the dropped component from unit
length. Worst-case error is about 0.25°.

### AVATAR (11)

`<B I2 s1 s1 B>`: type, revision, character id (the body object's name minus `_body`, e.g.
`ch0a0z0`), body object name, part count; then per part `<s1 s2 s2 B B s1 fff I4>`: name, mesh
path, material path, parent (0 = the body, k = part k), flags (1 follows the parent's joints by
name = SameJointsConstraint, 2 carries the main skeleton), parent joint name, local position,
local rotation (packed); then `<I2>` joint count and per joint `<I4 B>`: FNV-1a hash of the joint
name, flags (1 = its local position is animated too). The joint order is the order of POSE.

The receiver picks the body prefab from the character id
(`<_chainsaw|_mercenaries|_anotherorder>/appsystem/character/<id>/<id>_body.pfb`, checked with
`via.Prefab.get_Exist`), matches the prefab's meshes with the parts by mesh path, hides the
ones the partner does not wear and rebuilds the missing ones from mesh + material.

### GEAR (12)

`<B I2 B>`: type, revision, weapon count (≤ 4); per weapon `<s1 s2 s2 B B>`: object name (e.g.
`wp4000`, picks `.../appsystem/prefab/weapon/wp4000.pfb`), mesh path and material path (used
when no prefab is found), flags, joint count (≤ 32); then `<I4>` × joint count: joint name hashes.

### POSE (13)

Split into as many datagrams as needed; every chunk is self-contained, so a lost chunk only
holds its joints for a moment. `<B d I2 I2 B B I2 I2>`: type, sender time, AVATAR revision, GEAR
revision, chunk, chunk count, first joint (1-based), joint count. Chunk 1 continues with the root
`<fff I4 B>` (world position, rotation, flags: 1 cutscene, 2 dead), the weapons `<B>` count + per
weapon `<B B I2 fff I4 B>` (slot, flags: 1 visible, attach joint = AVATAR joint index or 0,
position, rotation, joint count) + `<I4>` × joints, and the translations `<B>` count + per joint
`<I2 hhh>` (AVATAR joint index, local position in mm). Every chunk then carries `<I4>` × joint
count: packed local rotations.

A weapon with an attach joint is placed relative to that joint (the receiver hangs it from the
same joint of its copy, so the gun stays in the hand); otherwise relative to the root. Poses
for an AVATAR or GEAR revision the receiver does not have are ignored.

About 1.2 KB per pose for a 300-joint skeleton: two datagrams at most for 512 joints.

### ACTIONS (14)

`<B d B>`: type, sender time, event count; per event `<B f>`: kind, time offset from the message
time, then:

* kind 1, CALL: `<B I4 B I4 B>`: part reference (0 body, 1–199 AVATAR part, 200 the context's
  head object, 200 + s weapon slot s), FNV-1a of the component's runtime type, its index among
  components of that type, FNV-1a of `"<declaring type>::<method signature>"` (0 = replay with the
  simplest `trigger` overload), argument count; per argument `<B>` tag + value: 1 `I4` UInt32,
  2 `i4` Int32, 3 `B` bool, 4 `f` Single, 5 `B` GameObject (a part reference), 6 null, 7 `j` Int64.
* kind 2, SHOT: `<B>` weapon slot.

The receiver replays events when its delayed animation timeline reaches them (same
interpolation delay as the pose), and drops events more than a second late. ACTIONS travel on
the unordered lane: each message carries its own timestamps, so arrival order does not matter.

### Timing

Senders keep exact rates (the next send is due one interval after the last *due* time, not
after the frame that sent it), so 30 poses per second stay 30 at any frame rate. The pose is
sent at the end of the frame it was captured in (PrepareRendering). The receiver shows the
partner `interp_delay` (default 66 ms) in the past, more when packets arrive with more jitter
than that covers (one send interval plus twice the measured jitter, at most 250 ms), samples
every POSE chunk at the same instant, and lets joints move on for one more pose interval when
a pose is late instead of freezing them. The pose rate drops to half beyond 40 m and to 5 per
second while the partner is in another chapter.
