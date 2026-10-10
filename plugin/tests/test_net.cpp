// Native tests for the wire format and the UDP session, run over 127.0.0.1.
#include "net/session.hpp"
#include "net/wire.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#ifdef __linux__
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

using namespace re4coop::net;
using namespace std::chrono_literals;

namespace {

int g_failures = 0;

#define CHECK(cond)                                                                 \
    do {                                                                            \
        if (!(cond)) {                                                              \
            std::fprintf(stderr, "  CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            ++g_failures;                                                           \
        }                                                                           \
    } while (0)

uint16_t g_next_port = static_cast<uint16_t>(41000 + (std::chrono::steady_clock::now().time_since_epoch().count() % 9000));

// Hosts on the next free port.
uint16_t host_any(Session& s, const std::string& name, const std::string& password = "") {
    for (int i = 0; i < 50; ++i) {
        const uint16_t port = g_next_port++;
        std::string err;
        if (s.host(port, name, password, err)) return port;
    }
    std::fprintf(stderr, "  could not find a free port\n");
    std::exit(2);
}

// Pumps both sessions until pred() holds or timeout; collects events into the vectors.
bool pump_until(std::vector<Session*> sessions, std::vector<std::vector<Event>*> sinks, const std::function<bool()>& pred,
                std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        for (size_t i = 0; i < sessions.size(); ++i) {
            for (auto& e : sessions[i]->poll()) sinks[i]->push_back(std::move(e));
        }
        if (pred()) return true;
        std::this_thread::sleep_for(2ms);
    }
    return pred();
}

size_t count_type(const std::vector<Event>& v, Event::Type t) {
    size_t n = 0;
    for (const auto& e : v) n += e.type == t;
    return n;
}

const Event* find_type(const std::vector<Event>& v, Event::Type t) {
    for (const auto& e : v) {
        if (e.type == t) return &e;
    }
    return nullptr;
}

void test_wire_roundtrip() {
    Writer w;
    w.header(PacketType::Reliable, 0xDEADBEEF);
    w.u16(0xBEEF);
    w.u64(0x0123456789ABCDEFull);
    w.str("leon");
    Reader r(w.data().data(), w.size());
    Header h;
    CHECK(read_header(r, h));
    CHECK(h.version == kProtocolVersion);
    CHECK(h.type == PacketType::Reliable);
    CHECK(h.token == 0xDEADBEEF);
    CHECK(r.u16() == 0xBEEF);
    CHECK(r.u64() == 0x0123456789ABCDEFull);
    CHECK(r.str() == "leon");
    CHECK(r.ok());
    r.u8();
    CHECK(!r.ok()); // reading past the end is detected

    const uint8_t garbage[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    Reader g(garbage, sizeof(garbage));
    CHECK(!read_header(g, h));

    CHECK(seq_newer(1, 0));
    CHECK(seq_newer(0, 65535)); // wrap-around
    CHECK(!seq_newer(65535, 0));
    CHECK(!seq_newer(5, 5));
}

void test_connect_and_exchange() {
    Session host, client;
    std::vector<Event> he, ce;
    const uint16_t port = host_any(host, "Leon");
    CHECK(host.state() == State::Listening);

    std::string err;
    CHECK(client.join("127.0.0.1", port, "Ashley", "", err));
    CHECK(pump_until({&host, &client}, {&he, &ce}, [&] {
        return find_type(he, Event::Type::Connected) && find_type(ce, Event::Type::Connected);
    }));
    CHECK(host.state() == State::Connected && client.state() == State::Connected);
    if (auto* e = find_type(he, Event::Type::Connected)) CHECK(e->name == "Ashley");
    if (auto* e = find_type(ce, Event::Type::Connected)) CHECK(e->name == "Leon");

    CHECK(client.send("hello host", true, err));
    CHECK(host.send(std::string("bin\0ary", 7), false, err));
    CHECK(pump_until({&host, &client}, {&he, &ce}, [&] {
        return count_type(he, Event::Type::Message) >= 1 && count_type(ce, Event::Type::Message) >= 1;
    }));
    for (const auto& e : he) {
        if (e.type == Event::Type::Message) CHECK(e.data == "hello host" && e.reliable);
    }
    for (const auto& e : ce) {
        if (e.type == Event::Type::Message) CHECK(e.data == std::string("bin\0ary", 7) && !e.reliable);
    }

    // Oversized messages are refused up front instead of being silently truncated.
    CHECK(!client.send(std::string(kMaxPayload + 1, 'x'), true, err));
    CHECK(client.send(std::string(kMaxPayload, 'x'), true, err));

    // RTT gets measured.
    pump_until({&host, &client}, {&he, &ce}, [&] { return client.stats().rtt_ms > 0.0; }, 3000ms);
    CHECK(client.stats().rtt_ms > 0.0);
}

void test_reliable_under_loss() {
    Session host, client;
    std::vector<Event> he, ce;
    const uint16_t port = host_any(host, "Host");
    std::string err;
    CHECK(client.join("127.0.0.1", port, "Client", "", err));
    CHECK(pump_until({&host, &client}, {&he, &ce}, [&] { return client.state() == State::Connected; }));
    he.clear();
    ce.clear();

    host.set_simulated_loss(0.3f);
    client.set_simulated_loss(0.3f);

    constexpr int kCount = 1500;
    for (int i = 0; i < kCount; ++i) {
        CHECK(client.send("msg" + std::to_string(i), true, err));
        CHECK(host.send("rev" + std::to_string(i), true, err));
    }
    const bool done = pump_until({&host, &client}, {&he, &ce}, [&] {
        return count_type(he, Event::Type::Message) >= kCount && count_type(ce, Event::Type::Message) >= kCount;
    }, 20000ms);
    CHECK(done);

    // Exactly once, in order, both directions.
    int expected = 0;
    for (const auto& e : he) {
        if (e.type != Event::Type::Message) continue;
        CHECK(e.data == "msg" + std::to_string(expected));
        ++expected;
    }
    CHECK(expected == kCount);
    expected = 0;
    for (const auto& e : ce) {
        if (e.type != Event::Type::Message) continue;
        CHECK(e.data == "rev" + std::to_string(expected));
        ++expected;
    }
    CHECK(expected == kCount);
    CHECK(client.stats().resends > 0);

    // In-flight queue drains once everything is acknowledged.
    host.set_simulated_loss(0.0f);
    client.set_simulated_loss(0.0f);
    CHECK(pump_until({&host, &client}, {&he, &ce}, [&] {
        return client.stats().reliable_in_flight == 0 && host.stats().reliable_in_flight == 0;
    }, 5000ms));
}

void test_rejections_and_rejoin() {
    Session host, a, b, wrong;
    std::vector<Event> he, ae, be, we;
    const uint16_t port = host_any(host, "Host", "s3cret");
    std::string err;

    CHECK(wrong.join("127.0.0.1", port, "Wrong", "nope", err));
    CHECK(pump_until({&host, &wrong}, {&he, &we}, [&] { return find_type(we, Event::Type::Rejected) != nullptr; }));
    if (auto* e = find_type(we, Event::Type::Rejected)) CHECK(e->data.find("password") != std::string::npos);
    CHECK(wrong.state() == State::Idle);

    CHECK(a.join("127.0.0.1", port, "A", "s3cret", err));
    CHECK(pump_until({&host, &a}, {&he, &ae}, [&] { return a.state() == State::Connected; }));

    // A second join from the same IP (new nonce) means "partner restarted the game before the
    // old link timed out": the host replaces A with B instead of making them wait 10 s.
    CHECK(b.join("127.0.0.1", port, "B", "s3cret", err));
    CHECK(pump_until({&host, &a, &b}, {&he, &ae, &be}, [&] { return b.state() == State::Connected; }));
    CHECK(count_type(he, Event::Type::Disconnected) == 1);
    CHECK(host.stats().peer_name == "B");

    // Graceful leave: host is told immediately and goes back to listening.
    he.clear();
    b.stop();
    CHECK(pump_until({&host}, {&he}, [&] { return find_type(he, Event::Type::Disconnected) != nullptr; }));
    CHECK(host.state() == State::Listening);

    // And the same session object can join again.
    be.clear();
    CHECK(b.join("127.0.0.1", port, "B2", "s3cret", err));
    CHECK(pump_until({&host, &b}, {&he, &be}, [&] { return b.state() == State::Connected; }));
    CHECK(host.stats().peer_name == "B2");
}

// Sends a raw ConnectRequest and returns the host's reply header + reject reason.
bool raw_connect_request(UdpSocket& raw, uint16_t port, uint8_t version, uint32_t nonce, Header& h, uint8_t& reason) {
    std::string err;
    Writer w;
    w.u32(kMagic);
    w.u8(version);
    w.u8(static_cast<uint8_t>(PacketType::ConnectRequest));
    w.u32(0);
    w.u32(nonce);
    w.str("Raw");
    w.str("");
    Address host_addr{};
    if (!resolve("127.0.0.1", port, host_addr, err)) return false;
    raw.send_to(host_addr, w.data().data(), w.size());

    std::vector<uint8_t> buf(2048);
    Address from{};
    int n = 0;
    for (int i = 0; i < 200 && n <= 0; ++i) {
        raw.wait_readable(10);
        n = raw.recv_from(from, buf.data(), buf.size());
    }
    if (n <= 0) return false;
    Reader r(buf.data(), static_cast<size_t>(n));
    if (!read_header(r, h)) return false;
    if (r.u32() != nonce) return false;
    reason = h.type == PacketType::ConnectReject ? r.u8() : 0;
    return r.ok();
}

void test_version_mismatch_reject() {
    Session host;
    const uint16_t port = host_any(host, "Host");
    UdpSocket raw;
    std::string err;
    CHECK(raw.open(0, err));
    Header h;
    uint8_t reason = 0;
    CHECK(raw_connect_request(raw, port, kProtocolVersion + 1, 1234, h, reason)); // a future build
    CHECK(h.type == PacketType::ConnectReject);
    CHECK(reason == static_cast<uint8_t>(RejectReason::VersionMismatch));
    CHECK(host.state() == State::Listening);
}

#ifdef __linux__
// A partner on another machine is turned away while one is connected. Linux routes all of
// 127.0.0.0/8 to loopback, so a socket bound to 127.0.0.2 stands in for a second PC.
void test_session_full() {
    Session host, a;
    std::vector<Event> he, ae;
    const uint16_t port = host_any(host, "Host");
    std::string err;
    CHECK(a.join("127.0.0.1", port, "A", "", err));
    CHECK(pump_until({&host, &a}, {&he, &ae}, [&] { return a.state() == State::Connected; }));

    const int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    sockaddr_in bind_addr{};
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_addr.s_addr = inet_addr("127.0.0.2");
    CHECK(::bind(fd, reinterpret_cast<sockaddr*>(&bind_addr), sizeof(bind_addr)) == 0);

    Writer w;
    w.header(PacketType::ConnectRequest, 0);
    w.u32(777);
    w.str("Intruder");
    w.str("");
    sockaddr_in to{};
    to.sin_family = AF_INET;
    to.sin_addr.s_addr = inet_addr("127.0.0.1");
    to.sin_port = htons(port);
    ::sendto(fd, w.data().data(), w.size(), 0, reinterpret_cast<sockaddr*>(&to), sizeof(to));

    timeval tv{2, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    uint8_t buf[2048];
    const auto n = ::recv(fd, buf, sizeof(buf), 0);
    ::close(fd);
    CHECK(n > 0);
    Reader r(buf, static_cast<size_t>(n > 0 ? n : 0));
    Header h;
    CHECK(read_header(r, h));
    CHECK(h.type == PacketType::ConnectReject);
    CHECK(r.u32() == 777);
    CHECK(r.u8() == static_cast<uint8_t>(RejectReason::Full));
    CHECK(a.state() == State::Connected); // the real partner is unaffected
}
#else
void test_session_full() {
    std::printf("  skipped (needs a second loopback address)\n");
}
#endif

void test_timeouts() {
    Config fast;
    fast.timeout_s = 1.0;
    fast.connect_timeout_s = 1.0;

    // Nobody listening: the join fails with a helpful reason.
    {
        Session client(fast);
        std::vector<Event> ce;
        std::string err;
        CHECK(client.join("127.0.0.1", g_next_port++, "Lonely", "", err));
        CHECK(pump_until({&client}, {&ce}, [&] { return find_type(ce, Event::Type::Disconnected) != nullptr; }, 4000ms));
        if (auto* e = find_type(ce, Event::Type::Disconnected)) CHECK(e->data.find("could not reach host") != std::string::npos);
        CHECK(client.state() == State::Idle);
    }

    // Partner vanishes without saying goodbye (100% loss): both sides time out.
    {
        Session host(fast), client(fast);
        std::vector<Event> he, ce;
        const uint16_t port = host_any(host, "Host");
        std::string err;
        CHECK(client.join("127.0.0.1", port, "Client", "", err));
        CHECK(pump_until({&host, &client}, {&he, &ce}, [&] { return client.state() == State::Connected; }));
        host.set_simulated_loss(1.0f);
        client.set_simulated_loss(1.0f);
        CHECK(pump_until({&host, &client}, {&he, &ce}, [&] {
            return find_type(he, Event::Type::Disconnected) && find_type(ce, Event::Type::Disconnected);
        }, 4000ms));
        CHECK(host.state() == State::Listening);
        CHECK(client.state() == State::Idle);
    }
}

void test_local_addresses() {
    const auto addrs = local_ipv4_addresses();
    for (const auto& a : addrs) {
        CHECK(a.rfind("127.", 0) != 0);
        std::printf("  local address: %s\n", a.c_str());
    }
}

} // namespace

int main() {
    struct {
        const char* name;
        void (*fn)();
    } tests[] = {
        {"wire_roundtrip", test_wire_roundtrip},
        {"connect_and_exchange", test_connect_and_exchange},
        {"reliable_under_loss", test_reliable_under_loss},
        {"rejections_and_rejoin", test_rejections_and_rejoin},
        {"version_mismatch_reject", test_version_mismatch_reject},
        {"session_full", test_session_full},
        {"timeouts", test_timeouts},
        {"local_addresses", test_local_addresses},
    };
    for (const auto& t : tests) {
        const int before = g_failures;
        std::printf("[ RUN  ] %s\n", t.name);
        t.fn();
        std::printf("[ %s ] %s\n", g_failures == before ? " OK " : "FAIL", t.name);
    }
    if (g_failures != 0) {
        std::printf("%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("all native tests passed\n");
    return 0;
}
