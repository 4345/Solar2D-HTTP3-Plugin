#!/bin/bash -e
# -----------------------------------------------------------------------------
# 3/deployLocal.sh
# Скрипт локальной установки плагина plugin.http3 в директорию ~/Solar2DPlugins
# для устранения предупреждений Solar2D Simulator при локальной разработке.
# -----------------------------------------------------------------------------

PLUGIN="${1:-plugin.http3}"
PUBLISHER="${2:-ovh.azi}"

path=$(cd "$(dirname "$0")"; pwd)

echo "=========================================================="
echo "    Деплой локального плагина в ~/Solar2DPlugins          "
echo "=========================================================="

# 1. Компиляция dylib при необходимости
if [ ! -f "$path/plugin/http3.dylib" ]; then
    make -C "$path/plugin"
fi

# 2. Создание структуры плагина под mac-sim и lua
TARGET_BASE="$HOME/Solar2DPlugins/$PUBLISHER/$PLUGIN"

deploy_platform() {
    PLATFORM=$1
    DEST_DIR="$TARGET_BASE/$PLATFORM"
    TMP_DIR="/tmp/solar2d_http3_deploy_$PLATFORM"

    rm -rf "$DEST_DIR" "$TMP_DIR"
    mkdir -p "$DEST_DIR" "$TMP_DIR"

    # Копирование исходных файлов плагина
    cp "$path/metadata.lua" "$TMP_DIR/"
    cp "$path/../lua/plugin_http3.lua" "$TMP_DIR/"
    
    if [ "$PLATFORM" == "mac-sim" ]; then
        mkdir -p "$TMP_DIR/plugin"
        if [ -f "$path/plugin/http3.dylib" ]; then
            cp "$path/plugin/http3.dylib" "$TMP_DIR/plugin/"
        fi
    fi

    # Архивация в data.tgz для Solar2D Simulator
    (
        cd "$TMP_DIR"
        COPYFILE_DISABLE=1 tar -czvf "$DEST_DIR/data.tgz" -- * &>/dev/null
    )
    rm -rf "$TMP_DIR"
    echo " + Установлена платформа $PLATFORM -> $DEST_DIR/data.tgz"
}

deploy_platform "mac-sim"
deploy_platform "lua"
deploy_platform "iphone"
deploy_platform "iphone-sim"

echo "----------------------------------------------------------"
echo "Локальный деплой завершён."
echo "Плагин зарегистрирован в: $TARGET_BASE"
echo "Solar2D Simulator больше не будет выводить предупреждения."
