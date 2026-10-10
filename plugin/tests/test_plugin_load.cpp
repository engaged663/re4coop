// Windows-only: loads re4coop_net.dll the way REFramework's PluginLoader does and checks it
// would be accepted and works on a Lua state owned by a *different* copy of Lua (as in the
// game, where REFramework links its own Lua and the plugin links another).
//   re4coop_test_plugin_load <path to re4coop_net.dll>
#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <cstring>

#include <reframework/API.h>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
}

namespace {

int g_failures = 0;
REFLuaStateCreatedCb g_lua_created = nullptr;

#define CHECK(cond)                                                                     \
    do {                                                                                \
        if (!(cond)) {                                                                  \
            std::fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            ++g_failures;                                                               \
        }                                                                               \
    } while (0)

bool on_lua_state_created(REFLuaStateCreatedCb cb) {
    g_lua_created = cb;
    return true;
}
bool on_lua_state_destroyed(REFLuaStateDestroyedCb) {
    return true;
}
void log_fn(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::vprintf(fmt, args);
    va_end(args);
    std::printf("\n");
}

// What REFramework reports to plugins for RE4. Pre-v2 builds: REFRAMEWORK_GAME_NAME = cmkr
// target name "RE4"; v2 universal build: GameIdentity::target_name() = "RE4".
constexpr const char* kReframeworkTargetName = "RE4";

const char* kLuaChecks = R"lua(
    assert(type(re4coop_net) == "table", "re4coop_net registered")
    local version = re4coop_net.version()
    assert(type(version) == "string", "version")

    -- A Lua error raised inside the plugin (its Lua copy) must unwind into our pcall
    -- (our Lua copy) cleanly - this is the longjmp-across-modules path.
    for i = 1, 200 do
        local ok, err = pcall(re4coop_net.host, "not a port")
        assert(not ok and tostring(err):find("number expected"), "argument error crosses the DLL boundary")
    end
    assert(re4coop_net.state() == "idle")

    -- Real UDP loopback through two plugin sessions.
    local host, client = re4coop_net.new_session(), re4coop_net.new_session()
    local port = 48000 + (os.time() % 1000)
    assert(host:host(port, "Host"))
    assert(client:join("127.0.0.1", port, "Client"))
    local got, deadline = nil, re4coop_net.time() + 5
    while got == nil and re4coop_net.time() < deadline do
        for _, ev in ipairs(client:poll()) do
            if ev.type == "connected" then client:send("ping from client", true) end
        end
        for _, ev in ipairs(host:poll()) do
            if ev.type == "message" then got = ev.data end
        end
    end
    assert(got == "ping from client", "loopback message")
    client:stop()
    host:stop()
    return version
)lua";

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <re4coop_net.dll>\n", argv[0]);
        return 2;
    }

    HMODULE mod = LoadLibraryA(argv[1]);
    if (mod == nullptr) {
        std::fprintf(stderr, "LoadLibrary failed (%lu)\n", GetLastError());
        return 1;
    }

    // 1. Version gate, mirroring PluginLoader::initialize_plugins().
    auto required = reinterpret_cast<REFPluginRequiredVersionFn>(reinterpret_cast<void*>(GetProcAddress(mod, "reframework_plugin_required_version")));
    CHECK(required != nullptr);
    REFrameworkPluginVersion v{};
    if (required != nullptr) required(&v);
    std::printf("plugin requires API %d.%d.%d for game '%s'\n", v.major, v.minor, v.patch, v.game_name ? v.game_name : "(any)");
    CHECK(v.major == REFRAMEWORK_PLUGIN_VERSION_MAJOR);
    CHECK(v.minor <= REFRAMEWORK_PLUGIN_VERSION_MINOR);
    CHECK(v.game_name == nullptr || std::strcmp(v.game_name, kReframeworkTargetName) == 0);

    // 2. Initialization with a minimal function table.
    REFrameworkPluginFunctions functions{};
    functions.on_lua_state_created = on_lua_state_created;
    functions.on_lua_state_destroyed = on_lua_state_destroyed;
    functions.log_error = log_fn;
    functions.log_warn = log_fn;
    functions.log_info = log_fn;
    REFrameworkPluginVersion framework_version{REFRAMEWORK_PLUGIN_VERSION_MAJOR, REFRAMEWORK_PLUGIN_VERSION_MINOR,
                                               REFRAMEWORK_PLUGIN_VERSION_PATCH, kReframeworkTargetName};
    REFrameworkPluginInitializeParam param{};
    param.reframework_module = nullptr;
    param.version = &framework_version;
    param.functions = &functions;

    auto init = reinterpret_cast<REFPluginInitializeFn>(reinterpret_cast<void*>(GetProcAddress(mod, "reframework_plugin_initialize")));
    CHECK(init != nullptr);
    CHECK(init != nullptr && init(&param));
    CHECK(g_lua_created != nullptr);

    // 3. ScriptRunner creates the main state and notifies plugins before running scripts.
    if (g_lua_created != nullptr) {
        lua_State* L = luaL_newstate();
        luaL_openlibs(L);
        g_lua_created(L);
        if (luaL_dostring(L, kLuaChecks) != LUA_OK) {
            std::fprintf(stderr, "Lua checks failed: %s\n", lua_tostring(L, -1));
            ++g_failures;
        } else {
            std::printf("plugin %s works on a foreign lua_State\n", lua_tostring(L, -1));
        }
        lua_close(L); // runs the plugin's __gc for the session objects
    }

    if (g_failures != 0) {
        std::printf("%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("plugin load test passed\n");
    return 0;
}
