-------------------------------------------------------------------------------
-- 3/test_runner.lua
-- Скрипт автоматизированного CLI стресс-теста (2500 запросов) для плагина HTTP/3
-------------------------------------------------------------------------------

package.cpath = "./plugin_?.dylib;./plugin/?.dylib;./plugin_?.so;./plugin/?.so;" .. package.cpath

local http3 = require("plugin_http3")

local TOTAL_REQUESTS = 2500
local CONCURRENCY = 30
local TEST_URL = "https://cloudflare-quic.com"

local completed = 0
local failed = 0
local inFlight = 0
local sent = 0
local startTime = os.clock()

local baselineStats = http3.getMemoryStats()
local baselineRSS = baselineStats.nativeRSSMB or 0
local baselineLuaHeap = collectgarbage("count") / 1024.0

print("==========================================================")
print("     SOLAR2D HTTP/3 PROJECT 3 EXTENDED STRESS TEST (2500) ")
print("==========================================================")
print(string.format("Базовый уровень памяти (Start):"))
print(string.format("  - Native RSS: %.2f MB", baselineRSS))
print(string.format("  - Lua Heap:   %.2f MB", baselineLuaHeap))
print("----------------------------------------------------------")

local function onResponse(event)
    inFlight = inFlight - 1
    if event and event.isError then
        failed = failed + 1
    else
        completed = completed + 1
    end

    local totalDone = completed + failed

    if totalDone % 500 == 0 then
        local stats = http3.getMemoryStats()
        local luaHeapMB = collectgarbage("count") / 1024.0
        print(string.format("[Check %4d/%d] Native RSS: %6.2f MB | Lua Heap: %5.2f MB | Done: %d (Fail: %d)",
            totalDone, TOTAL_REQUESTS, stats.nativeRSSMB or 0, luaHeapMB, totalDone, failed))
    end

    if sent < TOTAL_REQUESTS then
        sent = sent + 1
        inFlight = inFlight + 1
        http3.request(TEST_URL, "GET", onResponse, { timeout = 5 })
    end
end

-- Запуск первого пула параллельных запросов
for i = 1, CONCURRENCY do
    sent = sent + 1
    inFlight = inFlight + 1
    http3.request(TEST_URL, "GET", onResponse, { timeout = 5 })
end

-- Цикл обработки событий RunLoop
while (completed + failed) < TOTAL_REQUESTS do
    http3.pumpEvents(0.005)
end

local elapsedTime = os.clock() - startTime
print("----------------------------------------------------------")
print(string.format("Запросы обработаны за %.1f сек (Скорость: %.1f req/s)", elapsedTime, TOTAL_REQUESTS / math.max(0.1, elapsedTime)))

print("\nЗапуск сборки мусора...")
http3.collectGarbage()
http3.pumpEvents(0.1)

local finalStats = http3.getMemoryStats()
local finalLuaHeap = collectgarbage("count") / 1024.0

print("==========================================================")
print("              ИТОГОВЫЙ ОТЧЕТ АНАЛИЗА ПАМЯТИ               ")
print("==========================================================")
print(string.format("Начальный Native RSS:  %.2f MB", baselineRSS))
print(string.format("Конечный Native RSS:   %.2f MB", finalStats.nativeRSSMB or 0))
print(string.format("Изменение Native RSS:  %+.2f MB", (finalStats.nativeRSSMB or 0) - baselineRSS))
print(string.format("Изменение Lua Heap:    %+.2f MB", finalLuaHeap - baselineLuaHeap))
print("----------------------------------------------------------")
