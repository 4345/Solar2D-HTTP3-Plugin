-------------------------------------------------------------------------------
-- test_app/main.lua
-- Модификация приложения test_app без UI (Headless-режим)
-- Выполняет периодические HTTP/3 запросы к https://example.com/ и выводит
-- результаты работы протокола и транспорта в консоль (adb logcat).
-------------------------------------------------------------------------------

-- Настройка путей поиска модулей плагина
package.path = "../lua/?.lua;../?.lua;./lua/?.lua;./?.lua;" .. package.path

display.setStatusBar(display.HiddenStatusBar)

-- Подключение плагина HTTP/3
local status, http3 = pcall(require, "plugin.http3")
if not status or not http3 then
    status, http3 = pcall(require, "plugin_http3")
end

if not status or not http3 then
    print("[ERROR] HEADLESS_TEST: Не удалось загрузить модуль plugin.http3!")
    os.exit(1)
end

-- Целевой URL тестового сервера HTTP/3
local TEST_URL = "https://example.com/"



local requestCounter = 0
local successCounter = 0
local errorCounter = 0

print("==========================================================")
print("[HEADLESS_TEST] Старт приложения автотестирования HTTP/3")
print("[HEADLESS_TEST] Целевой URL: " .. TEST_URL)
print("==========================================================")

-- Функция отправки одиночного сетевого запроса
local function sendTestRequest()
    requestCounter = requestCounter + 1
    local currentReqIndex = requestCounter
    local startTime = (system and system.getTimer) and system.getTimer() or (os.clock() * 1000)

    http3.request(TEST_URL, "GET", function(event)
        local elapsedMs = math.floor(((system and system.getTimer) and system.getTimer() or (os.clock() * 1000)) - startTime)

        if event and not event.isError then
            successCounter = successCounter + 1
            print(string.format("[HEADLESS_TEST] [#%04d] УСПЕХ | Время: %d ms | Код: %d | Протокол: %s | Транспорт: %s",
                currentReqIndex,
                elapsedMs,
                event.status or 200,
                tostring(event.protocol or "HTTP/3"),
                tostring(event.transport or "Native")
            ))
        else
            errorCounter = errorCounter + 1
            local errReason = event and (event.error or event.reason) or "Unknown Error"
            print(string.format("[HEADLESS_TEST] [#%04d] ОШИБКА | Время: %d ms | Причина: %s | Транспорт: %s",
                currentReqIndex,
                elapsedMs,
                tostring(errReason),
                tostring(event and event.transport or "Native")
            ))
        end

        -- Каждые 10 запросов принудительно запускаем сборщик мусора
        if currentReqIndex % 10 == 0 then
            http3.collectGarbage()
        end
    end, { timeout = 5.0 })
end

-- Запуск отправки первого запроса сразу
sendTestRequest()

-- Периодическая отправка запросов каждые 2.5 секунды
timer.performWithDelay(2500, function()
    sendTestRequest()
end, 0)

