#!/bin/bash -e
# -----------------------------------------------------------------------------
# Apple/deployLocal.sh
# Выкладывает собранный плагин в локальное хранилище Solar2D
# (~/Solar2DPlugins/<издатель>/<плагин>/<платформа>/data.tgz), чтобы Simulator
# и сборка iOS брали рабочую копию, а не сетевой каталог.
#
# Архивы делает Apple/build.sh — этот скрипт их только раскладывает. Раньше он
# собирал состав сам, параллельно build.sh, и своим путём: dylib он клал в
# подкаталог plugin/, нативную библиотеку iOS не собирал вовсе, а метаданные и
# обёртку брал из других мест. Два разных состава для одного плагина — ровно то,
# из-за чего в архивах iphone месяцами не было ни одного объектного файла.
#
# Запуск:
#   Apple/deployLocal.sh [плагин] [издатель]      # по умолчанию plugin.http3 ovh.azi
#   Apple/deployLocal.sh --bez-sborki             # не пересобирать, взять готовые
# -----------------------------------------------------------------------------

path=$(cd "$(dirname "$0")"; pwd)
koren=$(cd "$path/.."; pwd)

SOBRAT=1
if [ "$1" == "--bez-sborki" ]; then SOBRAT=0; shift; fi

PLUGIN="${1:-plugin.http3}"
PUBLISHER="${2:-ovh.azi}"

# Apple-платформы плюс lua: остальные (win32, android) собирает
# tools/sobrat_arhivy.py, и на macOS их выкладывать незачем.
PLATFORMY=(iphone iphone-sim macOS mac-sim lua)

if [ "$SOBRAT" == "1" ]; then
    "$path/build.sh"
fi

TARGET_BASE="$HOME/Solar2DPlugins/$PUBLISHER/$PLUGIN"

# --- Карантин ----------------------------------------------------------------
# macOS метит скачанные файлы атрибутом com.apple.quarantine, а tar переносит
# метку с архива на всё, что из него распаковано. Gatekeeper затем отказывается
# грузить такой dylib: «Apple не удалось подтвердить, что файл не содержит
# вредоносного ПО». В Solar2D это выглядит не ошибкой, а молчаливым откатом на
# network.request — то есть работой по TCP вместо QUIC. Подпись тут ни при чём,
# она ad-hoc и у прежних сборок была такой же; мешает именно метка.
snyat_karantin() {
    xattr -dr com.apple.quarantine "$1" 2>/dev/null || true
}

echo "=========================================================="
echo "    Выкладка плагина в $TARGET_BASE"
echo "=========================================================="

oshibok=0
for p in "${PLATFORMY[@]}"; do
    arhiv="$koren/plugins/$p/data.tgz"
    if [ ! -f "$arhiv" ]; then
        echo " ! $p: нет $arhiv — пропуск" >&2
        oshibok=$((oshibok + 1))
        continue
    fi
    mkdir -p "$TARGET_BASE/$p"
    cp "$arhiv" "$TARGET_BASE/$p/data.tgz"
    snyat_karantin "$TARGET_BASE/$p/data.tgz"
    # Проверяем КОПИЮ, а не исходник: выкладка, рапортующая об успехе вслепую,
    # уже однажды скрыла то, что на месте лежит старый архив.
    echo " + $p: $(tar -tzf "$TARGET_BASE/$p/data.tgz" | tr '\n' ' ')"
done

[ "$oshibok" -eq 0 ] || { echo "Платформ не выложено: $oshibok"; exit 1; }

# --- Каталог плагинов самого Simulator --------------------------------------
# Одного ~/Solar2DPlugins для запуска в Simulator НЕ ХВАТАЕТ: архив оттуда он
# сам не распаковывает — ни при открытии проекта, ни когда data.tgz заведомо
# свежее распакованного. Читает он уже разложенные файлы, вот отсюда. Поэтому
# состав mac-sim кладём сюда сами.
KESH="$HOME/Library/Application Support/Corona/Simulator/Plugins"
if [ -d "$KESH" ]; then
    echo "----------------------------------------------------------"
    # Остатки прежних раскладок. Каждый из них перекрывает свежую сборку, а
    # старая при этом молча врала про протокол — писала HTTP/3 всегда, чем бы
    # запрос ни ушёл на самом деле. Дольше всех держался plugin/http3.dylib:
    # его клала во вложенный каталог прежняя версия ЭТОГО скрипта.
    for musor in "$KESH/plugin/http3.dylib" "$KESH/plugin_http3.dylib"                  "$KESH/libplugin_http3.dylib"; do
        if [ -f "$musor" ]; then
            rm -f "$musor"
            echo " - убран остаток прежней сборки: ${musor#$KESH/}"
        fi
    done
    rmdir "$KESH/plugin" 2>/dev/null

    tar -xzf "$koren/plugins/mac-sim/data.tgz" -C "$KESH"
    # Каталог плагина с архивом внутри — такой же, какой делает сам Solar2D,
    # когда скачивает плагин из сетевого каталога (ср. Plugins/plugin.openssl).
    mkdir -p "$KESH/$PLUGIN"
    cp "$koren/plugins/mac-sim/data.tgz" "$KESH/$PLUGIN/data.tgz"
    snyat_karantin "$KESH"
    echo " + Simulator: $(tar -tzf "$koren/plugins/mac-sim/data.tgz" | tr '\n' ' ')"
else
    echo " ! каталога $KESH нет — Solar2D Simulator не установлен?" >&2
fi

echo "----------------------------------------------------------"
echo "Готово. Плагин зарегистрирован как $PUBLISHER / $PLUGIN."
