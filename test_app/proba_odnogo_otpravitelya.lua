-- Стенд гонки Happy Eyeballs: запрос отправляет РОВНО ОДИН путь.
--
-- Гонка идёт за соединение: QUIC стартует сразу, TCP — если QUIC не соединился
-- за окно. Раньше каждый путь отправлял запрос сам, как только мог, и если QUIC
-- соединялся чуть позже старта TCP, запрос доходил до сервера ДВАЖДЫ, а
-- вызывающий видел один ответ. Для POST это повтор действия.
--
-- Случай редкий (холодное соединение, рукопожатие дольше окна), поэтому стенд
-- его ВЫЗЫВАЕТ: библиотека собирается с окном 1 мс, TCP стартует, пока QUIC ещё
-- рукопожимается. Сколько раз запрос ушёл на самом деле, видно только изнутри —
-- по журналу нативного слоя: каждая отправка оставляет строку
-- «StreamSend[...]» (QUIC) либо «WinHttpSendRequest...» (TCP).
--
-- Сборка и запуск с Windows:
--   win32\build_stend.bat /DHTTP3_LOG_ENABLED=1 /DHTTP3_PROBA_OKNO_MS=1
--   cd test_app
--   "C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\win\bin\lua.exe" proba_odnogo_otpravitelya.lua
--
-- Хосты разные: пул держит соединение к хосту 20 с, и повторный запрос к тому
-- же хосту пошёл бы по тёплому соединению, где гонки нет вовсе.
io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path

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

-- Журнал нативный слой пишет во временный каталог пользователя (LogWrite).
local ZHURNAL = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\plugin_http3.log"
os.remove(ZHURNAL)

local http3 = require("plugin_http3")

local function krutit(sekund, gotov)
    local predel = os.clock() + sekund
    while os.clock() < predel do
        if gotov and gotov() then return end
        http3.pumpEvents(0.01)
        local kopiya = {}
        for i = 1, #kadry do kopiya[i] = kadry[i] end
        for _, f in ipairs(kopiya) do pcall(f, {}) end
    end
end

local HOSTY = {
    "https://cloudflare-quic.com/",
    "https://www.cloudflare.com/",
    "https://blog.cloudflare.com/",
    "https://www.google.com/",
    "https://www.youtube.com/",
}

local otvetov = 0
for _, url in ipairs(HOSTY) do
    local itog
    http3.request(url, "GET", function(e) if e.phase == "ended" or e.phase == nil then itog = e end end,
                  { timeout = 10 })
    krutit(12, function() return itog ~= nil end)
    -- Проигравший путь живёт дольше опубликованного ответа: даём ему дойти до
    -- отправки (или до отказа от неё), прежде чем считать.
    krutit(3)
    print(string.format("  %-32s статус %s, %s", url, tostring(itog and itog.status),
        tostring(itog and (itog.transport or itog.protocol))))
    if itog and not itog.isError then otvetov = otvetov + 1 end
end
krutit(2)

local f = io.open(ZHURNAL, "r")
if not f then
    print("НЕТ ЖУРНАЛА " .. ZHURNAL .. " — библиотека собрана без /DHTTP3_LOG_ENABLED=1")
    os.exit(2)
end
local quic, tcp, ustupil, okno = 0, 0, 0, nil
for stroka in f:lines() do
    if stroka:find("StreamSend%[") then quic = quic + 1 end
    if stroka:find("WinHttpSendRequest%.%.%.") then tcp = tcp + 1 end
    if stroka:find("уступает") then ustupil = ustupil + 1 end
    if stroka:find("окно соединения, мс") then okno = stroka:match("(%S+)%s*$") end
end
f:close()

local zaprosov = #HOSTY
print("")
print(string.format("окно соединения: %s (ожидается 1 — стенд собран с /DHTTP3_PROBA_OKNO_MS=1)", tostring(okno)))
print(string.format("запросов: %d, ответов: %d", zaprosov, otvetov))
print(string.format("отправок по QUIC: %d, по TCP: %d, всего: %d", quic, tcp, quic + tcp))
print(string.format("уступок: %d", ustupil))
if tcp == 0 then
    print("НЕ ПРОВЕРЕНО: TCP не стартовал ни разу — гонка не состоялась")
    os.exit(2)
elseif quic + tcp == zaprosov then
    print("PASS: каждый запрос отправлен ровно одним путём")
else
    print(string.format("FAIL: отправок %d на %d запросов — запрос уходил обоими путями", quic + tcp, zaprosov))
    os.exit(1)
end
