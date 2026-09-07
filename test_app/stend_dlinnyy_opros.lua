-- СТЕНД ДЛИННОГО ОПРОСА.
--
-- Проверяем единственное, чего не покрывал stend_pul.lua: в игре всегда висит
-- GET /api/events (сервер держит ответ ~2 с, клиентский таймаут 5 с), и пока он
-- висит, к ТОМУ ЖЕ хосту уходят другие запросы. Вопрос был один: не выдаст ли
-- пул занятое соединение второму запросу и не закроет ли его по простою.
--
-- Только чтение: длинный опрос по несуществующему столу и короткие GET по
-- несуществующему пути. Ничего на сервере не меняется.
--
-- Запуск:  lua.exe stend_dlinnyy_opros.lua [секунд] [коротких_разом]
io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path

if not system then
    system = { getTimer = function() return os.clock() * 1000 end,
               pathForFile = function(f) return f end }
end

local skolko_sek = tonumber(arg and arg[1]) or 30
local korotkih   = tonumber(arg and arg[2]) or 2
local BASE       = "https://example.com"
local ustroystvo = "0000000000000000"

local ok, http3 = pcall(require, "plugin_http3")
if not ok then print("плагин не загрузился: " .. tostring(http3)); os.exit(1) end
print(string.format("стек: %s", tostring(http3.getMemoryStats().stackName)))
print(string.format("%d с | длинный опрос: 1 всегда в полёте | коротких разом: %d", skolko_sek, korotkih))
print("")

local zagolovki = { ["X-App-Req-Auth"] = ustroystvo,
                    ["X-App-Context-Id"] = ustroystvo }

local dlinnyh, dlinnyh_qu, dlinnyh_sboev = 0, 0, 0
local dlinnye_vremena = {}
local korotkih_vsego, korotkih_qu, korotkih_sboev = 0, 0, 0
local korotkie_vremena = {}
local v_polyote_kor = 0
local opros_letit = false

local function tr_quic(evt)
    local t = tostring(evt and (evt.transport or evt.protocol) or "?")
    return t:find("HTTP3") ~= nil or t:find("MsQuic") ~= nil
end

local function pustit_opros()
    opros_letit = true
    local n = os.clock()
    http3.request(BASE .. "/api/events?stol_id=" .. ustroystvo .. "&last_seq=1", "GET", function(evt)
        opros_letit = false
        dlinnyh = dlinnyh + 1
        dlinnye_vremena[#dlinnye_vremena + 1] = (os.clock() - n) * 1000
        if tr_quic(evt) then dlinnyh_qu = dlinnyh_qu + 1 end
        if not evt or evt.isError then dlinnyh_sboev = dlinnyh_sboev + 1 end
    end, { timeout = 5, headers = zagolovki })
end

local function pustit_korotkiy()
    v_polyote_kor = v_polyote_kor + 1
    local n = os.clock()
    http3.request(BASE .. "/api/net-takogo-puti", "GET", function(evt)
        v_polyote_kor = v_polyote_kor - 1
        korotkih_vsego = korotkih_vsego + 1
        korotkie_vremena[#korotkie_vremena + 1] = (os.clock() - n) * 1000
        if tr_quic(evt) then korotkih_qu = korotkih_qu + 1 end
        -- 404 здесь ожидаем, сбоем считаем только отсутствие ответа
        if not evt or evt.isError then korotkih_sboev = korotkih_sboev + 1 end
    end, { timeout = 5, headers = zagolovki })
end

local konec = os.clock() + skolko_sek
while os.clock() < konec do
    if not opros_letit then pustit_opros() end
    while v_polyote_kor < korotkih do pustit_korotkiy() end
    http3.pumpEvents(0.005)
end
local dozhdatsya = os.clock() + 8
while (opros_letit or v_polyote_kor > 0) and os.clock() < dozhdatsya do http3.pumpEvents(0.01) end

local function mediana(t)
    if #t == 0 then return 0 end
    table.sort(t); return t[math.max(1, math.floor(#t / 2))]
end

print("==========================================================")
print(string.format("длинный опрос:   %d шт, по QUIC %d, без ответа %d, медиана %.0f мс",
    dlinnyh, dlinnyh_qu, dlinnyh_sboev, mediana(dlinnye_vremena)))
print(string.format("короткие рядом:  %d шт, по QUIC %d, без ответа %d, медиана %.0f мс",
    korotkih_vsego, korotkih_qu, korotkih_sboev, mediana(korotkie_vremena)))
print("==========================================================")
