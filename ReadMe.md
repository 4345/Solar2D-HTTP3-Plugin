# Плагин Solar2D HTTP/3 (QUIC) Protocol

Универсальный высокопроизводительный плагин сетевого протокола **HTTP/3 (QUIC)** для игрового движка **Solar2D**. Поддерживает рабочие среды **Windows (Desktop & Simulator)**, **Android**, **iOS (Device & Simulator)** и **macOS (Desktop & Simulator)** с автоматическим резервным переключением (Fallback).

Официальный репозиторий проекта: `https://github.com/4345/Solar2D-HTTP3-Plugin`

---

## 🚀 Особенности реализации модуля

### 1. Архитектура нативных сетевых стеков по платформам

| Платформа | Используемый нативный стек | Режим передачи событий | Особенности реализации |
| :--- | :--- | :--- | :--- |
| **Windows (`win32`, `win32-sim`)** | C++ / **MsQuic (Microsoft QUIC)** & **WinHTTP** | Polling / `enterFrame` | Независимый C++ модуль без привязки к тяжелому C Runtime CRT. Высокая пропускная способность при минимизации накладных расходов памяти. |
| **iOS / macOS (`iphone`, `macOS`)** | Objective-C++ / **`NSURLSession`** & **`Network.framework`** | Async Push Callback | Принудительное включение протокола HTTP/3 через `assumesHTTP3Capable = YES`. Безопасная работа с памятью через прямые C-буферы `malloc`/`free`, полностью исключающая утечки Foundation ARC. |
| **Android (`android`)** | Java / **Cronet** | JNI Event Dispatcher | Полная поддержка мобильных архитектур (ARM64, x86_64). Тело и ответ передаются через Lua Bridge как `byte[]` — двоичные данные не портятся. Kotlin не используется. |
| **Fallback (Универсальный)** | Lua / **`network.request`** | Solar2D Network Loop | Прозрачный автоматический переход на встроенный стек Solar2D `network.request`, если нативная библиотека недоступна на целевом устройстве или сервере. Параметры запроса передаются в него ПОЛНОСТЬЮ, включая `bodyType`. |

### 2. Производительность и контроль памяти

- **Отсутствие задержек (Zero-RTT Connection Setup)**: Ускоренная установка соединения благодаря возможностям TLS 1.3 + QUIC.
- **Устойчивость к потере пакетов**: Отсутствие проблемы Head-of-Line Blocking благодаря раздельной обработке мультиплексированных потоков HTTP/3.
- **Мониторинг физической памяти**: Нативный метод `http3.getMemoryStats()` возвращает реальное объём занимаемой физической памяти (RSS) и количество активных сетевых задач.
- **Принудительное очищение памяти**: Нативный вызов `http3.collectGarbage()` безопасно очищает задействованные пулы памяти и запускает сборщик мусора Lua.

### 3. Двоичные данные и `bodyType`

Плагин пригоден для двоичных протоколов (msgpack, protobuf, сырые файлы): тело
запроса и тело ответа проходят **по длине**, а не как C-строка и не через
перекодировку.

| Платформа | Тело запроса | Тело ответа |
| :--- | :--- | :--- |
| Windows / Apple | `lua_tolstring` | `lua_pushlstring` |
| Android | `LuaState.toByteArray` → `UploadDataProviders.create(byte[])` | `ByteArrayOutputStream.toByteArray` → `LuaState.pushString(byte[])` |
| Fallback | `network.request` с исходным `bodyType` | строка Lua, как её отдаёт Solar2D |

Параметр `bodyType = "binary"` поддерживается в том же смысле, что и в
`network.request`. На нативных путях он не требуется — там байты и так идут как
байты, — но в режиме отката передаётся дальше, потому что без него Solar2D
отправляет тело как текст в UTF-8 и портит двоичные данные.

В режиме отката передаются все параметры запроса: помимо `headers`, `body` и
`timeout` — `bodyType`, `progress`, `response`, `handleRedirects`.

**Умолчание `timeout` — 3 секунды** (в `network.request` — 30). Такого ожидания
не требует ни один сценарий, а в iOS/macOS 3 секунды приняты стандартом для
HTTP/3.

### 4. Имя нативного модуля: `plugin.http3.ntv`

