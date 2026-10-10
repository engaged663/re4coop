#include "session.hpp"

#include <algorithm>

namespace re4coop::net {

namespace {

constexpr size_t kReorderWindow = 4096;
constexpr int kDisconnectRepeats = 3;

double seconds(Session::Clock::duration d) {
    return std::chrono::duration<double>(d).count();
}

uint64_t micros(Session::Clock::time_point t) {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(t.time_since_epoch()).count());
}

const char* reject_text(RejectReason r) {
    switch (r) {
    case RejectReason::Full: return "the host already has a partner connected";
    case RejectReason::BadPassword: return "wrong session password";
    case RejectReason::VersionMismatch: return "the host runs an incompatible re4coop network protocol version";
    }
    return "rejected by host";
}

const char* disconnect_text(DisconnectReason r) {
    switch (r) {
    case DisconnectReason::Requested: return "partner left the session";
    case DisconnectReason::Timeout: return "partner timed out";
    case DisconnectReason::Kicked: return "removed by host";
    }
    return "partner disconnected";
}

} // namespace

const char* to_string(State s) {
    switch (s) {
    case State::Idle: return "idle";
    case State::Listening: return "listening";
    case State::Connecting: return "connecting";
    case State::Connected: return "connected";
    }
    return "unknown";
}

const char* to_string(Role r) {
    switch (r) {
    case Role::None: return "none";
    case Role::Host: return "host";
    case Role::Client: return "client";
    }
    return "unknown";
}

Session::Session(Config cfg) : m_cfg(cfg), m_rng(std::random_device{}()) {}

Session::~Session() {
    stop();
}

bool Session::host(uint16_t port, const std::string& name, const std::string& password, std::string& err) {
    if (!m_running) {
        stop(); // reap a previous session whose thread ended by itself (timeout/rejection)
    }
    if (m_running) {
        err = "a session is already active; stop it first";
        return false;
    }
    if (port == 0) {
        err = "port must be between 1 and 65535";
        return false;
    }
    if (!startup(err)) return false;
    m_wsa_started = true;
    if (!m_socket.open(port, err)) {
        cleanup();
        m_wsa_started = false;
        return false;
    }

    {
        std::scoped_lock _{m_mutex};
        reset_link_locked();
        m_role = Role::Host;
        m_state = State::Listening;
        m_local_name = name;
        m_password = password;
        m_stats = Stats{};
    }
    return start_thread(err);
}

bool Session::join(const std::string& address, uint16_t port, const std::string& name, const std::string& password, std::string& err) {
    if (!m_running) {
        stop();
    }
    if (m_running) {
        err = "a session is already active; stop it first";
        return false;
    }
    if (port == 0) {
        err = "port must be between 1 and 65535";
        return false;
    }
    if (!startup(err)) return false;
    m_wsa_started = true;

    Address target{};
    if (!resolve(address, port, target, err) || !m_socket.open(0, err)) {
        cleanup();
        m_wsa_started = false;
        return false;
    }

    {
        std::scoped_lock _{m_mutex};
        reset_link_locked();
        m_role = Role::Client;
        m_state = State::Connecting;
        m_local_name = name;
        m_password = password;
        m_peer = target;
        m_nonce = m_rng() | 1u;
        m_connect_started = Clock::now();
        m_last_connect_attempt = Clock::time_point{};
        m_stats = Stats{};
    }
    return start_thread(err);
}

bool Session::start_thread(std::string& err) {
    try {
        m_running = true;
        m_thread = std::thread([this] { run(); });
    } catch (const std::exception& e) {
        m_running = false;
        err = std::string("could not start network thread: ") + e.what();
        m_socket.close();
        if (m_wsa_started) {
            cleanup();
            m_wsa_started = false;
        }
        std::scoped_lock _{m_mutex};
        m_state = State::Idle;
        m_role = Role::None;
        return false;
    }
    return true;
}

