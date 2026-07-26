io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path

if not system then
    system = {
        getTimer = function() return os.clock() * 1000 end,
        pathForFile = function(f) return f end
    }
end

local ok, http3 = pcall(require, "plugin_http3")
print("[HTTP3 Lua] Loaded plugin_http3:", ok)

local stats0 = http3.getMemoryStats()
print(string.format("Start RSS: %.2f MB | BuildTimestamp: %s | Stack: %s",
    stats0.nativeRSSMB or 0, tostring(stats0.buildTimestamp), tostring(stats0.stackName)))

local total = 1000
local done = 0
local success = 0
local failed = 0

for i = 1, total do
    local isReqDone = false
    local reqId = http3.request("https://cloudflare-quic.com", "GET", function(evt)
        done = done + 1
        isReqDone = true
        if evt and not evt.isError then
            success = success + 1
        else
            failed = failed + 1
        end
    end, { timeout = 5 })

    local startT = os.clock()
    while not isReqDone and (os.clock() - startT) < 5 do
        if http3.pumpEvents then http3.pumpEvents(0.005) end
    end

    if i % 100 == 0 or i == total then
        http3.collectGarbage()
        local stats = http3.getMemoryStats()
        print(string.format("[Req %4d/%d] Native RSS: %6.2f MB | Lua Heap: %5.2f MB | Done: %d (OK: %d, Fail: %d) | Active: %d",
            i, total, stats.nativeRSSMB or 0, collectgarbage("count") / 1024.0, done, success, failed, stats.activeTasks or 0))
        io.stdout:flush()
    end
end

http3.collectGarbage()
local statsEnd = http3.getMemoryStats()
print("==========================================================")
print(string.format("FINAL Native RSS: %.2f MB | Lua Heap: %.2f MB", statsEnd.nativeRSSMB or 0, collectgarbage("count") / 1024.0))
print("==========================================================")