Solar2D ищет загрузчик по имени требуемого модуля: `require("a.b.c")` → класс
`a.b.c.LuaLoader`. Нативный модуль плагина называется `plugin.http3.ntv`:
сегмент `native` в имени пакета невозможен, это ключевое слово Java. Загрузчик
написан на Java, Kotlin в плагине не используется.

Lua-модуль пробует два имени: сначала `plugin.http3.ntv`, затем
`plugin.http3.native` — второе экспортируют готовые бинарники Apple и Windows.

---

## 🛠 Подключение плагина в конфигурации приложений (`build.settings`)

Подключить плагин можно двумя способами: по прямым ссылкам на архивы этого
репозитория или локально, из каталога плагинов Solar2D. Первый способ проще,
второй нужен при доработке плагина — и он же единственный, если вы держите форк
закрытым: Solar2D скачивает архивы обычным HTTPS-запросом, без авторизации, и
для закрытого репозитория получит 404, уронив сборку на всех платформах сразу.

### Способ 1 — прямые ссылки

```lua
-- build.settings
settings =
{
    plugins =
    {
        ["plugin.http3"] =
        {
            publisherId = "ovh.azi",
            supportedPlatforms =
            {
                -- Нативная сборка для Windows Desktop
                win32 = { url = "https://raw.githubusercontent.com/4345/Solar2D-HTTP3-Plugin/main/plugins/win32/data.tgz" },

                -- Нативная сборка для Windows Solar2D Simulator
                ["win32-sim"] = { url = "https://raw.githubusercontent.com/4345/Solar2D-HTTP3-Plugin/main/plugins/win32-sim/data.tgz" },

                -- Нативная сборка для Android устройств
                android = { url = "https://raw.githubusercontent.com/4345/Solar2D-HTTP3-Plugin/main/plugins/android/data.tgz" },

                -- Нативная сборка для iOS устройств (iPhone / iPad)
                iphone = { url = "https://raw.githubusercontent.com/4345/Solar2D-HTTP3-Plugin/main/plugins/iphone/data.tgz" },

                -- Нативная сборка для iOS Симулятора Xcode
                ["iphone-sim"] = { url = "https://raw.githubusercontent.com/4345/Solar2D-HTTP3-Plugin/main/plugins/iphone-sim/data.tgz" },

                -- Нативная сборка для macOS Desktop
                macOS = { url = "https://raw.githubusercontent.com/4345/Solar2D-HTTP3-Plugin/main/plugins/macOS/data.tgz" },

                -- Нативная сборка для macOS Solar2D Simulator
                ["mac-sim"] = { url = "https://raw.githubusercontent.com/4345/Solar2D-HTTP3-Plugin/main/plugins/mac-sim/data.tgz" },

                -- Универсальный Lua Fallback
                lua = { url = "https://raw.githubusercontent.com/4345/Solar2D-HTTP3-Plugin/main/plugins/lua/data.tgz" },
            }
        },
    },

    android =
    {
        usesPermissions =
        {
            "android.permission.INTERNET",
            "android.permission.ACCESS_NETWORK_STATE",
        },
    },
}
```

### Android: обёртку кладите в приложение

На Android Lua-часть плагина из `data.tgz` в сборку **не попадает** — так
устроена сборка Solar2D, и официальные Android-плагины Lua-файлов в архивах не
держат. `require("plugin.http3")` там ищет скомпилированный модуль в ресурсах
приложения, а не находя, откатывается на `network.request` — молча:

```
module 'plugin.http3' not found: resource (plugin.http3.lu) does not exist in archive
    no Java class 'plugin.http3.LuaLoader'
```

Поэтому положите `lua/plugin_http3.lua` в своё приложение файлом
`plugin/http3.lua` (относительно корня проекта, рядом с `main.lua`). Он
скомпилируется вместе с приложением, и модуль найдётся на ВСЕХ платформах.
Нативную часть по-прежнему даёт архив платформы: обёртка сама ищет её под
именами `plugin.http3.ntv` и `plugin.http3.native`.

### Способ 2 — локально (из каталога плагинов Solar2D)

Разложите содержимое каталога `plugins/` в локальное хранилище плагинов
Solar2D, сохранив имена платформ:

```
%APPDATA%\Solar2DPlugins\ovh.azi\plugin.http3\<платформа>\
```

