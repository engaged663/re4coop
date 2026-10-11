// Two-player UDP session: one host, one client, connected directly by IP.
//
// A background thread owns the socket so heartbeats, acks and retransmits keep flowing
// even while the game is on a loading screen and Lua is not ticking. The game thread only
// calls send()/poll()/stats(), which exchange data with the network thread under a mutex.
#pragma once

#include "socket.hpp"
#include "wire.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <random>
#include <set>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace re4coop::net {

enum class State { Idle, Listening, Connecting, Connected };
enum class Role { None, Host, Client };

const char* to_string(State s);
const char* to_string(Role r);

struct Event {
    enum class Type { Connected, Disconnected, Rejected, Message };
    Type type{Type::Message};
    bool reliable{false};
    std::string data; // message payload, or human-readable reason for Disconnected/Rejected
    std::string peer; // "ip:port"
    std::string name; // peer display name (Connected only)
};

struct Stats {
    State state{State::Idle};
    Role role{Role::None};
    uint16_t local_port{0};
    std::string peer;
    std::string peer_name;
    double rtt_ms{0.0};
    double since_last_recv_s{0.0};
    uint64_t packets_sent{0};
    uint64_t packets_recv{0};
    uint64_t bytes_sent{0};
    uint64_t bytes_recv{0};
    uint64_t resends{0};
    uint64_t unreliable_out_of_order{0};
    uint64_t unordered_duplicates{0};
    uint64_t events_dropped{0};
    size_t reliable_in_flight{0};
};

struct Config {
    double timeout_s{10.0};         // no packets from the peer for this long = disconnected
    double connect_timeout_s{10.0}; // client gives up joining after this long
    double connect_retry_s{0.25};
    double ping_interval_s{0.5};
    double min_rto_s{0.05};
    double max_rto_s{1.0};
    size_t max_reliable_in_flight{2048};
    size_t max_queued_events{16384};
    int poll_interval_ms{4};
};

class Session {
public:
    using Clock = std::chrono::steady_clock;

    explicit Session(Config cfg = {});
    ~Session();
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;

    // Starts listening for one partner on UDP `port`.
    bool host(uint16_t port, const std::string& name, const std::string& password, std::string& err);
    // Starts connecting to a host. Completion is reported through poll() as Connected/Rejected/Disconnected.
    bool join(const std::string& address, uint16_t port, const std::string& name, const std::string& password, std::string& err);
    // Politely disconnects (if connected) and stops the network thread. Safe to call any time.
    void stop();

    // Queues one message for the peer. Reliable messages are delivered exactly once, in order.
    // Unreliable messages may be dropped or reordered; use them for state that is resent anyway.
    // unordered (reliable only): delivered exactly once as soon as it arrives, on a lane of its
    // own, so a lost packet there never holds back the ordered messages (and vice versa).
    bool send(std::string_view payload, bool reliable, std::string& err, bool unordered = false);

    std::vector<Event> poll(size_t max_events = SIZE_MAX);
    Stats stats() const;
    State state() const;
    Role role() const;

    // Test hook: drop this fraction of received datagrams (0..1) to exercise retransmission.
    void set_simulated_loss(float fraction);

private:
    struct PendingReliable {
        uint16_t seq{0};
        std::vector<uint8_t> packet;
        Clock::time_point last_sent{};
        double rto_s{0.0}; // doubles with every resend of this packet (backoff)
    };

    bool start_thread(std::string& err);
    void run();
    void tick_locked(Clock::time_point now);
    void handle_datagram_locked(const Address& from, const uint8_t* data, size_t len, Clock::time_point now);
    void handle_connect_request_locked(const Address& from, const Header& h, Reader& r, Clock::time_point now);
    void handle_peer_packet_locked(const Header& h, Reader& r, Clock::time_point now);
    void deliver_reliable_locked(uint16_t seq, const uint8_t* data, size_t len);
    void deliver_unordered_locked(uint16_t seq, const uint8_t* data, size_t len);
    void resend_locked(std::deque<PendingReliable>& queue, Clock::time_point now);
    void send_acks_locked(PacketType type, std::vector<uint16_t>& acks);
    void send_raw_locked(const Address& to, const std::vector<uint8_t>& bytes);
    void send_simple_locked(PacketType type);
    void flush_acks_locked();
    void push_event_locked(Event e);
    void reset_link_locked();
    void lose_peer_locked(const std::string& reason);
    double rto_s_locked() const;

    const Config m_cfg;

    mutable std::mutex m_mutex;
    std::thread m_thread;
    std::atomic<bool> m_running{false};
    UdpSocket m_socket;
    bool m_wsa_started{false};

    // Everything below is guarded by m_mutex.
    State m_state{State::Idle};
    Role m_role{Role::None};
    std::string m_local_name;
    std::string m_password;
    Address m_peer{};
    std::string m_peer_name;
    uint32_t m_token{0};
    uint32_t m_nonce{0};

    Clock::time_point m_connect_started{};
    Clock::time_point m_last_connect_attempt{};
    Clock::time_point m_last_recv{};
    Clock::time_point m_last_ping{};
    uint32_t m_next_ping_id{1};
    double m_srtt_s{0.1};
    bool m_have_rtt{false};

    uint16_t m_next_reliable_seq{0};
    std::deque<PendingReliable> m_unacked;
    uint16_t m_next_expected_seq{0};
    std::map<uint16_t, std::string> m_reorder; // out-of-order reliable payloads, keyed by absolute seq
    std::vector<uint16_t> m_pending_acks;

    uint16_t m_next_unordered_seq{0};
    std::deque<PendingReliable> m_unacked_unordered;
    uint16_t m_unordered_base{0};             // lowest unordered seq not delivered yet
    std::set<uint16_t> m_unordered_seen;      // delivered seqs ahead of m_unordered_base
    std::vector<uint16_t> m_pending_unordered_acks;

    uint16_t m_next_unreliable_seq{0};
    uint16_t m_last_unreliable_seq{0};
    bool m_have_unreliable{false};

    std::deque<Event> m_events;
    Stats m_stats{};
    float m_simulated_loss{0.0f};
    std::mt19937 m_rng;
};

} // namespace re4coop::net
