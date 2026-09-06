-------------------------------------------------------------------------------
-- plugin_http3.lua
-- Универсальный канонический Lua-модуль плагина plugin.http3 для Solar2D.
--
-- АРХИТЕКТУРА И ВОЗМОЖНОСТИ:
--   1. Полная совместимость с API network.request() Solar2D:
--      http3.request(url, method, listener [, params])
--      Поддерживает различные формы вызова аргументов и табличные слушатели (:http3Response).
--   2. Поддержка всех платформ (iOS, macOS, Android, Windows, CLI/Standalone):
--      - Push-режим (iOS/macOS/Android): нативное асинхронное событие ("http3").
--      - Polling-режим (Windows): опрос результатов через enterFrame и checkRequest(id).
--   3. Прозрачный фоллбэк на встроенный стек network.request:
--      Срабатывает при отсутствии нативной библиотеки или сигнале NATIVE_TRANSPORT_FAILED.
--   4. Расширенные функции управления и диагностики:
--      - http3.cancel(requestId)
--      - http3.getMemoryStats()
--      - http3.collectGarbage()
--      - http3.pumpEvents(seconds)
-------------------------------------------------------------------------------

local M = {}

-- Таблица для хранения активных слушателей в режиме опроса (polling), защищает их от GC
local activeListeners = {}

-- Кэшированная ссылка на нативную C-библиотеку
local nativeLib = nil

--- Динамический поиск и загрузка нативного модуля C/C++
-- @return table|nil Экземпляр нативной библиотеки или nil
local function loadNativeLibrary()
    if nativeLib then
        return nativeLib
    end

    -- ИМЕНА НАТИВНОГО МОДУЛЯ, по порядку предпочтения.
    --   plugin.http3.ntv    — новое имя. Solar2D ищет загрузчик по имени
    --     модуля (require("a.b.c") -> класс a.b.c.LuaLoader), а пакет с
    --     сегментом native javac собрать не может: это ключевое слово Java.
    --     Из-за него загрузчик держали на Kotlin и тащили в AAR весь
    --     kotlin-stdlib. Пакет переименован, Kotlin убран.
    --   plugin.http3.native — прежнее имя. ОСТАВЛЕНО НАМЕРЕННО: готовые
    --     бинарники Apple и Windows экспортируют luaopen_plugin_http3_native,
    --     и до их пересборки модуль доступен только под этим именем. Когда
    --     они будут пересобраны с alias luaopen_plugin_http3_ntv (он уже
    --     добавлен в shared/SimulatorPluginLibrary.cpp и .mm), эту строку
    --     можно убрать.
    --   plugin.http3        — базовое имя, как отдаёт Apple-сборка.
    local imena = { "plugin.http3.ntv", "plugin.http3.native", "plugin.http3" }

    -- Вариант 1: Зарегистрированный предзагрузчик в package.preload
    if package and package.preload then
        for i = 1, #imena do
            local preload = package.preload[imena[i]]
            if preload then
                local status, lib = pcall(preload)
                if status and type(lib) == "table" and (lib.request or lib.initiateRequest) then
                    nativeLib = lib
                    return nativeLib
                end
            end
        end
    end

    -- Вариант 2: Прямой require нативного модуля
    for i = 1, #imena do
        local status, lib = pcall(require, imena[i])
        if status and type(lib) == "table" and (lib.request or lib.initiateRequest) and lib ~= M then
            nativeLib = lib
            return nativeLib
        end
    end

    -- Вариант 4: Динамическая подгрузка бинарных библиотек (.dylib / .so / .dll)
    if package and package.loadlib then
        local libPath = (system and system.pathForFile) and system.pathForFile("plugin/http3.dylib", system.ResourceDirectory) or "./plugin/http3.dylib"
        local appData = (os.getenv and os.getenv("APPDATA")) or ""
        local coronaPluginsDir = (appData ~= "") and (appData .. "\\Corona Labs\\Corona Simulator\\Plugins\\plugin_http3_native.dll") or ""
        local solar2dSimDir = (appData ~= "") and (appData .. "\\Solar2DPlugins\\ovh.azi\\plugin.http3\\win32-sim\\plugin_http3_native.dll") or ""
        local solar2dWinDir = (appData ~= "") and (appData .. "\\Solar2DPlugins\\ovh.azi\\plugin.http3\\win32\\plugin_http3_native.dll") or ""

        local dllPaths = {
            libPath,
            "./plugin_http3_native.dll",
            "../win32/Release/plugin_http3_native.dll",
            "../plugins/win32-sim/plugin_http3_native.dll",
            "../plugins/win32/plugin_http3_native.dll",
            "./plugins/win32-sim/plugin_http3_native.dll",
            "./Release/plugin_http3_native.dll",
            coronaPluginsDir,
            solar2dSimDir,
            solar2dWinDir,
            "./plugin/http3.dylib",
            "./plugin_http3.dylib",
            "./plugin/http3.so",
        }

        for _, path in ipairs(dllPaths) do
            if path and path ~= "" then
                local loader = package.loadlib(path, "luaopen_plugin_http3_native")
                if not loader then
                    loader = package.loadlib(path, "luaopen_plugin_http3")
                end
                if loader then
                    local loadStatus, loadedLib = pcall(loader)
                    if loadStatus and type(loadedLib) == "table" and (loadedLib.request or loadedLib.initiateRequest) then
                        print("[HTTP3 Lua] Успешно загружен нативный модуль C++ DLL:", path)
                        nativeLib = loadedLib
                        return nativeLib
                    end
                end
            end
        end
    end

    print("[HTTP3 Lua] ОШИБКА: Нативный модуль C++ DLL не найден ни в одной из директорий!")
    return nil