(на macOS — `~/Library/Application Support/Solar2DPlugins/ovh.azi/plugin.http3/`).
В каждой платформенной папке должен лежать её `data.tgz` — сборка берёт именно
архив, а не файлы рядом с ним. После этого объявление сокращается до одной
строки, без `supportedPlatforms`:

```lua
plugins =
{
    ["plugin.http3"] = { publisherId = "ovh.azi" },
},
```

Локальное хранилище имеет приоритет над сетевым каталогом плагинов, поэтому так
подключается и рабочая копия при разработке. Именно этот способ используют
`test_app/build.settings` и `Apple/build.settings` в этом репозитории.

Android-сборку плагина туда кладёт задача Gradle:

```
cd android && ./gradlew :plugin:deployToLocalSolar2DRepo
```

Она кладёт архив по имени плагина из `build.settings` — то есть в
`plugin.http3/android`, откуда Solar2D его и читает. Копировать вручную не надо.

**Архивы платформ.** Solar2D берёт при сборке ИМЕННО `data.tgz`, а не файлы
рядом с ним, поэтому после правки любого файла платформы архив надо пересобрать:

```
python3 tools/sobrat_arhivy.py
```

Скрипт собирает `win32`, `win32-sim`, `android` и `lua` из файлов каталога и
следит за главным: в каждом архиве должна лежать Lua-обёртка `plugin_http3.lua`
— модуль плагина называется `plugin.http3`, и это именно она (нативная часть
объявляет `plugin.http3.ntv`, а не `plugin.http3`). Ключ `--proverit`
показывает состав всех архивов, ничего не пересобирая, `--bez-gradle` не
трогает AAR.

Нужен только Python 3.8+. Прежде скрипт был на PowerShell и работал лишь под
Windows — то есть ровно там, где Apple-часть и не собирается, а значит
проверить её состав на маке было нечем.

**Apple собирается только на маке.** Нативная часть iOS и macOS — это
Objective-C++, её собирает clang из Xcode, и под Windows этих платформ не
собрать вовсе. Поэтому `sobrat_arhivy.py` их не трогает, а только проверяет
состав. Собирает их на macOS:

```
Apple/build.sh                 # iphone, iphone-sim, macOS, mac-sim
Apple/deployLocal.sh           # то же + выкладка в ~/Solar2DPlugins
```

Правки в `shared/SimulatorPluginLibrary.mm`, сделанные на Windows, в архивы
Apple НЕ попадают — их надо довезти этим скриптом с мака.

### macOS: почему нативная часть называется `plugin_http3_native.dylib`

Имя не произвольное. Lua ищет модуль сначала по `package.path` (`.lua`) и лишь
потом по `package.cpath` (`.dylib`). В архиве лежит и обёртка
`plugin_http3.lua`, и нативная часть; если назвать её `plugin_http3.dylib`, обе
претендуют на модуль `plugin.http3` — выигрывает обёртка, а библиотека не
грузится вообще. Обёртка же ищет нативную часть под именами `plugin.http3.ntv`
и `plugin.http3.native` (себя саму она не ищет — это была бы рекурсия), не
находит ничего и уходит в откат на `network.request`.

Видно это не по ошибке, а по трафику: HTTP/3 нет, всё идёт по TCP. Поэтому
dylib называется так же, как библиотека Windows, — по второму из искомых имён.

### macOS: карантин Gatekeeper

macOS метит скачанные файлы атрибутом `com.apple.quarantine`, и `tar` переносит
метку с архива на всё, что из него распаковано. Gatekeeper затем отказывается
грузить такой `.dylib`:

```
Apple не удалось подтвердить, что файл «plugin_http3_native.dylib»
не содержит вредоносного ПО
```

Для плагина это снова выглядит не ошибкой, а молчаливым откатом на TCP. Снять
метку:

```bash
xattr -dr com.apple.quarantine ~/Library/Application\ Support/Corona/Simulator/Plugins
```

`Apple/deployLocal.sh` делает это сам.