void Session::stop() {
    {
        std::scoped_lock _{m_mutex};
        if (m_state == State::Connected) {
            for (int i = 0; i < kDisconnectRepeats; ++i) {
                Writer w;
                w.header(PacketType::Disconnect, m_token);
                w.u8(static_cast<uint8_t>(DisconnectReason::Requested));
                send_raw_locked(m_peer, w.data());
            }
        }
    }

    m_running = false;
    if (m_thread.joinable()) {
        m_thread.join();
    }
    m_socket.close();
    if (m_wsa_started) {
        cleanup();
        m_wsa_started = false;
    }

    std::scoped_lock _{m_mutex};
    reset_link_locked();
    m_state = State::Idle;
    m_role = Role::None;
    m_events.clear();
}

bool Session::send(std::string_view payload, bool reliable, std::string& err) {
    std::scoped_lock _{m_mutex};
    if (m_state != State::Connected) {
        err = "not connected";
        return false;
    }
    if (payload.size() > kMaxPayload) {
        err = "message too large (" + std::to_string(payload.size()) + " > " + std::to_string(kMaxPayload) + " bytes)";
        return false;
    }

    Writer w;
    if (reliable) {
        if (m_unacked.size() >= m_cfg.max_reliable_in_flight) {
            err = "reliable send queue is full (partner not acknowledging)";
            return false;
        }
        PendingReliable p;
        p.seq = m_next_reliable_seq++;
        w.header(PacketType::Reliable, m_token);
        w.u16(p.seq);
        w.bytes(payload.data(), payload.size());
        p.packet = w.data();
        p.last_sent = Clock::now();
        send_raw_locked(m_peer, p.packet);
        m_unacked.push_back(std::move(p));
    } else {
        w.header(PacketType::Unreliable, m_token);
        w.u16(m_next_unreliable_seq++);
        w.bytes(payload.data(), payload.size());
        send_raw_locked(m_peer, w.data());
    }
    return true;
}

std::vector<Event> Session::poll(size_t max_events) {
    std::scoped_lock _{m_mutex};
    std::vector<Event> out;
    const size_t n = std::min(max_events, m_events.size());
    out.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        out.push_back(std::move(m_events.front()));
        m_events.pop_front();
    }
    return out;
}

Stats Session::stats() const {
    std::scoped_lock _{m_mutex};
    Stats s = m_stats;
    s.state = m_state;
    s.role = m_role;
    s.local_port = m_socket.local_port();
    s.peer = (m_state == State::Connected || m_state == State::Connecting) ? m_peer.to_string() : std::string{};
    s.peer_name = m_state == State::Connected ? m_peer_name : std::string{};
    s.rtt_ms = m_have_rtt ? m_srtt_s * 1000.0 : 0.0;
    s.since_last_recv_s = m_state == State::Connected ? seconds(Clock::now() - m_last_recv) : 0.0;
    s.reliable_in_flight = m_unacked.size();
    return s;
}

State Session::state() const {
    std::scoped_lock _{m_mutex};
    return m_state;
}

Role Session::role() const {
    std::scoped_lock _{m_mutex};
    return m_role;
}

void Session::set_simulated_loss(float fraction) {
    std::scoped_lock _{m_mutex};
    m_simulated_loss = std::clamp(fraction, 0.0f, 1.0f);
}

void Session::run() {
    std::vector<uint8_t> buf(65536);
    while (m_running) {
        m_socket.wait_readable(m_cfg.poll_interval_ms);

        std::scoped_lock _{m_mutex};
        const auto now = Clock::now();
        for (int i = 0; i < 256; ++i) { // bounded so tick() still runs under a flood
            Address from{};
            const int n = m_socket.recv_from(from, buf.data(), buf.size());
            if (n <= 0) break;
            if (m_simulated_loss > 0.0f && std::uniform_real_distribution<float>(0.0f, 1.0f)(m_rng) < m_simulated_loss) {
                continue;
            }
            handle_datagram_locked(from, buf.data(), static_cast<size_t>(n), now);
        }
        tick_locked(now);
        flush_acks_locked();
    }
}

