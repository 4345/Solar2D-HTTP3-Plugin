-- Проверка прогресса передачи в ОПРОСНОМ слое (Windows).
--
-- Событий этот слой не шлёт: Lua дёргает checkRequest каждый кадр и получает
-- либо nil, либо готовый результат. Нативная часть ведёт счётчики, отдаёт их
-- через checkProgress, а фазы began/progress/ended делает обёртка. Стенд
-- проверяет именно это — что фазы приходят, числа растут и завершение сходится.
--
-- ВАЖНО: в CLI нет кадрового цикла Solar2D, а опрос обёртки живёт на
-- enterFrame. Поэтому Runtime подставляется здесь, и кадры крутит сам стенд.
-- Без этого не придёт вообще ничего, и это будет не отказ плагина.
--
-- Запуск с Windows, из каталога test_app:
--   "C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\win\bin\lua.exe" proba_progressa.lua
io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path

-- --- Подставной кадровый цикл -----------------------------------------------
local kadry = {}
Runtime = {
    addEventListener = function(_, imya, f) if imya == "enterFrame" then kadry[#kadry+1] = f end end,
    removeEventListener = function(_, _, f)
        for i, g in ipairs(kadry) do if g == f then table.remove(kadry, i) break end end
    end,
}
if not system then
    system = { getTimer = function() return os.clock() * 1000 end,
               pathForFile = function(f) return f end,
               DocumentsDirectory = "docs" }
end
if not network then
    network = { request = function(u, m, l) if l then l({ isError = true, status = -1 }) end return 0 end,
                cancel = function() end }
end

local http3 = require("plugin_http3")

-- Крутит кадры, пока gotov() не скажет «хватит» либо не выйдет срок.
-- Ждать фиксированное окно нельзя: прогон из пяти случаев занял бы минуты, а
-- соседние стенды выходят сразу по ответу.
local function krutit(sekund, gotov)
    local predel = os.clock() + sekund
    while os.clock() < predel do
        if gotov and gotov() then return end
        http3.pumpEvents(0.01)
        -- Копия списка: подписчик снимает себя на завершении, а править
        -- таблицу во время обхода нельзя. unpack тут не годится — на пустом
        -- списке он не вернёт ничего, и выражение свалится в table.unpack,
        -- которого в Lua 5.1 нет.
        local kopiya = {}
        for i = 1, #kadry do kopiya[i] = kadry[i] end
        for _, f in ipairs(kopiya) do
            local ok, err = pcall(f, {})
            if not ok then print("  [кадр] ошибка: " .. tostring(err)) end
        end
    end
end

print("progress_podderzhivaetsya() = " .. tostring(http3.progress_podderzhivaetsya()))
print("(ожидается true; false значит, что DLL собрана без checkProgress)")
print("")

-- --- Один прогон ------------------------------------------------------------
local function progon(imya, url, metod, params, zhdat)
    local fazy, chisla, itog = {}, {}, nil
    params.timeout = params.timeout or 30
    http3.request(url, metod, function(e)
        if e.phase and e.phase ~= "ended" then
            fazy[#fazy + 1] = e.phase
            chisla[#chisla + 1] = string.format("%s/%s",
                tostring(e.bytesTransferred), tostring(e.bytesEstimated))
        else
            itog = e
        end
    end, params)
    krutit(zhdat or 30, function() return itog ~= nil end)

    print(imya)
    print(string.format("  транспорт: %s", tostring(itog and (itog.protocol or itog.transport))))
    print(string.format("  промежуточных событий: %d  [%s]", #fazy, table.concat(fazy, ",")))
    if #chisla > 0 then
        local pokaz = {}
        for i = 1, math.min(#chisla, 6) do pokaz[i] = chisla[i] end
        print(string.format("  переданное/ожидаемое: %s%s", table.concat(pokaz, " "),
              #chisla > 6 and " ..." or ""))
    end
    if itog then
        print(string.format("  итог: status=%s isError=%s фаза=%s передано=%s ожидалось=%s длина тела=%s",
            tostring(itog.status), tostring(itog.isError), tostring(itog.phase),
            tostring(itog.bytesTransferred), tostring(itog.bytesEstimated),
            tostring(itog.response and #itog.response)))
    else
        print("  итог: ОТВЕТА НЕ БЫЛО")
    end
    print("")
end

-- 1. Приём с известной длиной. Ожидаем: began, несколько progress,
--    bytesEstimated равен Content-Length, итог совпадает с длиной тела.
progon("1. download, длина известна (httpbin отдаёт не больше 100 КБ)",
       "https://httpbin.org/bytes/102400", "GET", { progress = "download" })

-- 2. Приём по HTTP/3. Ожидаем: фазы идут, но bytesEstimated = -1 — у QUIC
--    длина тела до разбора кадров неизвестна, и врать процентом нельзя.
progon("2. download по HTTP/3 (ожидается bytesEstimated = -1)",
       "https://cloudflare-quic.com/", "GET", { progress = "download" })

-- 3. Отправка. НА WINDOWS ожидаем только began и ended: тело уходит одним
--    куском на обоих транспортах, промежуточным значениям взяться неоткуда, и
--    это не дефект. На push-платформах (Android, Apple) тот же стенд покажет и
--    промежуточные — там отправку считает сам сетевой стек.
-- Адрес именно такой: httpbin.org по QUIC для POST не отвечает, плагин уходит
-- на запасной network.request, а в CLI это заглушка стенда — и случай проверял
-- заглушку, а не плагин (status=-1, фаза nil). cloudflare-quic.com принимает
-- POST по QUIC, проверено отдельно.
progon("3. upload (на Windows ожидаются только began и ended)",
       "https://cloudflare-quic.com/", "POST",
       { progress = "upload", body = string.rep("A", 262144) })

-- 4. Без progress. Ожидаем НОЛЬ промежуточных событий.
progon("4. без progress (ожидается 0 промежуточных)",
       "https://cloudflare-quic.com/", "GET", {})

-- 5. Пачка параллельных: хватает ли слотов (их 64) и не теряются ли завершения.
do
    local vsego, gotovo, s_progressom = 50, 0, 0
    for i = 1, vsego do
        local videl = false
        http3.request("https://cloudflare-quic.com/", "GET", function(e)
            if e.phase and e.phase ~= "ended" then
                if not videl then videl = true; s_progressom = s_progressom + 1 end
            else
                gotovo = gotovo + 1
            end
        end, { progress = "download", timeout = 30 })
    end
    krutit(60, function() return gotovo >= vsego end)
    local st = http3.getMemoryStats()
    print("5. пачка из 50 запросов с progress")
    print(string.format("  завершилось: %d из %d", gotovo, vsego))
    print(string.format("  получили хотя бы одно событие прогресса: %d", s_progressom))
    print(string.format("  активных задач по завершении: %s (ожидается 0)",
          tostring(st and st.activeTasks)))
end
