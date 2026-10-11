// Transport-level wire format. See docs/PROTOCOL.md for the full description.
#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

namespace re4coop::net {

constexpr uint32_t kMagic = 0x50433452;  // "R4CP" when read as little-endian bytes
constexpr uint8_t kProtocolVersion = 2;  // 2: unordered reliable lane, 1200 B datagrams
constexpr size_t kHeaderSize = 10;        // magic(4) + version(1) + type(1) + token(4)
// Stays under the MTU of VPN tunnels (ZeroTier, Tailscale, Hamachi: ~1280-1420 B) with the
// IP/UDP headers, so a datagram is never split into IP fragments (one lost fragment loses it all).
constexpr size_t kMaxDatagram = 1200;
constexpr size_t kMaxReliableOverhead = 2;
constexpr size_t kMaxPayload = kMaxDatagram - kHeaderSize - kMaxReliableOverhead; // per message

enum class PacketType : uint8_t {
    ConnectRequest = 1, // nonce u32, name str, password str
    ConnectAccept = 2,  // nonce u32, host name str           (header token = new session token)
    ConnectReject = 3,  // nonce u32, reason u8, message str
    Disconnect = 4,     // reason u8
    Ping = 5,           // id u32, time_us u64
    Pong = 6,           // id u32, echoed time_us u64
    Unreliable = 7,     // seq u16, payload...
    Reliable = 8,       // seq u16, payload...
    Ack = 9,            // count u8, seq u16 * count
    ReliableUnordered = 10, // seq u16, payload... (delivered as soon as it arrives, exactly once)
    AckUnordered = 11,      // count u8, seq u16 * count
};

enum class RejectReason : uint8_t {
    Full = 1,
    BadPassword = 2,
    VersionMismatch = 3,
};

enum class DisconnectReason : uint8_t {
    Requested = 1,
    Timeout = 2,
    Kicked = 3,
};

// Wrap-around aware "a is newer than b" for 16-bit sequence numbers.
inline bool seq_newer(uint16_t a, uint16_t b) {
    return a != b && static_cast<uint16_t>(a - b) < 0x8000;
}

class Writer {
public:
    explicit Writer(size_t reserve = kMaxDatagram) { m_buf.reserve(reserve); }

    void u8(uint8_t v) { m_buf.push_back(v); }
    void u16(uint16_t v) { put(v); }
    void u32(uint32_t v) { put(v); }
    void u64(uint64_t v) { put(v); }
    void bytes(const void* p, size_t n) {
        const auto* b = static_cast<const uint8_t*>(p);
        m_buf.insert(m_buf.end(), b, b + n);
    }
    // Length-prefixed (u8) string, truncated to 255 bytes.
    void str(std::string_view s) {
        const size_t n = s.size() > 255 ? 255 : s.size();
        u8(static_cast<uint8_t>(n));
        bytes(s.data(), n);
    }
    void header(PacketType type, uint32_t token) {
        u32(kMagic);
        u8(kProtocolVersion);
        u8(static_cast<uint8_t>(type));
        u32(token);
    }

    const std::vector<uint8_t>& data() const { return m_buf; }
    size_t size() const { return m_buf.size(); }

private:
    template <typename T> void put(T v) {
        uint8_t tmp[sizeof(T)];
        for (size_t i = 0; i < sizeof(T); ++i) {
            tmp[i] = static_cast<uint8_t>(v >> (8 * i));
        }
        bytes(tmp, sizeof(T));
    }

    std::vector<uint8_t> m_buf;
};

class Reader {
public:
    Reader(const uint8_t* data, size_t len) : m_data(data), m_len(len) {}

    bool ok() const { return m_ok; }
    size_t remaining() const { return m_ok ? m_len - m_pos : 0; }
    const uint8_t* cursor() const { return m_data + m_pos; }

    uint8_t u8() { return get<uint8_t>(); }
    uint16_t u16() { return get<uint16_t>(); }
    uint32_t u32() { return get<uint32_t>(); }
    uint64_t u64() { return get<uint64_t>(); }
    std::string str() {
        const uint8_t n = u8();
        if (!need(n)) return {};
        std::string s(reinterpret_cast<const char*>(m_data + m_pos), n);
        m_pos += n;
        return s;
    }

private:
    bool need(size_t n) {
        if (!m_ok || m_len - m_pos < n) {
            m_ok = false;
            return false;
        }
        return true;
    }
    template <typename T> T get() {
        if (!need(sizeof(T))) return T{};
        T v{};
        for (size_t i = 0; i < sizeof(T); ++i) {
            v |= static_cast<T>(static_cast<T>(m_data[m_pos + i]) << (8 * i));
        }
        m_pos += sizeof(T);
        return v;
    }

    const uint8_t* m_data;
    size_t m_len;
    size_t m_pos{0};
    bool m_ok{true};
};

struct Header {
    uint8_t version{0};
    PacketType type{};
    uint32_t token{0};
};

// Validates the magic and extracts the header. Returns false for foreign/garbage packets.
// The caller must still compare `version` against kProtocolVersion (so it can tell a peer
// running an incompatible build why it is being rejected instead of silently dropping it).
inline bool read_header(Reader& r, Header& out) {
    if (r.u32() != kMagic) return false;
    out.version = r.u8();
    out.type = static_cast<PacketType>(r.u8());
    out.token = r.u32();
    return r.ok();
}

} // namespace re4coop::net
