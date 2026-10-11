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
| `max_payload()`, `version()` | `1188`; `"0.8.0", 2` |
| `new_session()` | An independent session object with the same methods (tests/tools) |

## Game messages (game protocol version 8)

Version 8 (mod 0.8.0) rebuilt enemy sync on the game's own enemy identity, with the host
running every enemy: ENEMY_SNAPSHOT, ENEMY_DAMAGE, ENEMY_DEAD and ENEMY_HIT carry the enemy's
**uid** (see "ContextIDs on the wire" below) instead of a spawner ContextID, ENEMY_SNAPSHOT
carries 19 entries per chunk and no dead entries any more, ENEMY_GRAVE (25) carries the list of
every enemy dead in the host's world, ENEMY_CLIENT only lists the host enemies the client has a
copy of (enemies no longer change hands), and ANIMALS (26) carries the host's animals near both
players.
Version 7 (mod 0.7.0): ENEMY_CLIENT up to 24 states, OBJECTS up to 50 events (everything fits
the 1188-byte payload), ACTIONS travel on the unordered lane, and ITEM_DROPPED is retired
(each player rolls their own loot).

The first byte is the message type. Formats use Lua `string.pack` notation.

| Type | Name | Channel | Direction | Format |
|---|---|---|---|---|
| 1 | HELLO | reliable | both, on connect | `<B I2 s1 s1 s1 B`: type, game protocol version, mod version, player name, chapter/area, flags (1 = reply requested) |
| 2 | PLAYER | unreliable, 20 Hz | both | `<B d fff ffff ff B I4 i4 i4`: time, position, rotation quaternion (x,y,z,w), HP, max HP, flags (1 dead, 2 cutscene, 4 aiming, 8 has stage, 16 has chapter, 32 waiting at a transition), area hash, `chainsaw.StageID` (valid with flag 8), `chainsaw.ChapterID` (valid with flag 16) |
| 3 | *(retired)* | | | SKELETON in protocols 1–3 (the stick-figure ghost) |
| 4 | ENEMY_SNAPSHOT | unreliable, 20 Hz | host → client | `<B d B B B` + n × `<I2 I4 fff fff f f f B I4 I4 I4 f>` (59 B): time, chunk, chunks, count; then the host's living enemies: net id, kind hash (FNV-1a of context type name), position, spawn position (where the host first saw it), yaw, HP, max HP, flags (1 alive, 2 has uid, 8 has animation; 4 and 16 meant "run by the client" and "hand-over decided" in development builds and are retired), uid, then motion bank, motion ID and frame of its motion layer 0 (read only for enemies the client has a copy of). 19 entries per chunk. The client's copies follow these: position, facing and animation, with their own AI off |
| 5 | ENEMY_DAMAGE | reliable | client → host | `<B I2 I4 fff f B I4`: net id (0 = unpaired), kind hash, spawn position, amount, flags (1 lethal, 2 has uid), uid. A lethal report for an enemy the host has not loaded puts it in the host's graveyard |
| 6 | ENEMY_DEAD | reliable | host → client | `<B I2 B I4`: net id, flags (1 has uid, 2 reset), uid. One enemy died in the host's world (also a corpse the host found that died earlier). Flag 2 (net id 0): the host reloaded a checkpoint, forget every death it reported |
| 7 | CHAT | reliable | both | `<B s2`: text (≤ 512 bytes) |
| 8 | NOTIFY | reliable | both | `<B B s1`: code (1 died, 2 revived, 3 teleported, 4 info), text |
| 9 | ITEM_TAKEN | reliable | both | `<B I4 fff B i4 i4 B B i4`: item ID, position, flags (1 has ContextID, 2 it was the only copy in the sender's scene, 4 has stage), ContextID of the `chainsaw.DropItem` (level IDs only), its `chainsaw.StageID`. The receiver removes its copy of that key item |
| 10 | FRAG | reliable | both | `<B I2 B B` + bytes: message id, piece index (1-based), piece count, a slice of a reliable message longer than one datagram. Pieces arrive in order and are concatenated |
| 11 | AVATAR | reliable (fragmented) | both | see below: how the sender's character is built |
| 12 | GEAR | reliable | both | see below: the weapons the character carries |
| 13 | POSE | unreliable, 30 Hz | both | see below: root placement, every joint's local rotation, weapon placement |
| 14 | ACTIONS | reliable, unordered lane | both | see below: sound/effect calls and shots to replay |
| 15 | ENEMY_HIT | unreliable | both | `<B I2 I4 fff i4 fff fff i4 B I4`: net id (host numbering; 0 = unpaired), kind hash, enemy spawn position, damage, wince, break, stopping, damage direction, weapon ID, flags (1 critical, 2 has uid), uid. A hit the sender's player landed (`HitController.callbackDamageHit`): the receiver draws a shot tracer, and with the experimental replay switch also replays it on its copy (cosmetic: 1 damage, HP restored) |
| 16 | *(retired)* | | | ITEM_DROPPED in protocols 4–6 (the host's roll spawned on the client); still decoded, ignored |
| 17 | ENEMY_CLIENT | unreliable, 20 Hz | client → host | `<B d I2` + n × `<I2>`: time, count (≤ 500), the net ids of the host enemies the client has a living copy of. The host reads (and sends) the animation of those enemies only |
| 18 | FLAGS | reliable | both | `<B B` + n × (`guid` + `<B`): scenario flags that changed (≤ 64 per message), with their new value |
| 19 | FLAG_WORDS | reliable | both | `<B I2 B B B B` (sync id, mode, chunk, chunks, item count) + per item `<s1 I2 I2` (group name, first word, count) + words. Mode 1 = full copy: `<I4` words. Mode 2 = changes: `<I2 I4 I4` (word index, bits set, bits cleared) |
| 20 | GIMMICKS | reliable | both | `<B I2 B B B B` (sync id, mode, chunk, chunks, count) + per gimmick: `ctx` (`<i4 i4 B B>`: group, index, kind, category), `<s1` attribute bytes, `<B` + n × `<I4 I4` (trigger save ID, done), `<B` detected, `<B` + n × (`<B` kind, `<f` or `<I4` value) accessory values. Mode 1 = the whole table, 2 = records that changed, 3 = records that appeared (applied only where the receiver has no record of that gimmick) |
| 21 | OBJECTS | reliable | both | `<B B` + n × (`guid` + `<B i4`): scene object (GameObject GUID), event (1 destroyed, 2 state changed), value (the `_Routine` it ended in, or -1) |
| 22 | CUTSCENE | reliable | both | `<B i4 s1 i4 i4 fff B`: timeline event ID (`chainsaw.TimelineEventDefine.ID`), request method name, chapter, stage, position where it started, flags (1 = triggered by the sender's game) |
| 23 | WORLD_REQUEST | reliable | client → host | `<B I2 B`: sync id, what (1 flags, 2 gimmicks, 4 enemies, 8 objects) |
| 24 | WORLD_DONE | reliable | host → client | `<B I2 B I4 I4`: sync id, what, flag groups sent, gimmicks sent. Follows the FLAG_WORDS / GIMMICKS / OBJECTS of a full transfer (the ordered lane keeps them in order). A request with sync id 0 (enemies only, from a client without a world adapter) gets no WORLD_DONE |
| 25 | ENEMY_GRAVE | reliable | host → client | `<B B B I2` + n × `<I4>`: chunk, chunks, count (≤ 290), uids. Every enemy dead in the host's world: the deaths it saw, the client's kills of enemies it had not loaded, and the enemies its save has eliminated (`CharacterManager.CharacterBackupDB`). Sent after a WORLD_REQUEST with bit 4 (joining, the client's game reloading), once the host has read its save (a few ticks). The first message replaces what the client knew |
| 26 | ANIMALS | unreliable, 10 Hz | host → client | `<B d B B B` + n × (`guid` + `<fff I4 i4 I4 I4 f B>`) (49 B): time, chunk, chunks, count (≤ 23); then the host's animals (`chainsaw.GmAnimal`: crows, chickens, fish, bats, rats) within 50 m of both players, nearest to the client first, at most 24: GameObject GUID, position, packed rotation, `_Routine`, motion bank, motion ID, motion frame, flags (1 has animation, 2 dead: its routine reached Die/Dead, 4 has routine). The client's copies follow them with their own AI off the game's update; a dead one dies in the client's game with its own death. Animal kills travel as OBJECTS |

`guid` is 16 raw bytes: the 32 hex digits of the canonical GUID string, in order. Scenario
flags are addressed by GUID in the game itself; scene objects by their GameObject GUID, which
comes from the scene file and is the same on both machines.

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

Rotations in AVATAR/POSE/ANIMALS travel as 32 bits, "smallest three": bits 31–30 hold the index (x, y,
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
