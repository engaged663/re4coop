# Wire protocol

Two layers: the **transport** (C++, `plugin/src/net`) moves datagrams between exactly two
peers. The **game messages** (Lua, `re4coop/protocol.lua`) ride inside transport payloads.
All integers are little-endian.

## Transport (network protocol version 1)

Every datagram starts with a 10-byte header:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `0x50433452` (`"R4CP"`) |
| 4 | 1 | protocol version (`1`) |
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
| 8 | Reliable | `u16 seq, payload` | Acked. Retransmitted every `clamp(2·RTT, 50 ms, 1 s)`. Delivered once, in order (4096-entry reorder window) |
| 9 | Ack | `u8 count, u16 seq × count` | Selective acks, batched per network tick |

`str` = `u8 length` + bytes (≤ 255). Maximum datagram: 1400 bytes. Maximum message payload:
**1388 bytes** (`re4coop_net.max_payload()`).

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
| `send(bytes, reliable)` | `true` or `nil, err` |
| `poll([max])` | Array of `{type="connected"\|"disconnected"\|"rejected"\|"message", data, reliable, peer, name}` |
| `state()` / `role()` | `"idle"\|"listening"\|"connecting"\|"connected"` / `"none"\|"host"\|"client"` |
| `stats()` | Table: `rtt_ms, peer, peer_name, bytes_sent, bytes_recv, resends, reliable_in_flight, …` |
| `local_addresses()` | Array of this PC's LAN IPv4 addresses |
| `time()` | Monotonic seconds (`os.clock` is CPU time, so don't use it for networking) |
| `max_payload()`, `version()` | `1388`; `"0.6.0", 1` |
| `new_session()` | An independent session object with the same methods (tests/tools) |

## Game messages (game protocol version 6)

The first byte is the message type. Formats use Lua `string.pack` notation.

| Type | Name | Channel | Direction | Format |
|---|---|---|---|---|
| 1 | HELLO | reliable | both, on connect | `<B I2 s1 s1 s1 B`: type, game protocol version, mod version, player name, chapter/area, flags (1 = reply requested) |
| 2 | PLAYER | unreliable, 20 Hz | both | `<B d fff ffff ff B I4 i4 i4`: time, position, rotation quaternion (x,y,z,w), HP, max HP, flags (1 dead, 2 cutscene, 4 aiming, 8 has stage, 16 has chapter, 32 waiting at a transition), area hash, `chainsaw.StageID` (valid with flag 8), `chainsaw.ChapterID` (valid with flag 16) |
| 3 | *(retired)* | | | SKELETON in protocols 1–3 (the stick-figure ghost) |
| 4 | ENEMY_SNAPSHOT | unreliable, 15 Hz | host → client | `<B d B B B` + n × `<I2 I4 fff fff f f f B i4 i4 B B I4 I4 f>` (65 B): time, chunk, chunks, count; then net id, kind hash (FNV-1a of context type name), position, spawn position, yaw, HP, max HP, flags (1 alive, 2 has ContextID, 4 run by the client, 8 has animation), the enemy's **spawner** `chainsaw.ContextID` (`CharacterContext.get_SpawnerID()`) as group, index, kind, category, then motion bank, motion ID and frame of its motion layer 0. 20 entries per chunk. Every 5th snapshot also lists recent deaths the client did not witness (flags without 1) |
| 5 | ENEMY_DAMAGE | reliable | client → host | `<B I2 I4 fff f B i4 i4 B B`: net id (0 = unpaired), kind hash, spawn position, amount, flags (1 lethal, 2 has ContextID), spawner ContextID (sent only once spawner IDs are trusted, see below) |
| 6 | ENEMY_DEAD | reliable | host → client | `<B I2`: net id. Net id 0: the host reloaded a checkpoint, forget every death it reported |
| 7 | CHAT | reliable | both | `<B s2`: text (≤ 512 bytes) |
| 8 | NOTIFY | reliable | both | `<B B s1`: code (1 died, 2 revived, 3 teleported, 4 info), text |
| 9 | ITEM_TAKEN | reliable | both | `<B I4 fff B i4 i4 B B i4`: item ID, position, flags (1 has ContextID, 2 it was the only copy in the sender's scene, 4 has stage), ContextID of the `chainsaw.DropItem` (level IDs only), its `chainsaw.StageID`. The receiver removes its copy of that key item |
| 10 | FRAG | reliable | both | `<B I2 B B` + bytes: message id, piece index (1-based), piece count, a slice of a reliable message longer than one datagram. Pieces arrive in order and are concatenated |
| 11 | AVATAR | reliable (fragmented) | both | see below: how the sender's character is built |
| 12 | GEAR | reliable | both | see below: the weapons the character carries |
| 13 | POSE | unreliable, 30 Hz | both | see below: root placement, every joint's local rotation, weapon placement |
| 14 | ACTIONS | reliable | both | see below: sound/effect calls and shots to replay |
| 15 | ENEMY_HIT | unreliable | both | `<B I2 I4 fff i4 fff fff i4 B`: net id (host numbering; 0 = unpaired), kind hash, enemy spawn position, damage, wince, break, stopping, damage direction, weapon ID, flags (1 critical). A hit the sender's player landed (`HitController.callbackDamageHit`); the receiver replays it on its copy (cosmetic: 1 damage, HP restored) |
| 16 | ITEM_DROPPED | reliable | host → client | `<B I2 I4 i4 fff i4 B`: net id of the enemy, item ID, count, position, stage, flags (1 has stage). The item the host's random roll dropped; the client spawns it where its copy of that enemy is |
| 17 | ENEMY_CLIENT | unreliable, 20 Hz | client → host | `<B d B B` + n × `<I2 fff f I4 I4 f B>` + m × `<I2>`: time, state count (≤ 30), copy count (≤ 200); the enemies the client runs (net id, position, yaw, motion bank/ID/frame, flags: 1 has animation), then the net ids of every other host enemy the client has a copy of. The host mirrors the first list and hands over only enemies the client has |
| 18 | FLAGS | reliable | both | `<B B` + n × (`guid` + `<B`): scenario flags that changed (≤ 64 per message), with their new value |
| 19 | FLAG_WORDS | reliable | both | `<B I2 B B B B` (sync id, mode, chunk, chunks, item count) + per item `<s1 I2 I2` (group name, first word, count) + words. Mode 1 = full copy: `<I4` words. Mode 2 = changes: `<I2 I4 I4` (word index, bits set, bits cleared) |
| 20 | GIMMICKS | reliable | both | `<B I2 B B B B` (sync id, mode, chunk, chunks, count) + per gimmick: `ctx` (`<i4 i4 B B>`: group, index, kind, category), `<s1` attribute bytes, `<B` + n × `<I4 I4` (trigger save ID, done), `<B` detected, `<B` + n × (`<B` kind, `<f` or `<I4` value) accessory values. Mode 1 = the whole table, 2 = records that changed, 3 = records that appeared (applied only where the receiver has no record of that gimmick) |
| 21 | OBJECTS | reliable | both | `<B B` + n × (`guid` + `<B i4`): scene object (GameObject GUID), event (1 destroyed, 2 state changed), value (the `_Routine` it ended in, or -1) |
| 22 | CUTSCENE | reliable | both | `<B i4 s1 i4 i4 fff B`: timeline event ID (`chainsaw.TimelineEventDefine.ID`), request method name, chapter, stage, position where it started, flags (1 = triggered by the sender's game) |
| 23 | WORLD_REQUEST | reliable | client → host | `<B I2 B`: sync id, what (1 flags, 2 gimmicks, 4 enemies, 8 objects) |
| 24 | WORLD_DONE | reliable | host → client | `<B I2 B I4 I4`: sync id, what, flag groups sent, gimmicks sent. Follows the FLAG_WORDS / GIMMICKS / OBJECTS of a full transfer (the reliable channel is ordered) |

`guid` is 16 raw bytes: the 32 hex digits of the canonical GUID string, in order. Scenario
flags are addressed by GUID in the game itself; scene objects by their GameObject GUID, which
comes from the scene file and is the same on both machines.

Joining: once the client is in the host's chapter it sends WORLD_REQUEST; the host answers
with full FLAG_WORDS and GIMMICKS, the OBJECTS destroyed so far and WORLD_DONE; the client
applies them and then warps next to the host.

Compatibility: only the `version` field of HELLO is guaranteed across game protocol versions.
A peer with a different version gets an "update both" message, and its game messages are
ignored.

### ContextIDs on the wire

`chainsaw.ContextID` is `{category, kind, group, index}`. The research dump showed two kinds:

* **Level IDs**, the same on both machines: level-placed items (`3:0:40210:13`, group =
  stage) and, presumably, level spawners.
* **Runtime IDs** in group 12, handed out in load order: every enemy's own `_ID`
  (`0:0:12:987`) and every spawned drop item (`2:0:12:486`). Two machines can give the same
  number to different objects, or agree for a while and then drift apart.

Runtime IDs are never used across the network: enemies are identified by their spawner's ID
(ignored if it is a runtime ID), and ITEM_TAKEN carries a ContextID only if it is a level
ID. A spawner may create several enemies, so the client pairs by spawner ID only when that ID
is unique among the enemies of that kind on both sides, within 25 m, and only after three
position-based pairings agreed with the spawner IDs and none disagreed.

### Quaternions

Rotations in AVATAR/POSE travel as 32 bits, "smallest three": bits 31–30 hold the index (x, y,
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
interpolation delay as the pose), and drops events more than a second late.
