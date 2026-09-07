-- Проверка гипотезы: почему /get-voice-list не работает по HTTP/3.
-- Гоняем настоящий плагин через lua.exe из Corona Native.
--   1. example.com с минимальными заголовками  (в бою работает)
--   2. example.com с ТЕМИ ЖЕ заголовками, что у голосового запроса
--   3. example.com/get-voice-list как есть      (в бою всегда 504)
-- Если ломается второй — дело в заголовках (ручной QPACK), а не в адресе.
io.stdout:setvbuf("no")
package.path = "../lua/?.lua;./?.lua;" .. package.path

if not system then
    system = { getTimer = function() return os.clock() * 1000 end,
               pathForFile = function(f) return f end }
end

local ok, http3 = pcall(require, "plugin_http3")
print("плагин загружен:", ok)
local st = http3.getMemoryStats()
print("стек:", tostring(st.stackName))
print("")

local ustroystvo = "0000000000000000"
local proby = {
    { imya = "1. example.com, минимум заголовков",
      url = "https://example.com/api/events?stol_id=0000000000000000&last_seq=1",
      headers = { ["X-App-Req-Auth"] = ustroystvo } },
    { imya = "2. example.com, заголовки как у голосового",
      url = "https://example.com/api/events?stol_id=0000000000000000&last_seq=1",
      headers = { ["X-App-Req-Auth"] = ustroystvo,
                  ["Content-Type"] = "text/plain",
                  ["X-App-Ts"] = "0000000000000000000",
                  ["X-App-Context-Id"] = "0000000000000000" } },
    { imya = "3. example.com/get-voice-list, как в игре",
      url = "https://example.com/get-voice-list",
      headers = { ["X-App-Req-Auth"] = ustroystvo,
                  ["Content-Type"] = "text/plain",
                  ["X-App-Ts"] = "0000000000000000000",
                  ["X-App-Context-Id"] = "0000000000000000" } },
    { imya = "4. example.com/get-voice-list, минимум заголовков",
      url = "https://example.com/get-voice-list",
      headers = { ["X-App-Req-Auth"] = ustroystvo } },
}

for _, p in ipairs(proby) do
    local gotovo, itog = false, nil
    local nachalo = os.clock()
    http3.request(p.url, "GET", function(evt)
        gotovo = true
        itog = string.format("status=%s isError=%s protocol=%s transport=%s reason=%s",
            tostring(evt and evt.status), tostring(evt and evt.isError),
            tostring(evt and evt.protocol), tostring(evt and evt.transport),
            tostring(evt and (evt.reason or evt.error)))
    end, { headers = p.headers, timeout = 8 })

    local predel = os.clock() + 12
    while not gotovo and os.clock() < predel do
        http3.pumpEvents(0.1)
    end
    print(p.imya)
    print(string.format("   %s   (%.2fс)", itog or "ОТВЕТА НЕ БЫЛО", os.clock() - nachalo))
    print("")
end
