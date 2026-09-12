-- КОГДА именно приходят события прогресса — время от старта запроса, мс.
--
-- proba_progressa.lua показывает, СКОЛЬКО событий пришло и с какими числами, но
-- не когда. Этой разницы хватило, чтобы дефект выглядел иначе, чем был: в
-- событиях стояли нули, и казалось, будто не работают счётчики в нативной части.
-- Раскладка по времени показала обратное — счётчики исправны, а первые события
-- просто приходились на ожидание гонки Happy Eyeballs, когда не передавалось
-- ничего:
--     0 мс began 0/-1 ... 2000 мс progress 0/-1 ... 2500 мс progress 86016/102400
--
-- Держать отдельно стоит именно поэтому: «сколько» и «когда» отвечают на разные
-- вопросы, и без второго причину можно искать не там.
io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path
local kadry = {}
Runtime = { addEventListener = function(_, n, f) if n == "enterFrame" then kadry[#kadry+1] = f end end,
            removeEventListener = function(_, _, f) for i,g in ipairs(kadry) do if g==f then table.remove(kadry,i) break end end end }
if not system then system = { getTimer = function() return os.clock()*1000 end, pathForFile = function(f) return f end, DocumentsDirectory = "docs" } end
if not network then network = { request = function(u,m,l) if l then l({isError=true,status=-1}) end return 0 end, cancel=function() end } end
local http3 = require("plugin_http3")
local t0, gotovo = os.clock(), false
http3.request("https://httpbin.org/bytes/102400", "GET", function(e)
    print(string.format("  %6.0f мс  фаза=%-8s передано=%-8s ожидалось=%-8s транспорт=%s",
        (os.clock()-t0)*1000, tostring(e.phase), tostring(e.bytesTransferred),
        tostring(e.bytesEstimated), tostring(e.transport)))
    if e.phase == "ended" or e.isError then gotovo = true end
end, { progress = "download", timeout = 30 })
local predel = os.clock() + 35
while not gotovo and os.clock() < predel do
    http3.pumpEvents(0.01)
    local k = {} for i,f in ipairs(kadry) do k[i]=f end
    for _, f in ipairs(k) do f({ time = (os.clock()-t0)*1000 }) end
end
