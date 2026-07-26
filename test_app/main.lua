-------------------------------------------------------------------------------
-- test_app/main.lua
-- Универсальное кроссплатформенное Solar2D приложение для тестирования и
-- демонстрации работы плагина plugin.http3 на iOS, macOS, Android, Windows и Simulator.
-------------------------------------------------------------------------------

-- Настройка путей поиска для подключения модуля плагина на любых платформах
package.path = "../lua/?.lua;../?.lua;./lua/?.lua;./?.lua;" .. package.path

display.setStatusBar(display.HiddenStatusBar)

-- Сначала пытаемся загрузить плагин plugin.http3, скачанный по ссылкам из build.settings
local status, http3 = pcall(require, "plugin.http3")
if not status or not http3 then
    status, http3 = pcall(require, "plugin_http3")
end

if not status or not http3 then
    print("[ERROR] HTTP3 Test App: Не удалось загрузить модуль plugin_http3!")
    http3 = {
        request = function(url, method, listener, params)
            if network and network.request then
                return network.request(url, method, listener, params)
            end
        end,
        cancel = function() return false end,
        getMemoryStats = function() return { nativeRSSMB = 0, nativeRSSBytes = 0, activeTasks = 0 } end,
        collectGarbage = function() collectgarbage("collect") end
    }
end

local TEST_URL = "https://cloudflare-quic.com"

-- Переменные метрик приложения
local activeRequestsCount = 0
local completedCount = 0
local failedCount = 0
local totalBytesReceived = 0

-- Задний фон приложения
local bg = display.newRect(display.contentCenterX, display.contentCenterY, display.contentWidth, display.contentHeight)
bg:setFillColor(0.07, 0.08, 0.11)

-- Заголовок приложения
local title = display.newText({
    text = "Solar2D HTTP/3 Multiplatform Test App",
    x = display.contentCenterX,
    y = 25,
    font = native.systemFontBold,
    fontSize = 15
})
title:setFillColor(0.9, 0.94, 1.0)

-- Подзаголовок платформы
local currentPlatformName = (system and system.getInfo) and system.getInfo("platform") or "unknown"
local platformSubtitle = display.newText({
    text = "Платформа: " .. string.upper(currentPlatformName),
    x = display.contentCenterX,
    y = 45,
    font = native.systemFont,
    fontSize = 11
})
platformSubtitle:setFillColor(0.55, 0.7, 0.9)

-- Функция создания информационных карточек метрик
local function createCard(x, y, w, h, titleStr)
    local rect = display.newRect(x, y, w, h)
    rect:setFillColor(0.12, 0.14, 0.20)
    rect.strokeWidth = 1
    rect:setStrokeColor(0.22, 0.25, 0.35)

    local lbl = display.newText({
        text = titleStr,
        x = x - w/2 + 8,
        y = y - h/2 + 12,
        font = native.systemFont,
        fontSize = 11
    })
    lbl.anchorX = 0
    lbl:setFillColor(0.55, 0.6, 0.7)

    local val = display.newText({
        text = "--",
        x = x - w/2 + 8,
        y = y + 5,
        font = native.systemFontBold,
        fontSize = 15
    })
    val.anchorX = 0
    val:setFillColor(0.3, 0.8, 1.0)

    return val
end

-- Создание 4-х карточек мониторинга памяти и задач
local rssText = createCard(90, 95, 150, 55, "Native RSS (Phys)")
local luaHeapText = createCard(270, 95, 150, 55, "Lua Heap")
local activeReqsText = createCard(90, 160, 150, 55, "Active Tasks")
local bytesText = createCard(270, 160, 150, 55, "Bytes Received")

-- Лог событий приложения
local logBackground = display.newRect(display.contentCenterX, 325, display.contentWidth - 30, 230)
logBackground:setFillColor(0.04, 0.05, 0.07)
logBackground.strokeWidth = 1
logBackground:setStrokeColor(0.18, 0.2, 0.28)

local logLines = {}
local function logMessage(msg)
    print("[HTTP3 TestApp] " .. msg)
    table.insert(logLines, 1, msg)
    if #logLines > 11 then
        table.remove(logLines)
    end
end

local logTextDisplay = display.newText({
    text = "Система готова к проведению тестов...",
    x = 25,
    y = 220,
    width = display.contentWidth - 50,
    height = 210,
    font = native.systemFont,
    fontSize = 10,
    align = "left"
})
logTextDisplay.anchorX = 0
logTextDisplay.anchorY = 0
logTextDisplay:setFillColor(0.8, 0.85, 0.92)

