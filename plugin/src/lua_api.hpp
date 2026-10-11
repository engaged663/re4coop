// Lua bindings for the network session, exposed to REFramework scripts as the global
// table `re4coop_net`. REFramework's Lua sandbox has no socket or io library, so this
// plugin is the only way scripts can talk to the network.
#pragma once

struct lua_State;

namespace re4coop {

constexpr const char* kVersion = "0.5.0";

// Pushes the API table onto the stack (luaopen_* convention). Returns 1.
int open_lua_api(lua_State* L);

// Builds the API table and stores it in the global `re4coop_net`.
void register_lua_api(lua_State* L);

} // namespace re4coop