end

-- Инициализируем при загрузке модуля
nativeLib = loadNativeLibrary()

-------------------------------------------------------------------------------
-- Основная функция запроса: http3.request( url, method, listener [, params] )
-------------------------------------------------------------------------------
function M.request(url, method, listener, params)
    if not url then
        error("HTTP3 Error: url является обязательным параметром", 2)
    end

    -- Нормализация аргументов при различных вариантах вызова API
    local httpMethod = "GET"
    local callbackListener = nil
    local requestParams = {}

    if type(method) == "string" then
        -- Стандартная сигнатура Solar2D: (url, method, listener [, params])
        httpMethod = string.upper(method)
        callbackListener = listener
        requestParams = params or {}
    elseif type(method) == "function" or (type(method) == "table" and method.http3Response) then
        -- Сигнатура с пропущенным методом: (url, listener [, params])
        callbackListener = method
        if type(listener) == "table" then
            requestParams = listener
            httpMethod = string.upper(requestParams.method or "GET")
        end
    elseif type(method) == "table" then
        -- Сигнатура с передачей таблицы параметров 2-м аргументом: (url, params, listener)
        requestParams = method
        httpMethod = string.upper(requestParams.method or "GET")
        callbackListener = listener
    end

    local headers = requestParams.headers
    local body = requestParams.body
    -- Умолчание таймаута — 3 секунды, и это НЕ описка и не наследие: у
    -- network.request в Solar2D стоит 30с, но сценария, где такое ожидание
    -- осмысленно, попросту нет — даже спутниковый канал отвечает много раньше.
    -- В iOS/macOS 3 секунды приняты стандартом для HTTP/3. Столько же принято и
    -- в проекте, который этим плагином пользуется. Не возвращать к 30с.
    local timeout = requestParams.timeout or 3.0

    -- ПАРАМЕТРЫ ОТКАТА собираем ПОЛНОСТЬЮ, копией исходной таблицы, а не из
    -- трёх избранных полей. У network.request их больше: bodyType, progress,
    -- response, handleRedirects. Пересборка из headers/body/timeout молча
    -- теряла остальные, и опаснее всего терялся bodyType="binary" — без него
    -- Solar2D отправляет тело как текст UTF-8 и портит двоичные данные
    -- (msgpack игрового протокола).
    local function params_dlya_otkata()
        local p = {}
        for k, v in pairs(requestParams) do p[k] = v end
        p.headers = headers
        p.body = body
        p.timeout = timeout
        return p
    end

    -- Обёртка над слушателем для перехвата ошибок транспорта и аннотации события
    local function wrapperListener(event)
        if event and event.isError and event.reason == "NATIVE_TRANSPORT_FAILED" then
            print("HTTP3: Нативный транспорт недоступен. Автоматическое переключение на Solar2D network.request.")
            if network and network.request then
                network.request(url, httpMethod, callbackListener, params_dlya_otkata())
            end
        else
            if event then
                event.name = event.name or "http3"
                event.transport = event.transport or (nativeLib and "Native HTTP/3" or "Solar2D network.request (Fallback)")
                event.protocol = event.protocol or (nativeLib and "HTTP/3 (QUIC / h3)" or "HTTP/2.0 (Fallback)")
                event.isNative = (nativeLib ~= nil)
            end
            if callbackListener then
                if type(callbackListener) == "function" then
                    callbackListener(event)
                elseif type(callbackListener) == "table" and type(callbackListener.http3Response) == "function" then
                    callbackListener:http3Response(event)
                end
            end
        end
    end

    -- 1. Вызов нативного C/C++/Java модуля
    local cLib = loadNativeLibrary()
    if cLib then
        local nativeParams = {
            method = httpMethod,
            headers = headers,
            body = body,
            bodyType = requestParams.bodyType, -- см. params_dlya_otkata выше
            timeout = timeout,
            listener = wrapperListener
        }
        requestParams.timeout = timeout

        local result = nil
        if cLib.request then
            result = cLib.request(url, httpMethod, wrapperListener, requestParams)
        elseif cLib.initiateRequest then
            result = cLib.initiateRequest(url, nativeParams)
        end

        -- Возвращаемое значение плагина: всегда числовой requestId
        if type(result) == "number" and result > 0 then
            local reqId = result

            -- Обратная совместимость с legacу-модулями, использующими checkRequest (polling)
            if cLib.checkRequest then
                local startTime = (system and system.getTimer) and system.getTimer() or (os.time() * 1000)
                local maxWaitMs = (timeout + 2.0) * 1000

                local function check(evt)
                    local pollResult = cLib.checkRequest(reqId)
                    if pollResult then
                        if Runtime and Runtime.removeEventListener and activeListeners[reqId] then
                            Runtime:removeEventListener("enterFrame", activeListeners[reqId])
                        end
                        activeListeners[reqId] = nil
                        wrapperListener(pollResult)
                    else
                        -- Предохранитель от утечки памяти: если нативный модуль завис или не вернул статус
                        local now = (system and system.getTimer) and system.getTimer() or (os.time() * 1000)
                        if (now - startTime) > maxWaitMs then
                            if Runtime and Runtime.removeEventListener and activeListeners[reqId] then
                                Runtime:removeEventListener("enterFrame", activeListeners[reqId])
                            end
                            activeListeners[reqId] = nil
                            if cLib and cLib.cancel then
                                cLib.cancel(reqId)
                            end
                            wrapperListener({ isError = true, error = "Request Timeout", reason = "Timeout" })
                        end
                    end
                end

                activeListeners[reqId] = check
                if Runtime and Runtime.addEventListener then
                    Runtime:addEventListener("enterFrame", check)
                end
            end

            return reqId
        elseif result then
            -- Если нативный слой вернул boolean/другое истинное значение, логируем и возвращаем результат
            return result
        end
    end

    -- 2. Резервный вызов стандартного сетевого стека Solar2D network.request
    if network and network.request then
        return network.request(url, httpMethod, function(evt)
            evt.name = "http3"
            evt.transport = "Solar2D network.request (Fallback)"
            evt.protocol = "HTTP/2.0 (Fallback)"
            evt.isNative = false
            if callbackListener then
                if type(callbackListener) == "function" then
                    callbackListener(evt)
                elseif type(callbackListener) == "table" and type(callbackListener.http3Response) == "function" then
                    callbackListener:http3Response(evt)
                end
            end
        end, params_dlya_otkata())
    end

    print("[WARNING] HTTP3: Ни нативный плагин HTTP/3, ни сетевой стек network.request недоступны.")
    return nil