void Session::tick_locked(Clock::time_point now) {
    switch (m_state) {
    case State::Connecting:
        if (seconds(now - m_connect_started) > m_cfg.connect_timeout_s) {
            Event e;
            e.type = Event::Type::Disconnected;
            e.peer = m_peer.to_string();
            e.data = "could not reach host at " + m_peer.to_string() +
                     " (check the IP/port, that the host clicked Host, and the host's firewall)";
            push_event_locked(std::move(e));
            m_state = State::Idle;
            m_running = false; // client sessions end here; the socket is closed by stop()
            return;
        }
        if (seconds(now - m_last_connect_attempt) >= m_cfg.connect_retry_s) {
            Writer w;
            w.header(PacketType::ConnectRequest, 0);
            w.u32(m_nonce);
            w.str(m_local_name);
            w.str(m_password);
            send_raw_locked(m_peer, w.data());
            m_last_connect_attempt = now;
        }
        break;

    case State::Connected: {
        if (seconds(now - m_last_recv) > m_cfg.timeout_s) {
            lose_peer_locked(disconnect_text(DisconnectReason::Timeout));
            return;
        }
        if (seconds(now - m_last_ping) >= m_cfg.ping_interval_s) {
            Writer w;
            w.header(PacketType::Ping, m_token);
            w.u32(m_next_ping_id++);
            w.u64(micros(now));
            send_raw_locked(m_peer, w.data());
            m_last_ping = now;
        }
        const double rto = rto_s_locked();
        for (auto& p : m_unacked) {
            if (seconds(now - p.last_sent) >= rto) {
                send_raw_locked(m_peer, p.packet);
                p.last_sent = now;
                ++m_stats.resends;
            }
        }
        break;
    }

    case State::Idle:
    case State::Listening:
        break;
    }
}

void Session::handle_datagram_locked(const Address& from, const uint8_t* data, size_t len, Clock::time_point now) {
    Reader r(data, len);
    Header h;
    if (!read_header(r, h)) return; // not ours

    ++m_stats.packets_recv;
    m_stats.bytes_recv += len;

    if (h.type == PacketType::ConnectRequest) {
        if (m_role == Role::Host) {
            handle_connect_request_locked(from, h, r, now);
        }
        return;
    }
    if (m_role == Role::Client && m_state == State::Connecting && from == m_peer) {
        if (h.type == PacketType::ConnectAccept && h.version == kProtocolVersion) {
            const uint32_t nonce = r.u32();
            std::string host_name = r.str();
            if (!r.ok() || nonce != m_nonce || h.token == 0) return;
            m_token = h.token;
            m_peer_name = std::move(host_name);
            m_state = State::Connected;
            m_last_recv = now;
            m_last_ping = Clock::time_point{};
            Event e;
            e.type = Event::Type::Connected;
            e.peer = m_peer.to_string();
            e.name = m_peer_name;
            push_event_locked(std::move(e));
        } else if (h.type == PacketType::ConnectReject) {
            const uint32_t nonce = r.u32();
            const auto reason = static_cast<RejectReason>(r.u8());
            std::string message = r.str();
            if (!r.ok() || nonce != m_nonce) return;
            Event e;
            e.type = Event::Type::Rejected;
            e.peer = m_peer.to_string();
            e.data = message.empty() ? reject_text(reason) : message;
            push_event_locked(std::move(e));
            m_state = State::Idle;
            m_running = false;
        }
        return;
    }

    if (h.version != kProtocolVersion) return;
    if (m_state == State::Connected && from == m_peer && h.token == m_token) {
        m_last_recv = now;
        handle_peer_packet_locked(h, r, now);
    }
}

