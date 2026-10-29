-- Проверка привязки ключей (http3.setPins) на живом сервере с сертификатом
-- Let's Encrypt. Хост — аргументом, по умолчанию тестовый адрес Let's Encrypt
-- с цепочкой до ISRG Root X1:
--
--   cd test_app
--   "C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\win\bin\lua.exe" proba_privyazki.lua [хост]
--
-- Что проверяется:
--   * без setPins — как всегда (привязка по желанию, не по умолчанию);
--   * набор с ключом цепочки — запрос проходит;
--   * набор без ключа цепочки — PIN_FAILED, и network.request НЕ зовётся
--     (повтор мимо привязки сделал бы её бессмысленной);
--   * тот же набор с вышедшим сроком — проходит (только системная проверка);
--   * хост вне списка — проходит.
io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path
if not system then system = { getTimer = function() return os.clock() * 1000 end, pathForFile = function(f) return f end } end
local OTKATOV = 0
network = { request = function(u, m, l, p) OTKATOV = OTKATOV + 1; if l then l({ isError = true, status = -1 }) end return 0 end,
            cancel = function() end }
local http3 = require("plugin_http3")

local HOST = arg and arg[1] or "valid-isrgrootx1.letsencrypt.org"
local URL = "https://" .. HOST .. "/"
-- SPKI SHA-256 корней Let's Encrypt (сняты OpenSSL с самих сертификатов).
local X1 = "sha256/C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M="
local X2 = "sha256/diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI="
local YE = "sha256/sCkq5UWXjg+7mKu9lMhhYF5bGLsy7VI/UNW3tccdR7w="
local CHUZHOY = "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
local BUDUSHCHEE, PROSHLOE = os.time() + 365 * 86400, os.time() - 60

local provalov = 0
local function proverit(imya, uslovie, podrobno)
    print((uslovie and "PASS  " or "FAIL  ") .. imya .. (uslovie and "" or ("  -- " .. tostring(podrobno))))
    if not uslovie then provalov = provalov + 1 end
end

local function zapros()
    local itog
    http3.request(URL, "GET", function(e) if e.phase == nil or e.phase == "ended" then itog = e end end, { timeout = 8 })
    local predel = os.clock() + 15
    while not itog and os.clock() < predel do http3.pumpEvents(0.01) end
    return itog or { isError = true, reason = "нет ответа" }
end

local function opisanie(e)
    return string.format("isError=%s reason=%s status=%s error=%s", tostring(e.isError), tostring(e.reason),
        tostring(e.status), tostring(e.error))
end

-- Второй аргумент "rano" — набор ДО первого запроса: так его задают
-- приложения, и только так msquic (Windows) проверяет ключ в рукопожатии QUIC.
local RANO = arg and arg[2] == "rano"
print("Хост: " .. HOST .. (RANO and " (набор до первого запроса)" or ""))
local e
if RANO then
    http3.setPins({ hosts = { HOST }, pins = { CHUZHOY, X1, X2, YE }, expires = BUDUSHCHEE })
    e = zapros()
    proverit("набор до первого запроса, ключ в наборе — проходит", not e.isError, opisanie(e))
    http3.setPins({ hosts = {}, pins = {}, expires = 0 })
end
e = zapros()
proverit("без setPins — запрос проходит, как всегда", not e.isError, opisanie(e))

local ok, prichina = http3.setPins({ hosts = { HOST }, pins = { CHUZHOY }, expires = BUDUSHCHEE })
proverit("набор принят нативным слоем", ok, prichina)
OTKATOV = 0
e = zapros()
proverit("ключа цепочки нет в наборе — PIN_FAILED", e.isError and e.reason == "PIN_FAILED", opisanie(e))
proverit("и без повтора через network.request", OTKATOV == 0, "повторов: " .. OTKATOV)

http3.setPins({ hosts = { HOST }, pins = { CHUZHOY, X1, X2, YE }, expires = BUDUSHCHEE })
e = zapros()
proverit("ключ корня цепочки в наборе — запрос проходит", not e.isError, opisanie(e))

http3.setPins({ hosts = { HOST }, pins = { CHUZHOY }, expires = PROSHLOE })
e = zapros()
proverit("срок набора вышел — только системная проверка, запрос проходит", not e.isError, opisanie(e))

http3.setPins({ hosts = { "drugoy.example.com" }, pins = { CHUZHOY }, expires = BUDUSHCHEE })
e = zapros()
proverit("хост вне списка — запрос проходит", not e.isError, opisanie(e))

local nok, nprichina = http3.setPins({ hosts = { HOST }, pins = { "sha256/korotkiy" }, expires = BUDUSHCHEE })
proverit("неверный отпечаток — набор не принят", not nok and nprichina ~= nil, tostring(nprichina))

http3.setPins({ hosts = {}, pins = {}, expires = 0 })
e = zapros()
proverit("пустой набор — привязка снята", not e.isError, opisanie(e))

print("\nПРОВАЛОВ: " .. provalov)
os.exit(provalov == 0 and 0 or 1)