**Чем собирать.** Нужен JDK 17 (проверено) — им же располагает и сама Solar2D:
`<Solar2D>/Corona/jre`. На JDK 25 сборка падает ещё на конфигурации, с
`IllegalArgumentException: 25.0.3` из `JavaVersion.parse`: компилятор Kotlin,
которым Gradle 8.13 собирает скрипты `.kts`, такую версию не разбирает. Если
Android Studio обновилась и её JDK стал 25-м, укажите другой явно. На Windows
корневой `build.gradle.kts` берёт путь к Corona Native из переменной
`CORONA_ROOT`, её тоже нужно задать:

```
set JAVA_HOME=C:\Program Files (x86)\Corona Labs\Corona\jre
set CORONA_ROOT=C:/Program Files (x86)/Corona Labs/Corona/Native
cd android && gradlew :plugin:deployToLocalSolar2DRepo
```

---

## 💻 Инициализация и использование API в Lua

### 1. Простая инициализация модуля

```lua
-- Инициализация плагина HTTP/3
local http3 = require("plugin.http3")

-- Выполнение базового HTTP/3 GET запроса
local reqId = http3.request("https://cloudflare-quic.com", "GET", function(event)
    if event.isError then
        print("[HTTP/3] Ошибка запроса:", event.error or event.reason)
    else
        print("[HTTP/3] Код ответа:", event.status)
        print("[HTTP/3] Протокол:", event.protocol)   -- HTTP/3 (QUIC / h3)
        print("[HTTP/3] Транспорт:", event.transport) -- Native HTTP/3 или Fallback
        print("[HTTP/3] Ответ сервера:", string.sub(event.response, 1, 200))
    end
end, { timeout = 5.0 })

print("Запрос запущен с ID:", reqId)
```

### 2. Выполнение POST-запроса с заголовками и телом

```lua
local http3 = require("plugin.http3")

local headers = {}
headers["Content-Type"] = "application/json"
headers["Accept"] = "application/json"

local postData = '{"user": "Solar2D", "action": "ping"}'

http3.request("https://httpbin.org/post", "POST", function(event)
    if not event.isError then
        print("Данные успешно отправлены по HTTP/3!")
        print("Ответ:", event.response)
    end
end, {
    headers = headers,
    body = postData,
    timeout = 10.0
})
```

### 2а. Двоичное тело (`bodyType = "binary"`)

В примере ниже `encoder` — любой двоичный сериализатор (MessagePack, Protobuf,
собственный формат); плагин с его содержимым ничего не делает и передаёт байты
как есть.

```lua
local http3 = require("plugin.http3")

local headers = { ["Content-Type"] = "application/octet-stream" }

http3.request("https://example.com/api", "POST", function(event)
    if not event.isError then
        -- event.response — сырые байты, длина сохранена, декодировать можно как есть
        local otvet = encoder.decode(event.response)
    end
end, {
    headers = headers,
    body = encoder.encode({ action = "ping" }),
    bodyType = "binary",   -- как в network.request
    timeout = 3,
})
```

Байты не портятся ни на одной платформе, включая режим отката: `bodyType`
передаётся в `network.request` дальше. Подробнее — раздел «Двоичные данные и
`bodyType`» выше.

### 2б. Скачивание и выгрузка файлов с прогрессом

`http3.download` и `http3.upload` повторяют аргументы `network.download` и
`network.upload` из Solar2D, поэтому подменяются в существующем коде один к
одному:

```lua
http3.download("https://example.com/avatar.jpg", "GET", function(event)
    if event.phase == "progress" then
        print(("принято %d из %d"):format(event.bytesTransferred, event.bytesEstimated))
    elseif event.phase == "ended" and not event.isError then
        print("файл сохранён")
    end
end, { progress = true }, "avatar.jpg", system.DocumentsDirectory)
```

События хода передачи (`began` / `progress` / `ended` с `bytesTransferred` и
`bytesEstimated`) шлёт **нативный слой**, и есть они там, где доставка идёт
push-коллбэком — сейчас это Android. `bytesEstimated = -1` означает «сервер не
сообщил Content-Length» — ровно как в Solar2D; полосу в этом случае рисовать не
по чему.

Опросный слой Windows промежуточных значений не имеет по устройству: он отдаёт
только готовый результат. Чтобы вызывающий не гадал, есть функция:

```lua
if http3.progress_podderzhivaetsya() then ... end
```

