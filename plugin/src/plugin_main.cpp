// REFramework plugin entry points. Drop the built re4coop_net.dll into
// <RE4 folder>/reframework/plugins/ and REFramework loads it at startup.
//
// The plugin does one job: before REFramework runs the scripts in reframework/autorun, it
// registers the `re4coop_net` table in the main Lua state so re4coop.lua can use UDP.

#include <reframework/API.h>

#include "lua_api.hpp"

namespace {

const REFrameworkPluginInitializeParam* g_param = nullptr;

void on_lua_state_created(lua_State* L) {
    re4coop::register_lua_api(L);
    if (g_param != nullptr && g_param->functions->log_info != nullptr) {
        g_param->functions->log_info("[re4coop] re4coop_net %s registered in Lua state", re4coop::kVersion);
    }
}

void on_lua_state_destroyed(lua_State*) {
    // The network session deliberately outlives the Lua state so "Reset Scripts" does not
    // drop the partner; the reloaded script picks the session back up via re4coop_net.state().
}

} // namespace

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* version) {
    // We only use on_lua_state_created/log_info, which exist with this layout since plugin
    // API 1.3 (2022), so every REFramework build that supports RE4 (2023) can load us.
    version->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    version->minor = 3;
    version->patch = 0;
    version->game_name = "re4";
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    g_param = param;
    param->functions->on_lua_state_created(on_lua_state_created);
    param->functions->on_lua_state_destroyed(on_lua_state_destroyed);
    param->functions->log_info("[re4coop] plugin initialized");
    return true;
}
