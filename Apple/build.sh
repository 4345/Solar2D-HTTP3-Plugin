#!/bin/bash -e
# -----------------------------------------------------------------------------
# 3/build.sh
# Скрипт сборки плагина Solar2D HTTP/3 под iOS устройство и симулятор
# -----------------------------------------------------------------------------

path=$(cd "$(dirname "$0")"; pwd)

TARGET_NAME=plugin_http3_native
BUILD_TARGET_NAME=plugin_library
OUTPUT_SUFFIX=a
CONFIG=Release

echo "=========================================================="
echo "          Сборка плагина Solar2D HTTP/3 (Проект 3)        "
echo "=========================================================="

# Очистка старых результатов
rm -rf "$path/BuiltPlugin" "$path/build"

# Сборка через Xcode если присутствует файл проекта
if [ -d "$path/Plugin.xcodeproj" ]; then
    xcodebuild -project "$path/Plugin.xcodeproj" -configuration $CONFIG clean
    xcodebuild -project "$path/Plugin.xcodeproj" -configuration $CONFIG -sdk iphoneos
    xcodebuild -project "$path/Plugin.xcodeproj" -configuration $CONFIG -sdk iphonesimulator
fi

# Формирование структуры плагина
build_plugin_structure() {
    PLUGIN_DEST=$1
    PLATFORM=$2
    
    mkdir -p "$PLUGIN_DEST"
    
    if [ -f "$path/build/$CONFIG-$PLATFORM/lib$BUILD_TARGET_NAME.$OUTPUT_SUFFIX" ]; then
        cp "$path/build/$CONFIG-$PLATFORM/lib$BUILD_TARGET_NAME.$OUTPUT_SUFFIX" "$PLUGIN_DEST/lib$TARGET_NAME.$OUTPUT_SUFFIX"
    fi
    
    cp "$path/metadata.lua" "$PLUGIN_DEST/"
    cp "$path/plugin_http3.lua" "$PLUGIN_DEST/"
}

build_plugin_structure "$path/BuiltPlugin/iphone" iphoneos
build_plugin_structure "$path/BuiltPlugin/iphone-sim" iphonesimulator

echo "Сборка завершена. Результаты сохранены в $path/BuiltPlugin"
