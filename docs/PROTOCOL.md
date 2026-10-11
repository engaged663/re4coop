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
| `max_payload()`, `version()` | `1388`; `"0.3.0", 1` |
| `new_session()` | An independent session object with the same methods (tests/tools) |

## Game messages (game protocol version 3)

The first byte is the message type. Formats use Lua `string.pack` notation.

| Type | Name | Channel | Direction | Format |
|---|---|---|---|---|
| 1 | HELLO | reliable | both, on connect | `<B I2 s1 s1 s1 B`: type, game protocol version, mod version, player name, chapter/area, flags (1 = reply requested) |
| 2 | PLAYER | unreliable, 20 Hz | both | `<B d fff ffff ff B I4 i4 B` + `hhh` × n: time, position, rotation quaternion (x,y,z,w), HP, max HP, flags (1 dead, 2 cutscene, 4 aiming, 8 has stage), area hash, `chainsaw.StageID` (valid when flag 8 is set), joint count, joints as int16 cm offsets from position |
| 3 | SKELETON | reliable, on change | both | `<B B` + `B` × n: parent index (1-based) of each joint in PLAYER, 0 = none |
| 4 | ENEMY_SNAPSHOT | unreliable, 10 Hz | host → client | `<B d B B B` + n × `<I2 I4 fff fff f f f B i4 i4 B B`: time, chunk, chunks, count; then net id, kind hash (FNV-1a of context type name), position, spawn position, yaw, HP, max HP, flags (1 alive, 2 has ContextID), the enemy's **spawner** `chainsaw.ContextID` (`CharacterContext.get_SpawnerID()`) as group, index, kind, category. 25 entries per chunk |
| 5 | ENEMY_DAMAGE | reliable | client → host | `<B I2 I4 fff f B i4 i4 B B`: net id (0 = unpaired), kind hash, spawn position, amount, flags (1 lethal, 2 has ContextID), spawner ContextID (sent only once spawner IDs are trusted, see below) |
| 6 | ENEMY_DEAD | reliable | host → client | `<B I2`: net id |
| 7 | CHAT | reliable | both | `<B s2`: text (≤ 512 bytes) |
| 8 | NOTIFY | reliable | both | `<B B s1`: code (1 died, 2 revived, 3 teleported, 4 info), text |
| 9 | ITEM_TAKEN | reliable | both | `<B I4 fff B i4 i4 B B`: item ID, position, flags (1 has ContextID), ContextID of the `chainsaw.DropItem` (level IDs only). The receiver removes its copy of that key item |

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

Compatibility: only the `version` field of HELLO is guaranteed across game protocol versions.
A peer with a different version gets an "update both" message, and its game messages are
ignored.
