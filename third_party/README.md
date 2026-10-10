# Third-party code

| Directory | Upstream | License | Why it is vendored |
|---|---|---|---|
| `lua-5.4.3/` | Copied from REFramework `dependencies/lua` (Lua 5.4.3 plus two upstream bugfix patches in `ldebug.c`/`lvm.c`), REFramework commit `41f9d19` | MIT (Lua.org) | The plugin calls the Lua C API on REFramework's `lua_State`. Struct layouts must match the Lua that REFramework links, so we build against the identical sources. |
| `reframework/include/reframework/API.h` | REFramework `include/reframework/API.h` (plugin API 1.15.0), same commit | MIT (praydog) | C plugin interface used by `plugin/src/plugin_main.cpp`. |
