#!/bin/bash -e
# -----------------------------------------------------------------------------
# Apple/build.sh
#
# Собирает Apple-часть плагина Solar2D HTTP/3 из shared/SimulatorPluginLibrary.mm
# и пересобирает архивы платформ plugins/iphone, plugins/iphone-sim,
# plugins/macOS и plugins/mac-sim.
#
# Запускать ТОЛЬКО на macOS с установленным Xcode: под Windows ни одна из этих
# платформ не собирается, и правки в .mm просто не доезжают до архивов. Именно
# так и вышло — в архивах iphone и iphone-sim нативной библиотеки не было вовсе,
# а dylib для macOS отставал от исходника на несколько правок.
#
# Прежняя версия скрипта звала xcodebuild по файлу Apple/Plugin.xcodeproj,
# которого в репозитории нет (он есть только в шаблоне Solar2D Native). Проверка
# `if [ -d ... ]` не срабатывала, компиляция молча пропускалась, а структура
# плагина всё равно раскладывалась — из метаданных и Lua, без единого объектного
# файла. Здесь Xcode как приложение не нужен: clang вызывается напрямую.
#
# Запуск (из любого каталога):
#   Apple/build.sh
#   Apple/build.sh --proverit     # только показать состав архивов
# -----------------------------------------------------------------------------

path=$(cd "$(dirname "$0")"; pwd)
koren=$(cd "$path/.."; pwd)

ISHODNIK="$koren/shared/SimulatorPluginLibrary.mm"
OBERTKA="$koren/lua/plugin_http3.lua"
METADATA="$koren/plugins/metadata.lua"

# Имя библиотеки задано в metadata.lua ключом staticLibs: сборщик iOS передаёт
# его компоновщику как -lplugin_http3_native и ищет рядом lib<имя>.a.
IMYA_LIB=plugin_http3_native

# iOS 12 и macOS 10.14 — нижние границы из metadata.lua.
IOS_MIN=12.0
MAC_MIN=10.14

VKLYUCHENIYA=(
    -I"$path/shared/include/Corona"
    -I"$path/shared/include/lua"
    -I"$koren/shared"
)
# -fvisibility=default обязателен: точки входа luaopen_* должны остаться
# видимыми, иначе компоновщик приложения их не найдёт.
FLAGI=(-fobjc-arc -O2 -std=c++11 -Wall -Wextra -Wno-unused-parameter -fvisibility=default)

PLATFORMY=(iphone iphone-sim macOS mac-sim)

pokazat_sostav() {
    for p in "${PLATFORMY[@]}"; do
        arhiv="$koren/plugins/$p/data.tgz"
        if [ -f "$arhiv" ]; then
            echo "[$p] $(tar -tzf "$arhiv" | tr '\n' ' ')"
        else
            echo "[$p] архива нет"
        fi
    done
}

if [ "$1" == "--proverit" ]; then
    pokazat_sostav
    exit 0
fi

