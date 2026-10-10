// Runs a Lua test script outside the game:
//   re4coop_lua_runner <repo root> <script.lua>
// The state mirrors what REFramework gives autorun scripts as closely as is useful:
// the same Lua 5.4.3, no `io` library, the mod's modules on package.path, and the real
// `re4coop_net` bindings registered as a global. Game APIs (sdk, re, imgui, draw) are
// provided by the test scripts themselves through tests/lua/mock_reframework.lua.
#include "lua_api.hpp"

#include <cstdio>
#include <string>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
}

namespace {

int traceback(lua_State* L) {
    const char* msg = lua_tostring(L, 1);
    luaL_traceback(L, L, msg ? msg : "(error object is not a string)", 1);
    return 1;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <repo root> <script.lua>\n", argv[0]);
        return 2;
    }
    const std::string root = argv[1];
    const std::string script = argv[2];

    lua_State* L = luaL_newstate();
    luaL_openlibs(L);

    // REFramework does not open io and strips parts of os; keep the mod honest.
    lua_pushnil(L);
    lua_setglobal(L, "io");

    lua_getglobal(L, "package");
    const std::string path = root + "/lua/reframework/autorun/?.lua;" + root + "/lua/reframework/autorun/?/init.lua;" + root +
                             "/tests/lua/?.lua";
    lua_pushstring(L, path.c_str());
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);

    lua_pushstring(L, root.c_str());
    lua_setglobal(L, "TEST_ROOT");

    re4coop::register_lua_api(L);

    lua_pushcfunction(L, traceback);
    if (luaL_loadfile(L, script.c_str()) != LUA_OK) {
        std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }
    const int rc = lua_pcall(L, 0, 0, -2);
    if (rc != LUA_OK) {
        std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }
    lua_close(L);
    return 0;
}