Скачанное тело сохраняет в файл сама обёртка — потоковой записи на диск в
нативных слоях нет. Для файлов размером в сотни килобайт это безопасно и даёт
один и тот же код на всех платформах; прогресс при этом не теряется, он идёт
из нативного слоя по мере приёма.

### 3. Отмена выполняющегося запроса (`cancel`)

```lua
local http3 = require("plugin.http3")

local reqId = http3.request("https://httpbin.org/delay/10", "GET", function(event)
    print("Коллбэк вызовется, если запрос не был отменён")
end)

-- Отмена запроса по его идентификатору
local isCancelled = http3.cancel(reqId)
print("Запрос отменён:", isCancelled)
```

### 4. Мониторинг памяти и физических ресурсов (`getMemoryStats`)

```lua
local http3 = require("plugin.http3")

local stats = http3.getMemoryStats()
print("Физическая память процесса (RSS):", stats.nativeRSSMB, "MB")
print("Активных сетевых задач:", stats.activeTasks)
print("Имя нативного стека:", stats.stackName)
```

### 5. Принудительная очистка мусора (`collectGarbage`)

```lua
local http3 = require("plugin.http3")

-- Запуск очистки временных буферов и сбора мусора Lua
http3.collectGarbage()
```

---

## 📁 Структура проекта

```
Solar2D-HTTP3-Plugin/
├── plugins/                        # Наборы файлов для прямого подключения в build.settings
│   ├── win32/                      # Нативный модуль и data.tgz для Windows Desktop
│   ├── win32-sim/                  # Нативный модуль и data.tgz для Windows Simulator
│   ├── android/                    # plugin-release.aar и data.tgz для Android
│   ├── iphone/                     # libplugin_http3_native.a и data.tgz для iOS устройств
│   ├── iphone-sim/                 # libplugin_http3_native.a и data.tgz для iOS Симулятора
│   ├── macOS/                      # plugin_http3_native.dylib и data.tgz для macOS Desktop
│   ├── mac-sim/                    # plugin_http3_native.dylib и data.tgz для macOS Simulator
│   ├── lua/                        # Резервный Lua-модуль и data.tgz
│   └── metadata.lua                # Метаданные платформ Solar2D
├── lua/
│   └── plugin_http3.lua            # Канонический Lua-интерфейс плагина с механизмом Fallback
├── shared/                         # Общие заголовочные и C++ исходники модуля
│   ├── SimulatorPluginLibrary.cpp  # Нативная реализация для Windows (MsQuic + WinHTTP)
│   ├── SimulatorPluginLibrary.mm   # Нативная реализация для Apple (NSURLSession + Network)
│   ├── SimulatorPluginLibrary.h
│   ├── msquic.h
│   └── msquic_winuser.h
├── win32/                          # Проект Visual Studio (Plugin.sln, Plugin.vcxproj, C++ исходники)
├── android/                        # Проект Android Studio и Gradle (нативный слой на Java, без Kotlin)
│   └── plugin/src/main/java/plugin/http3/
│       ├── ntv/LuaLoader.java      # Загрузчик, который ищет Solar2D по имени модуля
│       └── native_stub/LuaLoaderInternal.java  # Реализация на Cronet
├── tools/
│   └── sobrat_arhivy.py            # Пересборка data.tgz платформ из файлов рядом с ним
├── Apple/                          # build.sh (сборка Apple-платформ), deployLocal.sh, Makefile стенда
├── test_app/                       # Универсальное тестовое Solar2D-приложение
│   ├── main.lua                    # Дашборд проверки метрик памяти и пачек из 50 запросов
│   ├── build.settings              # Пример конфигурации
│   └── config.lua
├── .gitignore                      # Исключение временных файлов сборки
└── ReadMe.md                       # Главная документация проекта
```

---

## 🧪 Запуск тестового приложения (`test_app`)

1. Откройте **Solar2D Simulator**.
2. Нажмите **Open Project** и выберите директорию `test_app`.
3. В окне симулятора будут отображаться актуальные графики физической памяти (`Native RSS`), объема памяти Lua Heap и интерактивные кнопки тестирования:
   - **1 Запрос GET**: проверка работы протокола HTTP/3.
   - **Пачка 50 REQ**: стресс-тест 50 параллельных сетевых подключений.
   - **Очистить GC**: принудительный сбор мусора.
   - **Тест Cancel**: проверка отмены сетевой задачи.