void Session::handle_connect_request_locked(const Address& from, const Header& h, Reader& r, Clock::time_point now) {
    const uint32_t nonce = r.u32();
    const std::string name = r.str();
    const std::string password = r.str();

    auto reject = [&](RejectReason reason) {
        Writer w;
        // Clients accept a rejection whatever its header version, so mismatched builds still learn why.
        w.header(PacketType::ConnectReject, 0);
        w.u32(nonce);
        w.u8(static_cast<uint8_t>(reason));
        w.str(reject_text(reason));
        send_raw_locked(from, w.data());
    };

    if (h.version != kProtocolVersion) {
        reject(RejectReason::VersionMismatch);
        return;
    }
    if (!r.ok()) return;
    if (m_state != State::Listening && m_state != State::Connected) return;

    if (!m_password.empty() && password != m_password) {
        reject(RejectReason::BadPassword);
        return;
    }

    if (m_state == State::Connected && from.ip == m_peer.ip && nonce != m_nonce) {
        lose_peer_locked("partner reconnected"); // back to Listening, then accept below
    }
    if (m_state == State::Connected) {
        if (from == m_peer && nonce == m_nonce) {
            // Our accept got lost; repeat it.
            Writer w;
            w.header(PacketType::ConnectAccept, m_token);
            w.u32(nonce);
            w.str(m_local_name);
            send_raw_locked(from, w.data());
        } else {
            reject(RejectReason::Full);
        }
        return;
    }

    reset_link_locked();
    m_peer = from;
    m_peer_name = name;
    m_nonce = nonce;
    do {
        m_token = m_rng();
    } while (m_token == 0);
    m_state = State::Connected;
    m_last_recv = now;
    m_last_ping = Clock::time_point{};

    Writer w;
    w.header(PacketType::ConnectAccept, m_token);
    w.u32(nonce);
    w.str(m_local_name);
    send_raw_locked(from, w.data());

    Event e;
    e.type = Event::Type::Connected;
    e.peer = from.to_string();
    e.name = name;
    push_event_locked(std::move(e));
}

void Session::handle_peer_packet_locked(const Header& h, Reader& r, Clock::time_point now) {
    switch (h.type) {
    case PacketType::Ping: {
        const uint32_t id = r.u32();
        const uint64_t t = r.u64();
        if (!r.ok()) return;
        Writer w;
        w.header(PacketType::Pong, m_token);
        w.u32(id);
        w.u64(t);
        send_raw_locked(m_peer, w.data());
        break;
    }
    case PacketType::Pong: {
        r.u32();
        const uint64_t t = r.u64();
        if (!r.ok()) return;
        const uint64_t now_us = micros(now);
        if (t > now_us) return;
        const double sample = static_cast<double>(now_us - t) / 1e6;
        m_srtt_s = m_have_rtt ? (0.875 * m_srtt_s + 0.125 * sample) : sample;
        m_have_rtt = true;
        break;
    }
    case PacketType::Reliable: {
        const uint16_t seq = r.u16();
        if (!r.ok()) return;
        m_pending_acks.push_back(seq);
        deliver_reliable_locked(seq, r.cursor(), r.remaining());
        break;
    }
    case PacketType::Unreliable: {
        const uint16_t seq = r.u16();
        if (!r.ok()) return;
        if (m_have_unreliable && !seq_newer(seq, m_last_unreliable_seq)) {
            ++m_stats.unreliable_out_of_order;
        } else {
            m_last_unreliable_seq = seq;
            m_have_unreliable = true;
        }
        Event e;
        e.type = Event::Type::Message;
        e.reliable = false;
        e.data.assign(reinterpret_cast<const char*>(r.cursor()), r.remaining());
        push_event_locked(std::move(e));
        break;
    }
    case PacketType::Ack: {
        const uint8_t count = r.u8();
        for (uint8_t i = 0; i < count; ++i) {
            const uint16_t seq = r.u16();
            if (!r.ok()) return;
            auto it = std::find_if(m_unacked.begin(), m_unacked.end(), [seq](const PendingReliable& p) { return p.seq == seq; });
            if (it != m_unacked.end()) {
                m_unacked.erase(it);
            }
        }
        break;
    }
    case PacketType::Disconnect: {
        const auto reason = static_cast<DisconnectReason>(r.u8());
        lose_peer_locked(disconnect_text(reason));
        break;
    }
    case PacketType::ConnectAccept:
    case PacketType::ConnectReject:
    case PacketType::ConnectRequest:
        break;
    }
}

