#include "socket.hpp"

#include <atomic>
#include <cstring>
#include <mutex>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif
#else
#include <arpa/inet.h>
#include <cerrno>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace re4coop::net {

namespace {

#ifdef _WIN32
std::mutex g_wsa_mutex;
int g_wsa_refs = 0;

bool would_block() {
    const int e = WSAGetLastError();
    return e == WSAEWOULDBLOCK || e == WSAECONNRESET || e == WSAEMSGSIZE;
}
std::string last_error_string(const char* what) {
    return std::string(what) + " failed (WSA error " + std::to_string(WSAGetLastError()) + ")";
}
#else
bool would_block() {
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR || errno == ECONNREFUSED;
}
std::string last_error_string(const char* what) {
    return std::string(what) + " failed: " + std::strerror(errno);
}
#endif

bool is_usable_lan_ip(uint32_t ip) {
    const uint8_t a = static_cast<uint8_t>(ip >> 24);
    const uint8_t b = static_cast<uint8_t>(ip >> 16);
    if (a == 127 || a == 0) return false;          // loopback / unspecified
    if (a == 169 && b == 254) return false;        // link-local (no DHCP)
    return true;
}

std::string ip_to_string(uint32_t ip) {
    return std::to_string((ip >> 24) & 0xFF) + "." + std::to_string((ip >> 16) & 0xFF) + "." +
           std::to_string((ip >> 8) & 0xFF) + "." + std::to_string(ip & 0xFF);
}

} // namespace

std::string Address::to_string() const {
    return ip_to_string(ip) + ":" + std::to_string(port);
}

bool startup(std::string& err) {
#ifdef _WIN32
    std::scoped_lock _{g_wsa_mutex};
    if (g_wsa_refs++ == 0) {
        WSADATA data{};
        const int rc = WSAStartup(MAKEWORD(2, 2), &data);
        if (rc != 0) {
            g_wsa_refs = 0;
            err = "WSAStartup failed (" + std::to_string(rc) + ")";
            return false;
        }
    }
#else
    (void)err;
#endif
    return true;
}

void cleanup() {
#ifdef _WIN32
    std::scoped_lock _{g_wsa_mutex};
    if (g_wsa_refs > 0 && --g_wsa_refs == 0) {
        WSACleanup();
    }
#endif
}

bool resolve(const std::string& host, uint16_t port, Address& out, std::string& err) {
    if (host.empty()) {
        err = "no address given";
        return false;
    }

    in_addr parsed{};
    if (inet_pton(AF_INET, host.c_str(), &parsed) == 1) {
        out.ip = ntohl(parsed.s_addr);
        out.port = port;
        return true;
    }

    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    addrinfo* result = nullptr;
    const int rc = getaddrinfo(host.c_str(), nullptr, &hints, &result);
    if (rc != 0 || result == nullptr) {
        err = "could not resolve '" + host + "'";
        return false;
    }
    const auto* sin = reinterpret_cast<const sockaddr_in*>(result->ai_addr);
    out.ip = ntohl(sin->sin_addr.s_addr);
    out.port = port;
    freeaddrinfo(result);
    return true;
}

std::vector<std::string> local_ipv4_addresses() {
    std::vector<std::string> out;
    auto add = [&out](uint32_t ip) {
        if (!is_usable_lan_ip(ip)) return;
        auto s = ip_to_string(ip);
        for (const auto& e : out) {
            if (e == s) return;
        }
        out.push_back(std::move(s));
    };

#ifdef _WIN32
    std::string ignored;
    if (!startup(ignored)) return out;
    char name[256]{};
    if (gethostname(name, sizeof(name) - 1) == 0) {
        addrinfo hints{};
        hints.ai_family = AF_INET;
        addrinfo* result = nullptr;
        if (getaddrinfo(name, nullptr, &hints, &result) == 0) {
            for (auto* it = result; it != nullptr; it = it->ai_next) {
                add(ntohl(reinterpret_cast<const sockaddr_in*>(it->ai_addr)->sin_addr.s_addr));
            }
            freeaddrinfo(result);
        }
    }
    cleanup();
#else
    ifaddrs* list = nullptr;
    if (getifaddrs(&list) == 0) {
        for (auto* it = list; it != nullptr; it = it->ifa_next) {
            if (it->ifa_addr == nullptr || it->ifa_addr->sa_family != AF_INET) continue;
            if ((it->ifa_flags & IFF_UP) == 0) continue;
            add(ntohl(reinterpret_cast<const sockaddr_in*>(it->ifa_addr)->sin_addr.s_addr));
        }
        freeifaddrs(list);
    }
#endif
    return out;
}

UdpSocket::~UdpSocket() {
    close();
}

