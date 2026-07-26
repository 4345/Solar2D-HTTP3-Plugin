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
| **Android (`android`)** | Kotlin / Java / **Cronet** / **OkHttp3** | JNI Event Dispatcher | Полная поддержка мобильных архитектур (ARM64, x86_64). Оптимизированная передача бинарных данных через Lua Bridge. |
| **Fallback (Универсальный)** | Lua / **`network.request`** | Solar2D Network Loop | Прозрачный автоматический переход на встроенный стек Solar2D `network.request`, если нативная библиотека недоступна на целевом устройстве или сервере. |

### 2. Производительность и контроль памяти

- **Отсутствие задержек (Zero-RTT Connection Setup)**: Ускоренная установка соединения благодаря возможностям TLS 1.3 + QUIC.
- **Устойчивость к потере пакетов**: Отсутствие проблемы Head-of-Line Blocking благодаря раздельной обработке мультиплексированных потоков HTTP/3.
- **Мониторинг физической памяти**: Нативный метод `http3.getMemoryStats()` возвращает реальное объём занимаемой физической памяти (RSS) и количество активных сетевых задач.
- **Принудительное очищение памяти**: Нативный вызов `http3.collectGarbage()` безопасно очищает задействованные пулы памяти и запускает сборщик мусора Lua.

---

## 🛠 Подключение плагина в конфигурации приложений (`build.settings`)

Для подключения плагина в ваших проектах Solar2D укажите прямые ссылки на опубликованные архивы плагина из данного репозитория в файле `build.settings`:

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
│   ├── iphone/                     # Модуль и data.tgz для iOS устройств
│   ├── iphone-sim/                 # Модуль и data.tgz для iOS Симулятора
│   ├── macOS/                      # plugin_http3.dylib и data.tgz для macOS Desktop
│   ├── mac-sim/                    # plugin_http3.dylib и data.tgz для macOS Simulator
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
├── android/                        # Проект Android Studio и Gradle (Kotlin/Java нативный слой)
├── Apple/                          # Скрипты сборки Xcode, Makefile и deployLocal.sh
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