-- Обновление UI метрик
local function updateUI()
    local stats = http3.getMemoryStats()
    local luaHeapMB = collectgarbage("count") / 1024.0

    rssText.text = string.format("%.2f MB", stats.nativeRSSMB or 0)
    luaHeapText.text = string.format("%.2f MB", luaHeapMB)
    activeReqsText.text = tostring(stats.activeTasks or activeRequestsCount)
    bytesText.text = string.format("%.1f KB", (stats.totalBytesReceived or totalBytesReceived) / 1024.0)

    logTextDisplay.text = table.concat(logLines, "\n")
end

-- Вспомогательная функция создания интерактивных кнопок
local function createButton(x, y, w, h, textStr, color, callback)
    local btn = display.newRect(x, y, w, h)
    btn:setFillColor(unpack(color))

    local txt = display.newText({
        text = textStr,
        x = x,
        y = y,
        font = native.systemFontBold,
        fontSize = 13
    })
    txt:setFillColor(1, 1, 1)

    btn:addEventListener("tap", function()
        callback()
        return true
    end)
    return btn
end

-- Кнопка 1: Одиночный HTTP/3 GET-запрос
createButton(90, 470, 150, 38, "1 Запрос GET", {0.18, 0.52, 0.92}, function()
    logMessage("Отправка HTTP/3 GET на " .. TEST_URL)
    activeRequestsCount = activeRequestsCount + 1

    local reqId = http3.request(TEST_URL, "GET", function(event)
        activeRequestsCount = math.max(0, activeRequestsCount - 1)
        if event.isError then
            failedCount = failedCount + 1
            logMessage(" Ошибка: " .. tostring(event.error or event.reason or "Transport Error"))
        else
            completedCount = completedCount + 1
            totalBytesReceived = totalBytesReceived + (event.bytesTotal or string.len(event.response or ""))
            logMessage(string.format("✓ Статус %d | %s | %s", event.status, tostring(event.protocol or "HTTP/3"), tostring(event.transport or "Native")))
        end
        updateUI()
    end, { timeout = 3 })

    logMessage("Запрос запущен (ID: " .. tostring(reqId) .. ")")
    updateUI()
end)

-- Кнопка 2: Пачка из 50 параллельных запросов
createButton(270, 470, 150, 38, "Пачка 50 REQ", {0.22, 0.65, 0.35}, function()
    logMessage("Запуск стресс-пачки из 50 запросов...")
    local batchTotal = 50
    local batchDone = 0
    local batchSuccess = 0
    local batchFailed = 0

    for i = 1, batchTotal do
        activeRequestsCount = activeRequestsCount + 1
        http3.request(TEST_URL, "GET", function(event)
            activeRequestsCount = math.max(0, activeRequestsCount - 1)
            batchDone = batchDone + 1

            if not event.isError then
                completedCount = completedCount + 1
                batchSuccess = batchSuccess + 1
                totalBytesReceived = totalBytesReceived + (event.bytesTotal or string.len(event.response or ""))
            else
                failedCount = failedCount + 1
                batchFailed = batchFailed + 1
            end

            if batchDone % 10 == 0 or batchDone == batchTotal then
                logMessage(string.format("Пачка: %d/%d (Успешно: %d, Ошибок: %d)", batchDone, batchTotal, batchSuccess, batchFailed))
            end

            if batchDone == batchTotal then
                logMessage(string.format("✓ Пачка из 50 запросов завершена!"))
                http3.collectGarbage()
                updateUI()
            end
        end, { timeout = 10 })
    end
    updateUI()
end)

-- Кнопка 3: Принудительная сборка мусора
createButton(90, 520, 150, 38, "Очистить GC", {0.85, 0.45, 0.15}, function()
    logMessage("Запуск сборки мусора...")
    http3.collectGarbage()
    updateUI()
end)

-- Кнопка 4: Проверка отмены запроса (cancel)
createButton(270, 520, 150, 38, "Тест Cancel", {0.75, 0.25, 0.25}, function()
    logMessage("Тест отмены запроса...")
    local reqId = http3.request("https://httpbin.org/delay/5", "GET", function(event)
        logMessage("[FAIL] Коллбэк отменённого запроса вызван!")
    end, { timeout = 10 })

    if reqId then
        local cancelled = http3.cancel(reqId)
        logMessage("Запрос ID " .. tostring(reqId) .. " отменён: " .. tostring(cancelled))
    end
    updateUI()
end)

-- Кнопка 5: Данные стека и диагностики
createButton(display.contentCenterX, 570, 330, 34, "Инфо о нативном стеке", {0.4, 0.3, 0.6}, function()
    local stats = http3.getMemoryStats()
    logMessage("Стек: " .. tostring(stats.stackName or "Native"))
    logMessage("HTTP/3 конфигурирован: " .. tostring(stats.isHTTP3Configured))
    updateUI()
end)

-- Регулярный таймер вызова обновления интерфейса
timer.performWithDelay(500, updateUI, 0)
updateUI()
logMessage("Тестовое приложение заложено. Все платформы поддерживаются.")
