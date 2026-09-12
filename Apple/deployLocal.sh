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
    # Проверяем КОПИЮ, а не исходник: выкладка, рапортующая об успехе вслепую,
    # уже однажды скрыла то, что на месте лежит старый архив.
    echo " + $p: $(tar -tzf "$TARGET_BASE/$p/data.tgz" | tr '\n' ' ')"
done

[ "$oshibok" -eq 0 ] || { echo "Платформ не выложено: $oshibok"; exit 1; }
echo "----------------------------------------------------------"
echo "Готово. Плагин зарегистрирован как $PUBLISHER / $PLUGIN."
