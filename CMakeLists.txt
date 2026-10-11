cmake_minimum_required(VERSION 3.20)
project(re4coop VERSION 0.2.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(RE4COOP_BUILD_TESTS "Build the native and Lua test runners" ON)

if(MSVC)
    # Static CRT: the DLL then has no runtime dependency beyond what RE4 itself needs.
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    add_compile_options(/W4 /permissive- /utf-8)
    add_compile_definitions(_CRT_SECURE_NO_WARNINGS)
else()
    add_compile_options(-Wall -Wextra)
endif()

# Lua 5.4.3, identical to the copy REFramework links (see third_party/README.md).
file(GLOB RE4COOP_LUA_SOURCES CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lua-5.4.3/src/*.c)
add_library(re4coop_lua STATIC ${RE4COOP_LUA_SOURCES})
target_include_directories(re4coop_lua PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lua-5.4.3/src)
if(MSVC)
    target_compile_options(re4coop_lua PRIVATE /W0)
else()
    target_compile_options(re4coop_lua PRIVATE -w)
    if(NOT WIN32)
        target_compile_definitions(re4coop_lua PRIVATE LUA_USE_POSIX)
    endif()
endif()

# Transport + Lua bindings, platform independent.
add_library(re4coop_net_core STATIC
    plugin/src/net/socket.cpp
    plugin/src/net/session.cpp
    plugin/src/lua_api.cpp
)
target_include_directories(re4coop_net_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/plugin/src)
target_link_libraries(re4coop_net_core PUBLIC re4coop_lua)
if(WIN32)
    target_link_libraries(re4coop_net_core PUBLIC ws2_32)
    target_compile_definitions(re4coop_net_core PUBLIC WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0601)
else()
    find_package(Threads REQUIRED)
    target_link_libraries(re4coop_net_core PUBLIC Threads::Threads)
endif()

# The REFramework plugin DLL (Windows only - RE4 is a Windows game).
if(WIN32)
    add_library(re4coop_net SHARED plugin/src/plugin_main.cpp)
    target_include_directories(re4coop_net PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/third_party/reframework/include)
    target_link_libraries(re4coop_net PRIVATE re4coop_net_core)
    set_target_properties(re4coop_net PROPERTIES PREFIX "" OUTPUT_NAME "re4coop_net")
    if(MINGW)
        target_link_options(re4coop_net PRIVATE -static -static-libgcc -static-libstdc++)
    endif()
    install(TARGETS re4coop_net RUNTIME DESTINATION reframework/plugins LIBRARY DESTINATION reframework/plugins)
endif()

install(DIRECTORY lua/reframework/ DESTINATION reframework)

if(RE4COOP_BUILD_TESTS)
    enable_testing()

    add_executable(re4coop_test_net plugin/tests/test_net.cpp)
    target_link_libraries(re4coop_test_net PRIVATE re4coop_net_core)
    add_test(NAME native_transport COMMAND re4coop_test_net)

    # Runs Lua test scripts with the real re4coop_net bindings and the mod's Lua modules.
    add_executable(re4coop_lua_runner plugin/tests/lua_runner.cpp)
    target_link_libraries(re4coop_lua_runner PRIVATE re4coop_net_core)

    # Loads the real DLL like REFramework's PluginLoader (version/game gate, init, Lua callback
    # with a Lua state from a separate Lua copy). Windows only, since the plugin is a Windows DLL.
    if(WIN32)
        add_executable(re4coop_test_plugin_load plugin/tests/test_plugin_load.cpp)
        target_include_directories(re4coop_test_plugin_load PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/third_party/reframework/include)
        target_link_libraries(re4coop_test_plugin_load PRIVATE re4coop_lua)
        add_test(NAME plugin_load COMMAND re4coop_test_plugin_load $<TARGET_FILE:re4coop_net>)
    endif()

    file(GLOB RE4COOP_LUA_TESTS CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/tests/lua/test_*.lua)
    foreach(test_script ${RE4COOP_LUA_TESTS})
        get_filename_component(test_name ${test_script} NAME_WE)
        add_test(NAME lua_${test_name}
                 COMMAND re4coop_lua_runner ${CMAKE_CURRENT_SOURCE_DIR} ${test_script})
    endforeach()
endif()