for f in "$ISHODNIK" "$OBERTKA" "$METADATA"; do
    [ -f "$f" ] || { echo "[ОШИБКА] нет $f — собирать не из чего"; exit 1; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=========================================================="
echo "        Сборка Apple-части плагина Solar2D HTTP/3         "
echo "=========================================================="

# --- Компиляция --------------------------------------------------------------
# $1 — SDK, $2 — архитектура, $3 — флаг минимальной версии, $4 — выходной .o
sobrat_obekt() {
    echo " * $1 $2"
    xcrun --sdk "$1" clang -c "$ISHODNIK" -o "$4" \
        -arch "$2" -isysroot "$(xcrun --sdk "$1" --show-sdk-path)" "$3" \
        "${FLAGI[@]}" "${VKLYUCHENIYA[@]}"
}

# iOS-устройство: только arm64. armv7 Xcode больше не поддерживает, а
# minOSVersion 12.0 его и не требует.
sobrat_obekt iphoneos arm64 "-mios-version-min=$IOS_MIN" "$TMP/ios_arm64.o"
xcrun libtool -static -o "$TMP/lib$IMYA_LIB-ios.a" "$TMP/ios_arm64.o"

# Симулятор iOS: arm64 для Apple Silicon и x86_64 для Intel — в одном файле.
sobrat_obekt iphonesimulator arm64  "-mios-simulator-version-min=$IOS_MIN" "$TMP/sim_arm64.o"
sobrat_obekt iphonesimulator x86_64 "-mios-simulator-version-min=$IOS_MIN" "$TMP/sim_x86_64.o"
xcrun libtool -static -o "$TMP/sim_arm64.a"  "$TMP/sim_arm64.o"
xcrun libtool -static -o "$TMP/sim_x86_64.a" "$TMP/sim_x86_64.o"
xcrun lipo -create "$TMP/sim_arm64.a" "$TMP/sim_x86_64.a" -output "$TMP/lib$IMYA_LIB-sim.a"

# macOS: тоже обе архитектуры. Прежний dylib был только arm64, и на Intel-маке
# нативный слой не грузился вовсе — плагин тихо уходил в откат на TCP.
echo " * macosx arm64 x86_64"
xcrun --sdk macosx clang -dynamiclib "$ISHODNIK" -o "$TMP/plugin_http3.dylib" \
    -arch arm64 -arch x86_64 -mmacosx-version-min="$MAC_MIN" \
    -undefined dynamic_lookup -framework Foundation -framework Network \
    "${FLAGI[@]}" "${VKLYUCHENIYA[@]}"

# --- Раскладка и архивы ------------------------------------------------------
# Архив платформы плоский: Solar2D распаковывает его как есть, вложенных
# каталогов не ждёт. Рядом с архивом лежат те же файлы — как у win32 и android.
#
# Прежние Apple-архивы были собраны поверх самих себя: внутри data.tgz лежал
# data.tgz предыдущей сборки, и так несколько слоёв. Здесь архив из состава
# исключён явно.
#
# $1 — платформа, $2 — файл сборки (или пусто), $3 — имя этого файла в архиве.
razlozhit() {
    papka="$koren/plugins/$1"
    mkdir -p "$papka"
    rm -f "$papka"/*.a "$papka"/*.dylib
    cp "$METADATA" "$papka/metadata.lua"
    cp "$OBERTKA"  "$papka/plugin_http3.lua"
    [ -n "$2" ] && cp "$2" "$papka/$3"

    (
        cd "$papka"
        # COPYFILE_DISABLE — иначе tar на macOS добавит ._-спутники ресурсных
        # вилок, и Solar2D распакует их рядом с настоящими файлами.
        COPYFILE_DISABLE=1 tar -czf data.tgz $(ls | grep -v '^data\.tgz$')
    )
    echo " + $1"
}

razlozhit iphone     "$TMP/lib$IMYA_LIB-ios.a"  "lib$IMYA_LIB.a"
razlozhit iphone-sim "$TMP/lib$IMYA_LIB-sim.a"  "lib$IMYA_LIB.a"
razlozhit macOS      "$TMP/plugin_http3.dylib"  "plugin_http3.dylib"
razlozhit mac-sim    "$TMP/plugin_http3.dylib"  "plugin_http3.dylib"

# --- Проверка ----------------------------------------------------------------
# Собранного мало: нужно, чтобы в библиотеке были точки входа, под которыми
# Lua-обёртка ищет нативный модуль.
echo "----------------------------------------------------------"
oshibok=0
for p in iphone iphone-sim; do
    lib="$koren/plugins/$p/lib$IMYA_LIB.a"
    for simvol in _luaopen_plugin_http3_ntv _luaopen_plugin_http3_native; do
        if ! nm -g "$lib" 2>/dev/null | grep -q " T $simvol$"; then
            echo "[$p] НЕТ символа $simvol" >&2
            oshibok=$((oshibok + 1))
        fi
    done
    echo "[$p] $(lipo -info "$lib" | sed 's/.*: //')"
done
for p in macOS mac-sim; do
    echo "[$p] $(lipo -info "$koren/plugins/$p/plugin_http3.dylib" | sed 's/.*: //')"
done
pokazat_sostav
[ "$oshibok" -eq 0 ] || { echo "Сборка неполная: символов не хватает"; exit 1; }
echo "Готово."
