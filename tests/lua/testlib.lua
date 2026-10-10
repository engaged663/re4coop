-- Tiny assertion helpers shared by the Lua tests (run through re4coop_lua_runner).
local T = {}

T.failures = 0

function T.check(cond, msg, level)
    if not cond then
        T.failures = T.failures + 1
        local info = debug.getinfo((level or 1) + 1, "Sl")
        print(("  CHECK failed at %s:%d: %s"):format(info.short_src, info.currentline, msg or "condition is false"))
    end
    return cond
end

function T.eq(a, b, msg)
    return T.check(a == b, ("%s: expected %s, got %s"):format(msg or "eq", tostring(b), tostring(a)), 2)
end

function T.near(a, b, eps, msg)
    eps = eps or 1e-4
    return T.check(type(a) == "number" and math.abs(a - b) <= eps,
        ("%s: expected %s +- %s, got %s"):format(msg or "near", tostring(b), tostring(eps), tostring(a)), 2)
end

function T.run(name, fn)
    local before = T.failures
    print("[ RUN  ] " .. name)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        T.failures = T.failures + 1
        print("  ERROR: " .. tostring(err))
    end
    print(("[ %s ] %s"):format(T.failures == before and " OK " or "FAIL", name))
end

function T.finish()
    if T.failures > 0 then
        error(("%d check(s) failed"):format(T.failures), 0)
    end
    print("all checks passed")
end

-- Busy-waits (sleep-free) until pred() is true or `timeout` seconds pass, calling step() each loop.
function T.wait_until(pred, step, timeout)
    local deadline = re4coop_net.time() + (timeout or 5)
    while re4coop_net.time() < deadline do
        if step then step() end
        if pred() then return true end
    end
    return pred()
end

return T
