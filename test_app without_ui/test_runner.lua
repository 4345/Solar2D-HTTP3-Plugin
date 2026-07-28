-------------------------------------------------------------------------------
-- test_app/test_runner.lua
-- Универсальный CLI скрипт автотестирования и стресс-теста (2500 запросов)
-- плагина HTTP/3 для всех платформ.
-------------------------------------------------------------------------------

package.path = "../lua/?.lua;../?.lua;./lua/?.lua;./?.lua;" .. package.path
-- Пути поиска для нативных C/C++ библиотек плагина (включая Windows DLL)
package.cpath = "../win32/Release/?.dll;../win32/Release/?_native.dll;./plugin_?.dylib;./plugin/?.dylib;./plugin_?.so;./plugin/?.so;./Release/?.dll;./?.dll;" .. package.cpath

local status, http3 = pcall(require, "plugin_http3")
if not status or not http3 then
    status, http3 = pcall(require, "plugin.http3")
end

if not status or not http3 then
    print("[ERROR] Не удалось загрузить плагин plugin_http3 для CLI автотеста!")
    os.exit(1)
end

local TOTAL_REQUESTS = 1000
local CONCURRENCY = 10
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
print("     SOLAR2D HTTP/3 MULTIPLACEFORM STRESS TEST            ")
print("==========================================================")
print(string.format("Базовый уровень памяти (Start):"))
print(string.format("  - Native RSS: %.2f MB", baselineRSS))
print(string.format("  - Lua Heap:   %.2f MB", baselineLuaHeap))
print(string.format("  - Stack:      %s", baselineStats.stackName or "Native"))
print("----------------------------------------------------------")

local function onResponse(event)
    inFlight = inFlight - 1
    if event and event.isError then
        failed = failed + 1
    else
        completed = completed + 1
    end

    local totalDone = completed + failed

    -- Выводим прогресс каждые 10% или минимум 10 запросов
    local checkInterval = math.max(10, math.floor(TOTAL_REQUESTS / 10))
    if totalDone % checkInterval == 0 or totalDone == TOTAL_REQUESTS then
        local stats = http3.getMemoryStats()
        local luaHeapMB = collectgarbage("count") / 1024.0
        print(string.format("[Check %4d/%d] Native RSS: %6.2f MB | Lua Heap: %5.2f MB | Done: %d (Fail: %d)",
            totalDone, TOTAL_REQUESTS, stats.nativeRSSMB or 0, luaHeapMB, totalDone, failed))
    end

    if sent < TOTAL_REQUESTS then
        sent = sent + 1
        inFlight = inFlight + 1
        http3.request(TEST_URL, "GET", onResponse, { timeout = 3 })
    end
end

-- Запуск первого пула параллельных запросов
for i = 1, CONCURRENCY do
    sent = sent + 1
    inFlight = inFlight + 1
    http3.request(TEST_URL, "GET", onResponse, { timeout = 3 })
end

-- Цикл обработки событий
while (completed + failed) < TOTAL_REQUESTS do
    if http3.pumpEvents then
        http3.pumpEvents(0.005)
    end
end

local elapsedTime = os.clock() - startTime
print("----------------------------------------------------------")
print(string.format("Запросы обработаны за %.1f сек (Скорость: %.1f req/s)", elapsedTime, TOTAL_REQUESTS / math.max(0.1, elapsedTime)))

print("\nЗапуск сборки мусора...")
http3.collectGarbage()
if http3.pumpEvents then
    http3.pumpEvents(0.1)
end

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