bool UdpSocket::is_open() const {
    return m_sock != static_cast<Handle>(-1);
}

bool UdpSocket::open(uint16_t port, std::string& err) {
    close();

#ifdef _WIN32
    const SOCKET s = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) {
        err = last_error_string("socket()");
        return false;
    }
    m_sock = static_cast<Handle>(s);

    // Without this, an ICMP "port unreachable" (e.g. the partner closed the game) makes every
    // later recvfrom() on this socket fail with WSAECONNRESET, killing the host's listener.
    BOOL new_behavior = FALSE;
    DWORD bytes = 0;
    WSAIoctl(s, SIO_UDP_CONNRESET, &new_behavior, sizeof(new_behavior), nullptr, 0, &bytes, nullptr, nullptr);

    u_long nonblocking = 1;
    if (ioctlsocket(s, FIONBIO, &nonblocking) != 0) {
        err = last_error_string("ioctlsocket(FIONBIO)");
        close();
        return false;
    }
#else
    const int s = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s < 0) {
        err = last_error_string("socket()");
        return false;
    }
    m_sock = s;
    const int flags = fcntl(s, F_GETFL, 0);
    if (flags < 0 || fcntl(s, F_SETFL, flags | O_NONBLOCK) < 0) {
        err = last_error_string("fcntl(O_NONBLOCK)");
        close();
        return false;
    }
#endif

    // Generous buffers: enemy snapshots arrive in bursts.
    int bufsize = 1 << 20;
    setsockopt(s, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char*>(&bufsize), sizeof(bufsize));
    setsockopt(s, SOL_SOCKET, SO_SNDBUF, reinterpret_cast<const char*>(&bufsize), sizeof(bufsize));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (::bind(s, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) != 0) {
        err = last_error_string("bind()");
        if (port != 0) {
            err += " - is UDP port " + std::to_string(port) + " already in use?";
        }
        close();
        return false;
    }

    sockaddr_in bound{};
#ifdef _WIN32
    int bound_len = sizeof(bound);
#else
    socklen_t bound_len = sizeof(bound);
#endif
    if (getsockname(s, reinterpret_cast<sockaddr*>(&bound), &bound_len) == 0) {
        m_local_port = ntohs(bound.sin_port);
    } else {
        m_local_port = port;
    }
    return true;
}

void UdpSocket::close() {
    if (!is_open()) return;
#ifdef _WIN32
    ::closesocket(static_cast<SOCKET>(m_sock));
#else
    ::close(m_sock);
#endif
    m_sock = static_cast<Handle>(-1);
    m_local_port = 0;
}

int UdpSocket::send_to(const Address& to, const void* data, size_t len) {
    if (!is_open()) return -1;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(to.ip);
    addr.sin_port = htons(to.port);
#ifdef _WIN32
    const int rc = ::sendto(static_cast<SOCKET>(m_sock), static_cast<const char*>(data), static_cast<int>(len), 0,
                            reinterpret_cast<const sockaddr*>(&addr), sizeof(addr));
    return rc == SOCKET_ERROR ? -1 : rc;
#else
    const auto rc = ::sendto(m_sock, data, len, 0, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr));
    return rc < 0 ? -1 : static_cast<int>(rc);
#endif
}

int UdpSocket::recv_from(Address& from, void* buf, size_t cap) {
    if (!is_open()) return -1;
    sockaddr_in addr{};
#ifdef _WIN32
    int addr_len = sizeof(addr);
    const int rc = ::recvfrom(static_cast<SOCKET>(m_sock), static_cast<char*>(buf), static_cast<int>(cap), 0,
                              reinterpret_cast<sockaddr*>(&addr), &addr_len);
    if (rc == SOCKET_ERROR) {
        return would_block() ? 0 : -1;
    }
#else
    socklen_t addr_len = sizeof(addr);
    const auto rc = ::recvfrom(m_sock, buf, cap, 0, reinterpret_cast<sockaddr*>(&addr), &addr_len);
    if (rc < 0) {
        return would_block() ? 0 : -1;
    }
#endif
    from.ip = ntohl(addr.sin_addr.s_addr);
    from.port = ntohs(addr.sin_port);
    return static_cast<int>(rc);
}

bool UdpSocket::wait_readable(int timeout_ms) {
    if (!is_open()) return false;
#ifdef _WIN32
    WSAPOLLFD pfd{};
    pfd.fd = static_cast<SOCKET>(m_sock);
    pfd.events = POLLRDNORM;
    return WSAPoll(&pfd, 1, timeout_ms) > 0;
#else
    pollfd pfd{};
    pfd.fd = m_sock;
    pfd.events = POLLIN;
    return ::poll(&pfd, 1, timeout_ms) > 0;
#endif
}

} // namespace re4coop::net
