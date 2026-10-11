#include "lua_api.hpp"

#include "net/session.hpp"

#include <chrono>
#include <cstring>
#include <exception>
#include <string>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

namespace re4coop {

namespace {

// Lives for the whole process and survives REFramework script resets ("Reset Scripts"
// destroys and recreates the Lua state; the partner should not be dropped because of it).
// Intentionally leaked: joining threads from static destructors during process exit is
// asking for loader-lock trouble on Windows.
net::Session& session() {
    static auto* s = new net::Session();
    return *s;
}

int push_fail(lua_State* L, const std::string& err) {
    lua_pushnil(L);
    lua_pushlstring(L, err.data(), err.size());
    return 2;
}

void set_string(lua_State* L, const char* key, const std::string& value) {
    lua_pushlstring(L, value.data(), value.size());
    lua_setfield(L, -2, key);
}

void set_number(lua_State* L, const char* key, double value) {
    lua_pushnumber(L, value);
    lua_setfield(L, -2, key);
}

void set_integer(lua_State* L, const char* key, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, key);
}

uint16_t check_port(lua_State* L, int idx) {
    const lua_Integer port = luaL_checkinteger(L, idx);
    luaL_argcheck(L, port >= 1 && port <= 65535, idx, "port must be 1-65535");
    return static_cast<uint16_t>(port);
}

// Binding rule: every luaL_check*/luaL_opt* (which may longjmp on bad arguments) runs before
// any C++ object with a destructor is alive in the frame. REFramework builds Lua as C, so
// Lua errors unwind with longjmp, which does not reliably run C++ destructors.

// host(port, name, password) -> true | nil, err
int do_host(lua_State* L, net::Session& s, int b) {
    const uint16_t port = check_port(L, b);
    const char* name = luaL_optstring(L, b + 1, "Host");
    const char* password = luaL_optstring(L, b + 2, "");
    std::string err;
    if (!s.host(port, name, password, err)) return push_fail(L, err);
    lua_pushboolean(L, 1);
    return 1;
}

// join(address, port, name, password) -> true | nil, err
int do_join(lua_State* L, net::Session& s, int b) {
    const char* address = luaL_checkstring(L, b);
    const uint16_t port = check_port(L, b + 1);
    const char* name = luaL_optstring(L, b + 2, "Partner");
    const char* password = luaL_optstring(L, b + 3, "");
    std::string err;
    if (!s.join(address, port, name, password, err)) return push_fail(L, err);
    lua_pushboolean(L, 1);
    return 1;
}

int do_stop(lua_State*, net::Session& s, int) {
    s.stop();
    return 0;
}

// send(data, reliable[, unordered]) -> true | nil, err
int do_send(lua_State* L, net::Session& s, int b) {
    size_t len = 0;
    const char* data = luaL_checklstring(L, b, &len);
    const bool reliable = lua_toboolean(L, b + 1) != 0;
    const bool unordered = lua_toboolean(L, b + 2) != 0;
    std::string err;
    if (!s.send(std::string_view(data, len), reliable, err, unordered)) return push_fail(L, err);
    lua_pushboolean(L, 1);
    return 1;
}

// poll([max]) -> { {type=..., data=..., reliable=..., peer=..., name=...}, ... }
int do_poll(lua_State* L, net::Session& s, int b) {
    const lua_Integer max = luaL_optinteger(L, b, 0);
    auto events = s.poll(max > 0 ? static_cast<size_t>(max) : SIZE_MAX);

    lua_createtable(L, static_cast<int>(events.size()), 0);
    lua_Integer i = 1;
    for (const auto& e : events) {
        lua_createtable(L, 0, 5);
        switch (e.type) {
        case net::Event::Type::Connected: set_string(L, "type", "connected"); break;
        case net::Event::Type::Disconnected: set_string(L, "type", "disconnected"); break;
        case net::Event::Type::Rejected: set_string(L, "type", "rejected"); break;
        case net::Event::Type::Message: set_string(L, "type", "message"); break;
        }
        set_string(L, "data", e.data);
        lua_pushboolean(L, e.reliable ? 1 : 0);
        lua_setfield(L, -2, "reliable");
        if (!e.peer.empty()) set_string(L, "peer", e.peer);
        if (!e.name.empty()) set_string(L, "name", e.name);
        lua_rawseti(L, -2, i++);
    }
    return 1;
}

int do_state(lua_State* L, net::Session& s, int) {
    lua_pushstring(L, net::to_string(s.state()));
    return 1;
}

int do_role(lua_State* L, net::Session& s, int) {
    lua_pushstring(L, net::to_string(s.role()));
    return 1;
}

int do_stats(lua_State* L, net::Session& session, int) {
    const auto s = session.stats();
    lua_createtable(L, 0, 16);
    set_string(L, "state", net::to_string(s.state));
    set_string(L, "role", net::to_string(s.role));
    set_integer(L, "local_port", s.local_port);
    set_string(L, "peer", s.peer);
    set_string(L, "peer_name", s.peer_name);
    set_number(L, "rtt_ms", s.rtt_ms);
    set_number(L, "since_last_recv", s.since_last_recv_s);
    set_integer(L, "packets_sent", static_cast<lua_Integer>(s.packets_sent));
    set_integer(L, "packets_recv", static_cast<lua_Integer>(s.packets_recv));
    set_integer(L, "bytes_sent", static_cast<lua_Integer>(s.bytes_sent));
    set_integer(L, "bytes_recv", static_cast<lua_Integer>(s.bytes_recv));
    set_integer(L, "resends", static_cast<lua_Integer>(s.resends));
    set_integer(L, "out_of_order", static_cast<lua_Integer>(s.unreliable_out_of_order));
    set_integer(L, "unordered_duplicates", static_cast<lua_Integer>(s.unordered_duplicates));
    set_integer(L, "events_dropped", static_cast<lua_Integer>(s.events_dropped));
    set_integer(L, "reliable_in_flight", static_cast<lua_Integer>(s.reliable_in_flight));
    return 1;
}

int l_local_addresses(lua_State* L) {
    const auto addrs = net::local_ipv4_addresses();
    lua_createtable(L, static_cast<int>(addrs.size()), 0);
    lua_Integer i = 1;
    for (const auto& a : addrs) {
        lua_pushlstring(L, a.data(), a.size());
        lua_rawseti(L, -2, i++);
    }
    return 1;
}

// Monotonic wall-clock seconds. Scripts need this because os.clock() measures CPU time.
int l_time(lua_State* L) {
    static const auto start = std::chrono::steady_clock::now();
    lua_pushnumber(L, std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count());
    return 1;
}

int l_max_payload(lua_State* L) {
    lua_pushinteger(L, static_cast<lua_Integer>(net::kMaxPayload));
    return 1;
}

int l_version(lua_State* L) {
    lua_pushstring(L, kVersion);
    lua_pushinteger(L, net::kProtocolVersion);
    return 2;
}

int do_set_simulated_loss(lua_State* L, net::Session& s, int b) {
    s.set_simulated_loss(static_cast<float>(luaL_checknumber(L, b)));
    return 0;
}

using SessionFn = int (*)(lua_State*, net::Session&, int);

// C++ exceptions must not cross into Lua's C frames: report them as `nil, message` instead.
// (A fixed buffer, not std::string, so nothing needs destroying if Fn raises a Lua error.)
template <SessionFn Fn> int guarded(lua_State* L, net::Session& s, int base) {
    char message[256] = "unknown C++ exception";
    try {
        return Fn(L, s, base);
    } catch (const std::exception& e) {
        std::strncpy(message, e.what(), sizeof(message) - 1);
        message[sizeof(message) - 1] = '\0';
    } catch (...) {
    }
    lua_pushnil(L);
    lua_pushstring(L, message);
    return 2;
}

// Module functions act on the process-wide session the game uses.
template <SessionFn Fn> int module_fn(lua_State* L) {
    return guarded<Fn>(L, session(), 1);
}

constexpr const char* kSessionMeta = "re4coop.Session";

struct SessionBox {
    net::Session* session;
};

// Methods act on an extra session made by new_session() (tests and tools).
template <SessionFn Fn> int method_fn(lua_State* L) {
    auto* box = static_cast<SessionBox*>(luaL_checkudata(L, 1, kSessionMeta));
    luaL_argcheck(L, box->session != nullptr, 1, "session already destroyed");
    return guarded<Fn>(L, *box->session, 2);
}

int l_session_gc(lua_State* L) {
    auto* box = static_cast<SessionBox*>(luaL_checkudata(L, 1, kSessionMeta));
    delete box->session; // stops the thread
    box->session = nullptr;
    return 0;
}

const luaL_Reg kSessionMethods[] = {
    {"host", method_fn<do_host>},
    {"join", method_fn<do_join>},
    {"stop", method_fn<do_stop>},
    {"send", method_fn<do_send>},
    {"poll", method_fn<do_poll>},
    {"state", method_fn<do_state>},
    {"role", method_fn<do_role>},
    {"stats", method_fn<do_stats>},
    {"set_simulated_loss", method_fn<do_set_simulated_loss>},
    {nullptr, nullptr},
};

// re4coop_net.new_session() -> independent Session object (closed when garbage collected)
int l_new_session(lua_State* L) {
    auto* box = static_cast<SessionBox*>(lua_newuserdatauv(L, sizeof(SessionBox), 0));
    box->session = nullptr;
    if (luaL_newmetatable(L, kSessionMeta)) {
        luaL_newlib(L, kSessionMethods);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, l_session_gc);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, l_session_gc);
        lua_setfield(L, -2, "__close");
    }
    lua_setmetatable(L, -2);
    try {
        box->session = new net::Session();
    } catch (...) {
        lua_pushnil(L);
        lua_pushstring(L, "could not create session");
        return 2;
    }
    return 1;
}

const luaL_Reg kFunctions[] = {
    {"host", module_fn<do_host>},
    {"join", module_fn<do_join>},
    {"stop", module_fn<do_stop>},
    {"send", module_fn<do_send>},
    {"poll", module_fn<do_poll>},
    {"state", module_fn<do_state>},
    {"role", module_fn<do_role>},
    {"stats", module_fn<do_stats>},
    {"set_simulated_loss", module_fn<do_set_simulated_loss>},
    {"local_addresses", l_local_addresses},
    {"time", l_time},
    {"max_payload", l_max_payload},
    {"version", l_version},
    {"new_session", l_new_session},
    {nullptr, nullptr},
};

} // namespace

int open_lua_api(lua_State* L) {
    luaL_newlib(L, kFunctions);
    return 1;
}

void register_lua_api(lua_State* L) {
    open_lua_api(L);
    lua_setglobal(L, "re4coop_net");
}

} // namespace re4coop
