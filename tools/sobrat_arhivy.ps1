# sobrat_arhivy.ps1
#
# Пересобирает data.tgz платформ из файлов, лежащих рядом с ним в plugins\<платформа>\.
# Solar2D берёт при сборке ИМЕННО архив, а не файлы рядом, — и рассинхрон между
# ними уже стоил рабочего HTTP/3: в архивах win32, win32-sim и android не было
# Lua-обёртки plugin_http3.lua, приложение молча оставалось на TCP.
#
# Обёртка обязательна КАЖДОЙ платформе: модуль плагина называется plugin.http3,
# и это именно она. Нативная библиотека объявляет plugin.http3.ntv (и
# plugin.http3.native), а plugin.http3 не объявляет вовсе — одной её для
# require мало. Скрипт подкладывает обёртку сам, из lua\plugin_http3.lua.
#
# Apple-платформы (iphone, iphone-sim, macOS, mac-sim) здесь НЕ собираются: их
# архив устроен иначе (внутри вложенный data.tgz и metadata.lua) и делается
# своим скриптом — Apple\deployLocal.sh.
#
# Android вдобавок несёт нативную библиотеку plugin-release.aar. Она собирается
# из Java (android\plugin\src) через Gradle, и её тоже надо обновлять: правка в
# Java, не дошедшая до архива, просто не попадёт на устройство. Скрипт сам
# запускает сборку, если исходники новее архива.
#
# Запуск (из корня репозитория плагина):
#   powershell -ExecutionPolicy Bypass -File tools\sobrat_arhivy.ps1
#   ... -Proverit        # только проверить состав, ничего не пересобирая
#   ... -BezGradle       # не трогать AAR, взять какой лежит

param(
    [switch]$Proverit,
    [switch]$BezGradle
)

$ErrorActionPreference = "Stop"

$Koren = Split-Path -Parent $PSScriptRoot
$Obertka = Join-Path $Koren "lua\plugin_http3.lua"
# Платформы, чей архив собирается из файлов рядом. Apple — см. коммент выше.
$Platformy = @("win32", "win32-sim", "android", "lua")

if (-not (Test-Path $Obertka)) {
    Write-Host "[ОШИБКА] нет $Obertka — собирать не из чего" -ForegroundColor Red
    exit 1
}

$Oshibok = 0

# --- Нативная библиотека Android -------------------------------------------
# Собирает AAR, если Java новее того, что лежит в plugins\android, и кладёт
# свежий рядом с архивом. Не находим JDK или Gradle падает — ГРОМКО пишем и
# идём дальше: у стороннего человека с публичным репозиторием может не быть
# Android-окружения вовсе, и Lua-часть собрать он всё равно должен.
function Obnovit-Aar {
    $Ishodniki = Join-Path $Koren "android\plugin\src"
    $Gotovyy = Join-Path $Koren "plugins\android\plugin-release.aar"
    if (-not (Test-Path $Ishodniki)) { return }

    $Svezhest = (Get-ChildItem $Ishodniki -Recurse -File |
        Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum
    if ((Test-Path $Gotovyy) -and
        $Svezhest -le (Get-Item $Gotovyy).LastWriteTimeUtc) {
        Write-Host "[android] AAR свежий, Gradle не нужен"
        return
    }

    # JAVA_HOME у Android Studio лежит в jbr; своего JDK в системе может не
    # быть вовсе, и без подсказки Gradle не стартует.
    if (-not $env:JAVA_HOME) {
        foreach ($k in @("C:\Program Files\Android\Android Studio\jbr",
                         "C:\Program Files\Android\Android Studio\jre")) {
            if (Test-Path $k) { $env:JAVA_HOME = $k; break }
        }
    }
    if (-not $env:JAVA_HOME) {
        Write-Host "[android] JDK не найден — AAR остаётся прежним, правки в Java НЕ доедут" -ForegroundColor Red
        $script:Oshibok++
        return
    }

    Push-Location (Join-Path $Koren "android")
    try {
        & .\gradlew.bat :plugin:assembleRelease --console=plain -q
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[android] Gradle вернул $LASTEXITCODE — AAR остаётся прежним" -ForegroundColor Red
            $script:Oshibok++
            return
        }
    } finally { Pop-Location }

    $Sobrannyy = Join-Path $Koren "android\plugin\build\outputs\aar\plugin-release.aar"
    if (-not (Test-Path $Sobrannyy)) {
        Write-Host "[android] Gradle отработал, но AAR не найден: $Sobrannyy" -ForegroundColor Red
        $script:Oshibok++
        return
    }
    Copy-Item $Sobrannyy $Gotovyy -Force
    Write-Host "[android] AAR пересобран из Java"
}

