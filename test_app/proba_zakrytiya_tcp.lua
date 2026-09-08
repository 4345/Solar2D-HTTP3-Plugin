-- Проверка закрытия запасного сеанса TCP.
-- Фаза 1: хост, где QUIC не поднимается (у него рукопожатие TLS по QUIC не
--         проходит) — запасной путь включается, сеанс WinHTTP создаётся.
-- Фаза 2: рабочий хост — QUIC выигрывает подряд, и сеанс должен закрыться.
io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path
if not system then system = { getTimer = function() return os.clock()*1000 end, pathForFile = function(f) return f end } end
if not network then
    network = { request = function(u, m, l, p) if l then l({ isError = true, status = -1, transport = "откат-заглушка" }) end return 0 end,
                cancel = function() end }
end
local http3 = require("plugin_http3")

local function poslat(adres, skolko, imya)
    local gotovo, tr = 0, {}
    for i = 1, skolko do
        http3.request(adres, "GET", function(evt)
            gotovo = gotovo + 1
            local t = tostring(evt and (evt.transport or evt.protocol) or "?")
            tr[t] = (tr[t] or 0) + 1
        end, { timeout = 5 })
    end
    local predel = os.clock() + skolko * 8
    while gotovo < skolko and os.clock() < predel do http3.pumpEvents(0.01) end
    local s = {}
    for k, v in pairs(tr) do s[#s+1] = string.format("%s=%d", k, v) end
    table.sort(s)
    print(string.format("%s: завершено %d из %d  [%s]", imya, gotovo, skolko, table.concat(s, " ")))
end

poslat("https://speed.cloudflare.com/__down?bytes=100", 3, "фаза 1 (QUIC не работает)")
poslat("https://cloudflare-quic.com", 8, "фаза 2 (QUIC работает)")
