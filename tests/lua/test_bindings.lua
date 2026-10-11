-- The re4coop_net C bindings: argument errors, error returns, independent sessions.
local T = require("testlib")

T.run("api_surface", function()
    for _, name in ipairs({ "host", "join", "stop", "send", "poll", "state", "role", "stats",
        "local_addresses", "time", "max_payload", "version", "new_session", "set_simulated_loss" }) do
        T.eq(type(re4coop_net[name]), "function", name)
    end
    local v, proto = re4coop_net.version()
    T.eq(v, require("re4coop.protocol").MOD_VERSION, "plugin and script versions match")
    T.eq(proto, 2, "net protocol")
    T.eq(re4coop_net.max_payload(), 1188, "max payload (1200 B datagrams)")
    T.eq(re4coop_net.max_payload(), require("re4coop.protocol").MAX_PAYLOAD, "script knows the payload limit")
    T.eq(re4coop_net.state(), "idle", "idle at start")
    local t1 = re4coop_net.time()
    T.check(type(t1) == "number" and re4coop_net.time() >= t1, "monotonic time")
end)

T.run("bad_arguments_raise_catchable_errors", function()
    T.check(not pcall(re4coop_net.host, "not a port"), "non-numeric port")
    T.check(not pcall(re4coop_net.host, 0), "port 0")
    T.check(not pcall(re4coop_net.host, 70000), "port too large")
    T.check(not pcall(re4coop_net.join, nil, 33040), "missing address")
    T.check(not pcall(re4coop_net.send, {}), "non-string payload")
    T.eq(re4coop_net.state(), "idle", "still usable after errors")
end)

T.run("failures_return_nil_and_message", function()
    local ok, err = re4coop_net.send("x", true)
    T.check(ok == nil and err:find("not connected"), "send while idle")
    ok, err = re4coop_net.join("no-such-host.invalid", 33040)
    T.check(ok == nil and type(err) == "string", "unresolvable host: " .. tostring(err))
    local a = re4coop_net.new_session()
    local port = 46000 + (os.time() % 3000)
    T.check(a:host(port, "A"), "first bind")
    local b = re4coop_net.new_session()
    ok, err = b:host(port, "B")
    T.check(ok == nil and err:find("in use"), "second bind on same port explains why: " .. tostring(err))
    ok, err = a:host(port + 1, "A")
    T.check(ok == nil and err:find("already active"), "double host refused")
    a:stop()
    b:stop()
end)

T.run("binary_payload_roundtrip_between_sessions", function()
    local host, client = re4coop_net.new_session(), re4coop_net.new_session()
    local port = 47000 + (os.time() % 2000)
    assert(host:host(port, "H", "pw"))
    assert(client:join("127.0.0.1", port, "C", "pw"))
    local got
    local blob = string.char(0, 255, 1, 254) .. string.rep("\0", 100) .. "end"
    T.wait_until(function()
        for _, ev in ipairs(host:poll()) do
            if ev.type == "message" then got = ev end
        end
        for _, ev in ipairs(client:poll()) do
            if ev.type == "connected" then client:send(blob, true) end
        end
        return got ~= nil
    end, nil, 5)
    T.check(got ~= nil and got.data == blob and got.reliable == true, "binary-safe reliable message")
    local stats = host:stats()
    T.eq(stats.peer_name, "C", "peer name in stats")
    T.check(stats.packets_recv > 0, "counters")
    client:stop()
    host:stop()
end)

T.finish()