if (-not $Proverit -and -not $BezGradle) { Obnovit-Aar }

foreach ($p in $Platformy) {
    $Papka = Join-Path $Koren "plugins\$p"
    if (-not (Test-Path $Papka)) {
        Write-Host "[$p] каталога нет — пропуск" -ForegroundColor Yellow
        continue
    }
    $Arhiv = Join-Path $Papka "data.tgz"

    if (-not $Proverit) {
        # Обёртка должна лежать рядом — тогда она попадёт и в архив.
        $Svoya = Join-Path $Papka "plugin_http3.lua"
        if (-not (Test-Path $Svoya) -or
            (Get-FileHash $Svoya).Hash -ne (Get-FileHash $Obertka).Hash) {
            Copy-Item $Obertka $Svoya -Force
            Write-Host "[$p] обёртка обновлена из lua\plugin_http3.lua"
        }

        # Собираем то, что лежит рядом, кроме самого архива. Пути внутри
        # архива должны быть плоскими — Solar2D распаковывает его как есть.
        #
        # ТОЛЬКО ОТСЛЕЖИВАЕМОЕ GIT. Прежде паковалось всё подряд, и в win32-архив
        # уехал msquic.dll, лежавший рядом от сборки стенда: в репозитории его
        # нет, у другого человека архив собрался бы иным, а опубликованный
        # отличался бы от исходников молча. Не репозиторий или git не ответил —
        # откатываемся на прежнее поведение и ГОВОРИМ об этом.
        $Fayly = $null
        try {
            $Spisok = & git -C $Papka ls-files 2>$null
            if ($LASTEXITCODE -eq 0 -and $Spisok) {
                # Имена приходят относительно $Papka; вложенные каталоги
                # (с "/") архиву не нужны — он плоский.
                $Fayly = @($Spisok | Where-Object {
                    $_ -and ($_ -notmatch "/") -and ($_ -ne "data.tgz")
                })
            }
        } catch { }
        if ($null -eq $Fayly) {
            Write-Host "[$p] git не ответил — пакую всё, что лежит рядом" -ForegroundColor Yellow
            $Fayly = @(Get-ChildItem -Path $Papka -File |
                Where-Object { $_.Name -ne "data.tgz" } |
                ForEach-Object { $_.Name })
        }
        if ($Fayly.Count -eq 0) {
            Write-Host "[$p] рядом с архивом нет файлов — пропуск" -ForegroundColor Yellow
            continue
        }
        Push-Location $Papka
        try {
            # Массив передаём КАК ЕСТЬ: @ перед именем — это splatting для
            # командлетов, а внешний tar от него получал мусор из окружения
            # («Couldn't visit directory: am Files\Intel\WiFi…»).
            & tar -czf "data.tgz" $Fayly
            if ($LASTEXITCODE -ne 0) { throw "tar вернул $LASTEXITCODE" }
        } finally { Pop-Location }
    }

    # Проверка состава — и после сборки, и в режиме -Proverit.
    $Sostav = & tar -tzf $Arhiv
    $EstObertka = $Sostav -contains "plugin_http3.lua"
    $Znak = if ($EstObertka) { "OK " } else { "НЕТ" }
    $Cvet = if ($EstObertka) { "Green" } else { "Red" }
    Write-Host ("[$p] $Znak обёртка; в архиве: " + ($Sostav -join ", ")) -ForegroundColor $Cvet
    if (-not $EstObertka) { $Oshibok++ }
}

# Apple-архивы только проверяем: собираются они отдельно, но обёртка обязана
# быть и в них — иначе require("plugin.http3") не найдёт модуль и там.
foreach ($p in @("iphone", "iphone-sim", "macOS", "mac-sim")) {
    $Arhiv = Join-Path $Koren "plugins\$p\data.tgz"
    if (-not (Test-Path $Arhiv)) { continue }
    $Sostav = & tar -tzf $Arhiv
    if ($Sostav -contains "plugin_http3.lua") {
        Write-Host "[$p] OK  обёртка (архив собирается Apple\deployLocal.sh)" -ForegroundColor Green
    } else {
        Write-Host "[$p] НЕТ обёртки — пересоберите Apple\deployLocal.sh" -ForegroundColor Red
        $Oshibok++
    }
}

if ($Oshibok -gt 0) {
    Write-Host "Платформ без обёртки: $Oshibok" -ForegroundColor Red
    exit 1
}
Write-Host "Все архивы несут Lua-обёртку." -ForegroundColor Green
