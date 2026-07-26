-------------------------------------------------------------------------------
-- 3/main.lua
-- Интерактивное интерфейсное приложение Solar2D для демонстрации и тестирования
-- работы плагина plugin.http3 (Проект 3).
-------------------------------------------------------------------------------

display.setStatusBar(display.HiddenStatusBar)

local http3 = require("plugin_http3")

local TEST_URL = "https://cloudflare-quic.com"
local TOTAL_BENCHMARK_REQS = 500

local activeRequestsCount = 0
local completedCount = 0
local failedCount = 0
local totalBytesReceived = 0

-- Задний фон
local bg = display.newRect(display.contentCenterX, display.contentCenterY, display.contentWidth, display.contentHeight)
bg:setFillColor(0.08, 0.09, 0.12)

-- Заголовок
local title = display.newText({
    text = "Solar2D HTTP/3 Plugin (Project 3)",
    x = display.contentCenterX,
    y = 30,
    font = native.systemFontBold,
    fontSize = 18
})
title:setFillColor(0.9, 0.95, 1.0)

-- Карточки метрик
local function createCard(x, y, w, h, titleStr)
    local rect = display.newRect(x, y, w, h)
    rect:setFillColor(0.14, 0.16, 0.22)
    rect.strokeWidth = 1
    rect:setStrokeColor(0.25, 0.28, 0.38)

    local lbl = display.newText({
        text = titleStr,
        x = x - w/2 + 10,
        y = y - h/2 + 15,
        font = native.systemFont,
        fontSize = 12
    })
    lbl.anchorX = 0
    lbl:setFillColor(0.6, 0.65, 0.75)

    local val = display.newText({
        text = "--",
        x = x - w/2 + 10,
        y = y + 5,
        font = native.systemFontBold,
        fontSize = 16
    })
    val.anchorX = 0
    val:setFillColor(0.3, 0.8, 1.0)

    return val
end

local rssText = createCard(90, 85, 150, 60, "Native RSS (Phys)")
local luaHeapText = createCard(270, 85, 150, 60, "Lua Heap")
local activeReqsText = createCard(90, 155, 150, 60, "Active Tasks")
local bytesText = createCard(270, 155, 150, 60, "Bytes Received")

-- Лог событий
local logBackground = display.newRect(display.contentCenterX, 320, display.contentWidth - 40, 230)
logBackground:setFillColor(0.05, 0.06, 0.08)
logBackground.strokeWidth = 1
logBackground:setStrokeColor(0.2, 0.22, 0.3)

local logLines = {}
local function logMessage(msg)
    print("[HTTP3 UI] " .. msg)
    table.insert(logLines, 1, msg)
    if #logLines > 10 then
        table.remove(logLines)
    end
end

local logTextDisplay = display.newText({
    text = "Лог готов...",
    x = 30,
    y = 220,
    width = display.contentWidth - 60,
    height = 210,
    font = native.systemFont,
    fontSize = 11,
    align = "left"
})
logTextDisplay.anchorX = 0
logTextDisplay.anchorY = 0
logTextDisplay:setFillColor(0.8, 0.85, 0.9)

local function updateUI()
    local stats = http3.getMemoryStats()
    local luaHeapMB = collectgarbage("count") / 1024.0

    rssText.text = string.format("%.2f MB", stats.nativeRSSMB or 0)
    luaHeapText.text = string.format("%.2f MB", luaHeapMB)
    activeReqsText.text = tostring(stats.activeTasks or activeRequestsCount)
    bytesText.text = string.format("%.1f KB", (stats.totalBytesReceived or totalBytesReceived) / 1024.0)

    logTextDisplay.text = table.concat(logLines, "\n")
end

-- Кнопки управления
local function createButton(x, y, w, h, textStr, color, callback)
    local btn = display.newRect(x, y, w, h)
    btn:setFillColor(unpack(color))

    local txt = display.newText({
        text = textStr,
        x = x,
        y = y,
        font = native.systemFontBold,
        fontSize = 14
    })
    txt:setFillColor(1, 1, 1)

    btn:addEventListener("tap", function()
        callback()
        return true
    end)
    return btn
end

-- Одиночный запрос HTTP/3
createButton(90, 470, 150, 40, "1 Запрос GET", {0.18, 0.52, 0.92}, function()
    logMessage("Отправка HTTP/3 GET...")
    activeRequestsCount = activeRequestsCount + 1

    http3.request(TEST_URL, "GET", function(event)
        activeRequestsCount = math.max(0, activeRequestsCount - 1)
        if event.isError then
            failedCount = failedCount + 1
            logMessage("Ошибка: " .. tostring(event.error or "HTTP Error"))
        else
            completedCount = completedCount + 1
            totalBytesReceived = totalBytesReceived + (event.bytesTotal or string.len(event.response or ""))
            logMessage(string.format("Успех %d! Протокол: %s", event.status, tostring(event.protocol)))
        end
        updateUI()
    end, { timeout = 5 })
    updateUI()
end)

-- Стресс-тест 50 запросов
createButton(270, 470, 150, 40, "Пачка 50 REQ", {0.22, 0.65, 0.35}, function()
    logMessage("Запуск пачки 50 запросов...")
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
                logMessage(string.format("Пачка: %d/%d (Успех: %d, Ошибок: %d)", batchDone, batchTotal, batchSuccess, batchFailed))
            end

            if batchDone == batchTotal then
                logMessage(string.format("✓ Пачка 50 REQ завершена! Успешно: %d, Ошибок: %d", batchSuccess, batchFailed))
            end

            updateUI()
        end, { timeout = 15 })
    end
    updateUI()
end)

-- Очистка GC
createButton(90, 525, 150, 40, "Очистить GC", {0.85, 0.45, 0.15}, function()
    logMessage("Принудительная сборка мусора...")
    http3.collectGarbage()
    updateUI()
end)

-- Проверка отмены запроса
createButton(270, 525, 150, 40, "Тест Cancel", {0.75, 0.25, 0.25}, function()
    logMessage("Запуск и отмена запроса...")
    local reqId = http3.request("https://httpbin.org/delay/5", "GET", function(event)
        logMessage("Коллбэк отменённого запроса (не должен вызываться)")
    end, { timeout = 10 })

    if reqId then
        local cancelled = http3.cancel(reqId)
        logMessage("Результат отмены ID " .. tostring(reqId) .. ": " .. tostring(cancelled))
    end
    updateUI()
end)

-- Таймер обновления метрик
timer.performWithDelay(500, updateUI, 0)
updateUI()
logMessage("Плагин загружен. Нажмите кнопку для теста.")