end

-------------------------------------------------------------------------------
-- Вспомогательные функции управления задачами и диагностикой
-------------------------------------------------------------------------------

--- Отмена выполняющегося запроса по ID
-- @param requestId ID запроса
-- @return boolean Успешность отмены
function M.cancel(requestId)
    if not requestId then return false end
    if activeListeners[requestId] and Runtime then
        Runtime:removeEventListener("enterFrame", activeListeners[requestId])
        activeListeners[requestId] = nil
    end

    local cLib = loadNativeLibrary()
    if cLib and cLib.cancel then
        return cLib.cancel(requestId)
    elseif network and network.cancel then
        return network.cancel(requestId)
    end
    return false
end

--- Получение системных метрик использования памяти
-- @return table Таблица со статистикой памяти и активности
function M.getMemoryStats()
    local cLib = loadNativeLibrary()
    if cLib and cLib.getMemoryStats then
        return cLib.getMemoryStats()
    end
    return {
        nativeRSSMB = collectgarbage("count") / 1024.0,
        nativeRSSBytes = collectgarbage("count") * 1024,
        activeTasks = 0,
        totalCompleted = 0,
        totalFailed = 0,
        isHTTP3Configured = false,
        stackName = "Solar2D network.request (Fallback)",
        buildTimestamp = "Fallback (Pure Lua)"
    }
end

--- Запуск очистки мусора Lua и нативной памяти
-- @return boolean Успешность операции
function M.collectGarbage()
    if activeListeners then
        for reqId, listenerFunc in pairs(activeListeners) do
            if Runtime and Runtime.removeEventListener then
                Runtime:removeEventListener("enterFrame", listenerFunc)
            end
            activeListeners[reqId] = nil
        end
    end

    local cLib = loadNativeLibrary()
    if cLib and cLib.collectGarbage then
        cLib.collectGarbage()
    end

    collectgarbage("collect")
    collectgarbage("collect")
    return true
end

--- Вызов цикла обработки событий для изолированного CLI-тестирования
-- @param seconds Время прокачки событий в секундах
function M.pumpEvents(seconds)
    local cLib = loadNativeLibrary()
    if cLib and cLib.pumpEvents then
        cLib.pumpEvents(seconds)
    end
    -- В CLI-режиме без Solar2D Runtime опрашиваем активные polling-слушатели вручную.
    -- Создаём копию списка функций слушателей перед вызовом, чтобы удаление элементов
    -- внутри колбэков не сбивало итератор pairs в Lua.
    if activeListeners then
        local listenersToCall = {}
        for reqId, listenerFunc in pairs(activeListeners) do
            table.insert(listenersToCall, listenerFunc)
        end
        for i = 1, #listenersToCall do
            listenersToCall[i]()
        end
    end
end

return M
