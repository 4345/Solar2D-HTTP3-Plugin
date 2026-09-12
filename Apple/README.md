# Плагин Solar2D HTTP/3 Protocol (Проект 3)

Проект 3 — это итоговый универсальный плагин сетевого протокола HTTP/3 для Solar2D, объединивший лучшие архитектурные решения из Проекта 1 и Проекта 2.

---

## 🌟 Главные преимущества Объединённого Проекта 3

1. **Полная кроссплатформенность**:
   - **iOS / macOS**: Нативный стек Objective-C++ на базе `NSURLSession` и фреймворка `Network.framework` с установкой `assumesHTTP3Capable = YES`.
   - **Windows (Simulator & Desktop)**: Нативная реализация на C++ под библиотеку **MsQuic (Microsoft QUIC)** и стек `WinHTTP` (без зависимости от C Runtime CRT).
   - **Fallback**: Автоматическое и прозрачное переключение на встроенный стек Solar2D `network.request` при отсутствии нативного слоя.

2. **Производительность и контроль памяти**:
   - Потокобезопасность (`@synchronized` блоки для реестра активных задач).
   - Принудительное управление временными объектами (`@autoreleasepool`).
   - Передача тела ответа в Lua через сырой C-буфер (`malloc` / `free`), полностью исключающая утечки памяти Foundation ARC (`NSString` / `CFString`).

3. **Расширенный функционал API**:
   - `http3.request(url, [method,] listener [, params])` — гибкая обработка различных порядков вызова аргументов.
   - `http3.cancel(requestId)` — возможность отменить выполняющийся запрос.
   - `http3.getMemoryStats()` — получение мгновенных физических метрик процесса (`nativeRSSMB`, `activeTasks`).
   - `http3.collectGarbage()` — двукратный запуск сборщика мусора в защищённом пуле памяти.
   - `http3.pumpEvents(seconds)` — вызов цикла событий для тестирования в CLI.

---

## 📁 Структура Проекта 3

```
Apple/
├── build.sh                        # Сборка Apple-платформ и архивов plugins/<платформа>/data.tgz
├── deployLocal.sh                  # То же + выкладка в ~/Solar2DPlugins
├── metadata.lua                    # Копия plugins/metadata.lua (сборщик читает staticLibs)
├── plugin/
│   ├── Makefile                    # Универсальный http3.dylib для стенда main.lua
│   └── http3.dylib                 # Результат этого Makefile
├── shared/include/                 # Заголовки Corona и Lua для компиляции
├── build.settings                  # Настройки стенда Solar2D
├── config.lua                      # Параметры экрана Solar2D
├── main.lua                        # Интерактивный стенд с дашбордом метрик
├── test_runner.lua                 # CLI-прогон стресс-теста
└── README.md                       # Это руководство
```

Сам нативный исходник лежит не здесь, а в корне репозитория:
`shared/SimulatorPluginLibrary.mm` — он один на iOS и macOS.

---

### 🛠 Сборка и деплой плагина:

1. **Сборка Apple-платформ** (нужен macOS с Xcode — под Windows они не
   собираются вовсе):
   ```bash
   Apple/build.sh                # соберёт iphone, iphone-sim, macOS, mac-sim
   Apple/build.sh --proverit     # только показать состав архивов
   ```
   Скрипт компилирует `shared/SimulatorPluginLibrary.mm` под iOS (arm64),
   симулятор iOS (arm64 + x86_64) и macOS (arm64 + x86_64), раскладывает
   результат по `plugins/<платформа>/`, пересобирает `data.tgz` и проверяет,
   что в библиотеке остались точки входа `luaopen_plugin_http3_ntv` и
   `luaopen_plugin_http3_native`.

   Имя библиотеки в архиве — `libplugin_http3_native.a`, и оно не произвольно:
   сборщик iOS внутри Solar2D читает `metadata.plugin.staticLibs` и передаёт
   компоновщику `-lplugin_http3_native`.

2. **Локальный деплой в Solar2D Simulator (убирает предупреждения)**:
   ```bash
   Apple/deployLocal.sh
   ```
   Соберёт то же самое и зарегистрирует плагин в
   `~/Solar2DPlugins/ovh.azi/plugin.http3/`. Ключ `--bez-sborki` выкладывает
   готовые архивы, ничего не пересобирая.

2. **Использование в проекте Solar2D**:

```lua
local http3 = require("plugin_http3")

-- 1. Выполнение запроса
local reqId = http3.request("https://cloudflare-quic.com", "GET", function(event)
    if event.isError then
        print("Ошибка:", event.error)
    else
        print("Статус:", event.status)
        print("Протокол:", event.protocol) -- HTTP/3 (QUIC / h3)
        print("Ответ:", string.sub(event.response, 1, 100))
    end
end, { timeout = 5 })

-- 2. Отмена запроса при необходимости
-- http3.cancel(reqId)

-- 3. Мониторинг памяти
local stats = http3.getMemoryStats()
print("Физическая память (RSS):", stats.nativeRSSMB, "MB")
```

---

## 🧪 Инфраструктура тестирования

- **Визуальное тестирование (UI)**: Запустите папки `3` в Solar2D Simulator для отображения карточек физической памяти Native RSS и Lua Heap в реальном времени.
- **Консольный стресс-тест на 2500 запросов**: Выполните команду `lua test_runner.lua` для проверки стабильности памяти и скорости параллельных запросов.