void Session::deliver_reliable_locked(uint16_t seq, const uint8_t* data, size_t len) {
    const uint16_t ahead = static_cast<uint16_t>(seq - m_next_expected_seq);
    if (ahead >= kReorderWindow) {
        return; // duplicate of something already delivered (or absurdly far ahead)
    }

    std::string payload(reinterpret_cast<const char*>(data), len);
    if (ahead != 0) {
        m_reorder.emplace(seq, std::move(payload)); // no-op if already buffered
        return;
    }

    auto emit = [this](std::string&& p) {
        Event e;
        e.type = Event::Type::Message;
        e.reliable = true;
        e.data = std::move(p);
        push_event_locked(std::move(e));
    };

    emit(std::move(payload));
    ++m_next_expected_seq;
    for (auto it = m_reorder.find(m_next_expected_seq); it != m_reorder.end(); it = m_reorder.find(m_next_expected_seq)) {
        emit(std::move(it->second));
        m_reorder.erase(it);
        ++m_next_expected_seq;
    }
}

void Session::flush_acks_locked() {
    if (m_pending_acks.empty() || m_state != State::Connected) {
        m_pending_acks.clear();
        return;
    }
    size_t i = 0;
    while (i < m_pending_acks.size()) {
        const size_t n = std::min<size_t>(255, m_pending_acks.size() - i);
        Writer w;
        w.header(PacketType::Ack, m_token);
        w.u8(static_cast<uint8_t>(n));
        for (size_t k = 0; k < n; ++k) {
            w.u16(m_pending_acks[i + k]);
        }
        send_raw_locked(m_peer, w.data());
        i += n;
    }
    m_pending_acks.clear();
}

void Session::send_raw_locked(const Address& to, const std::vector<uint8_t>& bytes) {
    if (m_socket.send_to(to, bytes.data(), bytes.size()) > 0) {
        ++m_stats.packets_sent;
        m_stats.bytes_sent += bytes.size();
    }
}

void Session::push_event_locked(Event e) {
    if (m_events.size() >= m_cfg.max_queued_events) {
        // Lua is not draining (scripts disabled?). Drop the oldest unreliable message first.
        auto it = std::find_if(m_events.begin(), m_events.end(),
                               [](const Event& ev) { return ev.type == Event::Type::Message && !ev.reliable; });
        if (it == m_events.end()) it = m_events.begin();
        m_events.erase(it);
        ++m_stats.events_dropped;
    }
    m_events.push_back(std::move(e));
}

void Session::reset_link_locked() {
    m_peer = Address{};
    m_peer_name.clear();
    m_token = 0;
    m_nonce = 0;
    m_srtt_s = 0.1;
    m_have_rtt = false;
    m_next_reliable_seq = 0;
    m_unacked.clear();
    m_next_expected_seq = 0;
    m_reorder.clear();
    m_pending_acks.clear();
    m_next_unreliable_seq = 0;
    m_last_unreliable_seq = 0;
    m_have_unreliable = false;
}

void Session::lose_peer_locked(const std::string& reason) {
    Event e;
    e.type = Event::Type::Disconnected;
    e.peer = m_peer.to_string();
    e.data = reason;
    push_event_locked(std::move(e));

    reset_link_locked();
    if (m_role == Role::Host) {
        m_state = State::Listening; // keep hosting so the partner can rejoin
    } else {
        m_state = State::Idle;
        m_running = false;
    }
}

double Session::rto_s_locked() const {
    return std::clamp(m_srtt_s * 2.0 + 0.01, m_cfg.min_rto_s, m_cfg.max_rto_s);
}

} // namespace re4coop::net
