-- Проверка, что крупный набор заголовков доходит целиком.
-- Раньше он обрезался молча в пяти местах: при сборке (2040), в кодировщике на
-- имени (255) и значении (1535), на его выходном буфере (3072) и на пути
-- WinHTTP (1024 широких символа).
io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path
if not system then system = { getTimer = function() return os.clock()*1000 end, pathForFile = function(f) return f end } end
if not network then
    network = { request = function(u, m, l, p) if l then l({ isError = true, status = -1 }) end return 0 end,
                cancel = function() end }
end
local http3 = require("plugin_http3")

for _, dlina in ipairs({ 40, 1600, 4000 }) do
    local headers = { ["Content-Type"] = "text/plain",
                      ["X-Stend-Dlinnyy"] = string.rep("z", dlina) }
    local gotovo, itog = false, nil
    http3.request("https://cloudflare-quic.com", "GET", function(evt)
        gotovo = true
        itog = string.format("status=%s transport=%s",
            tostring(evt and evt.status), tostring(evt and (evt.transport or evt.protocol)))
    end, { headers = headers, timeout = 5 })
    local predel = os.clock() + 12
    while not gotovo and os.clock() < predel do http3.pumpEvents(0.01) end
    print(string.format("значение заголовка %5d Б -> %s", dlina, itog or "ОТВЕТА НЕ БЫЛО"))
end
