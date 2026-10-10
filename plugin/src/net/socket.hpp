// Minimal cross-platform IPv4 UDP socket wrapper (Winsock on Windows, BSD sockets elsewhere).
// The game only ever runs on Windows; the POSIX path exists so the transport can be unit
// tested on Linux CI.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace re4coop::net {

struct Address {
    uint32_t ip{0};   // host byte order
    uint16_t port{0}; // host byte order

    bool operator==(const Address& o) const { return ip == o.ip && port == o.port; }
    bool operator!=(const Address& o) const { return !(*this == o); }
    bool valid() const { return ip != 0 && port != 0; }
    std::string to_string() const;
};

// Reference-counted WSAStartup/WSACleanup. No-ops on POSIX.
bool startup(std::string& err);
void cleanup();

// Resolves a hostname or dotted IPv4 string. IPv4 only (LAN play).
bool resolve(const std::string& host, uint16_t port, Address& out, std::string& err);

// Non-loopback, non-link-local IPv4 addresses of this machine, so a host can tell their
// partner which IP to type in.
std::vector<std::string> local_ipv4_addresses();

class UdpSocket {
public:
    UdpSocket() = default;
    ~UdpSocket();
    UdpSocket(const UdpSocket&) = delete;
    UdpSocket& operator=(const UdpSocket&) = delete;

    // Binds to 0.0.0.0:port (port 0 = ephemeral) and switches to non-blocking mode.
    bool open(uint16_t port, std::string& err);
    void close();
    bool is_open() const;
    uint16_t local_port() const { return m_local_port; }

    // Returns bytes sent, or -1 on error.
    int send_to(const Address& to, const void* data, size_t len);
    // Returns bytes received, 0 when nothing is pending, or -1 on a hard error.
    int recv_from(Address& from, void* buf, size_t cap);
    // Blocks up to timeout_ms waiting for the socket to become readable.
    bool wait_readable(int timeout_ms);

private:
#ifdef _WIN32
    using Handle = uintptr_t; // SOCKET
#else
    using Handle = int;
#endif
    Handle m_sock{static_cast<Handle>(-1)};
    uint16_t m_local_port{0};
};

} // namespace re4coop::net
