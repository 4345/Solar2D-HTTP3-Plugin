-- Проверка, что параметр timeout доходит до нативного слоя.
-- Адрес заведомо молчащий: пакеты уходят в никуда, ответа не будет никогда,
-- значит запрос обязан завершиться ровно по своему таймауту, а не по зашитым 3с.
io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path
if not system then system = { getTimer = function() return os.clock()*1000 end, pathForFile = function(f) return f end } end
if not network then
    network = { request = function(u, m, l, p) if l then l({ isError = true, status = -1 }) end return 0 end,
                cancel = function() end }
end
local http3 = require("plugin_http3")
for _, t in ipairs({ 1, 5 }) do
    local gotovo, n = false, os.clock()
    http3.request("https://10.255.255.1/molchit", "GET", function() gotovo = true end, { timeout = t })
    local predel = os.clock() + t + 6
    while not gotovo and os.clock() < predel do http3.pumpEvents(0.01) end
    print(string.format("timeout = %d с  ->  завершилось за %.2f с", t, os.clock() - n))
end
