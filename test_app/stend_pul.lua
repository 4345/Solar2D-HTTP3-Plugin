-- СТЕНД ДЛЯ ОТЛАДКИ ПУЛА СОЕДИНЕНИЙ QUIC.
--
-- test_direct.lua шлёт запросы строго по одному и ждёт каждый. В игре не так:
-- висит длинный опрос, и параллельно с ним уходят ходы. Счётчик живых потоков
-- в боевом журнале показывал 1-6 одновременных — значит воспроизводить надо
-- именно с наложением запросов, иначе отказ StreamSend не появится.
--
-- Запуск:  lua.exe stend_pul.lua [сколько_всего] [сколько_разом] [адрес] [длина_тела]
-- Длина тела > 0 переводит стенд на POST: именно у запросов с телом
-- StreamSend возвращает 0x80070057.
io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path

if not system then
    system = { getTimer = function() return os.clock() * 1000 end,
               pathForFile = function(f) return f end }
end

local vsego   = tonumber(arg and arg[1]) or 120
local razom   = tonumber(arg and arg[2]) or 4
local adres   = (arg and arg[3]) or "https://cloudflare-quic.com"
local telo_len = tonumber(arg and arg[4]) or 0
local telo    = telo_len > 0 and string.rep("x", telo_len) or nil
local metod   = telo and "POST" or "GET"

-- В CLI движка Solar2D нет, и запасной network.request звать некому. Без
-- заглушки запрос, ушедший на откат, не позовёт колбэк никогда и повесит
-- прогон. Заглушка отвечает сразу ошибкой: такой запрос виден как откат.
if not network then
    network = { request = function(url, method, listener, params)
        if listener then listener({ isError = true, status = -1, transport = "откат-заглушка" }) end
        return 0
    end, cancel = function() end }
end

local ok, http3 = pcall(require, "plugin_http3")
if not ok then print("плагин не загрузился: " .. tostring(http3)); os.exit(1) end
local st0 = http3.getMemoryStats()
print(string.format("стек: %s | сборка: %s", tostring(st0.stackName), tostring(st0.buildTimestamp)))
print(string.format("адрес: %s | метод: %s | тело: %d Б | всего: %d | одновременно: %d",
    adres, metod, telo_len, vsego, razom))
print("")

local zapushcheno, zaversheno = 0, 0
local udachno, oshibok = 0, 0
local po_transportu = {}
local vremena = {}
local v_polyote = 0

local function pustit()
    zapushcheno = zapushcheno + 1
    v_polyote = v_polyote + 1
    local nomer = zapushcheno
    local nachalo = os.clock()
    http3.request(adres, metod, function(evt)
        v_polyote = v_polyote - 1
        zaversheno = zaversheno + 1
        vremena[#vremena + 1] = (os.clock() - nachalo) * 1000
        local tr = tostring(evt and (evt.transport or evt.protocol) or "?")
        po_transportu[tr] = (po_transportu[tr] or 0) + 1
        if evt and not evt.isError and evt.status and evt.status < 400 then
            udachno = udachno + 1
        else
            oshibok = oshibok + 1
            if oshibok <= 5 then
                print(string.format("  запрос %d: status=%s isError=%s transport=%s reason=%s",
                    nomer, tostring(evt and evt.status), tostring(evt and evt.isError),
                    tr, tostring(evt and (evt.reason or evt.error))))
            end
        end
    end, { timeout = 5, body = telo, bodyType = telo and "binary" or nil,
           headers = { ["X-App-Req-Auth"] = "0000000000000000",
                       ["Content-Type"] = "text/plain",
                       ["X-App-Ts"] = "0000000000000000000",
                       ["X-App-Context-Id"] = "0000000000000000" } })
end

local predel = os.clock() + 300
while zaversheno < vsego and os.clock() < predel do
    while v_polyote < razom and zapushcheno < vsego do pustit() end
    http3.pumpEvents(0.005)
    if zaversheno > 0 and zaversheno % 20 == 0 and zaversheno ~= (_poslednij or -1) then
        _poslednij = zaversheno
        print(string.format("  ... %d/%d (успешно %d, ошибок %d)", zaversheno, vsego, udachno, oshibok))
    end
end

table.sort(vremena)
local function kvantil(d)
    if #vremena == 0 then return 0 end
    return vremena[math.max(1, math.floor(#vremena * d))]
end

print("")
http3.collectGarbage()
local stK = http3.getMemoryStats()
print(string.format("память: нативная %.2f МБ (было %.2f), куча Lua %.2f МБ, активных задач %d",
    stK.nativeRSSMB or 0, st0.nativeRSSMB or 0, collectgarbage("count") / 1024.0, stK.activeTasks or 0))
print("==========================================================")
print(string.format("завершено %d из %d: успешно %d, ошибок %d", zaversheno, vsego, udachno, oshibok))
print(string.format("время ответа: медиана %.0f мс, 90%% %.0f мс, максимум %.0f мс",
    kvantil(0.5), kvantil(0.9), vremena[#vremena] or 0))
local ts = {}
for k, v in pairs(po_transportu) do ts[#ts + 1] = string.format("%s=%d", k, v) end
table.sort(ts)
print("транспорт: " .. table.concat(ts, "  "))
print("==========================================================")
