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
# Запуск (из корня репозитория плагина):
#   powershell -ExecutionPolicy Bypass -File tools\sobrat_arhivy.ps1
#   ... -Proverit        # только проверить состав, ничего не пересобирая

param(
    [switch]$Proverit
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

        # Собираем ВСЁ, что лежит рядом, кроме самого архива. Пути внутри
        # архива должны быть плоскими — Solar2D распаковывает его как есть.
        $Fayly = Get-ChildItem -Path $Papka -File |
            Where-Object { $_.Name -ne "data.tgz" } |
            ForEach-Object { $_.Name }
        if ($Fayly.Count -eq 0) {
            Write-Host "[$p] рядом с архивом нет файлов — пропуск" -ForegroundColor Yellow
            continue
        }
        Push-Location $Papka
        try {
            & tar -czf "data.tgz" @Fayly
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
