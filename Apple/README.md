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
3/
├── shared/
│   ├── SimulatorPluginLibrary.h    # Заголовочный файл C++ экспорта плагина
│   ├── SimulatorPluginLibrary.mm   # Объединённый нативный модуль iOS / macOS (Objective-C++)
│   ├── SimulatorPluginLibrary.cpp  # Нативный модуль Windows (C++ / MsQuic + WinHTTP)
│   ├── msquic.h                    # Заголовки Microsoft QUIC API
│   └── msquic_winuser.h
├── plugin/
│   └── Makefile                    # Makefile для компиляции .dylib / .so под macOS/Linux
├── BuiltPlugin/                    # Результаты компиляции плагина под Solar2D Native
│   ├── iphone/
│   └── iphone-sim/
├── plugin_http3.lua                # Единый гибридный Lua-модуль плагина
├── metadata.lua                    # Файл метаданных платформенной сборки Solar2D
├── build.sh                        # Автоматический скрипт сборки под iOS
├── build.settings                  # Настройки проекта Solar2D
├── config.lua                      # Параметры экрана Solar2D
├── main.lua                        # Интерактивное приложение Solar2D с дашбордом метрик
├── test_runner.lua                 # CLI скрипт для проведения автоматизированного стресс-теста (2500 reqs)
└── README.md                       # Полное руководство на русском языке
```

---

### 🛠 Сборка и деплой плагина:

1. **Локальный деплой в Solar2D Simulator (убирает предупреждения)**:
   При локальной разработке выполните скрипт:
   ```bash
   cd 3
   ./deployLocal.sh
   ```
   Скрипт автоматически соберёт нативную библиотеку `http3.dylib`, упакует платформенные архивы `data.tgz` и зарегистрирует плагин в `~/Solar2DPlugins/ovh.azi/plugin.http3/`.

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
