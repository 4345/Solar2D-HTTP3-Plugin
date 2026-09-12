# -----------------------------------------------------------------------------
# Apple/plugin/Makefile
# Собирает http3.dylib для локального прогона стенда Apple/main.lua в Solar2D
# Simulator. Архивы платформ этим файлом НЕ собираются — их делает
# Apple/build.sh, и именно он идёт в репозиторий.
# -----------------------------------------------------------------------------

CC = clang
# Обе архитектуры: на Intel-маке arm64-библиотека не грузится вовсе, и стенд
# молча уходит в откат на network.request.
ARCHS = -arch arm64 -arch x86_64
CFLAGS = -O2 -Wall -Wextra -Wno-unused-parameter -fPIC -fobjc-arc -fvisibility=default
INCLUDES = -I../../shared -I../shared/include/Corona -I../shared/include/lua

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
    TARGET = http3.dylib
    LDFLAGS = -dynamiclib -undefined dynamic_lookup -framework Foundation -framework Network -mmacosx-version-min=10.14
else
    TARGET = http3.so
    LDFLAGS = -shared
    ARCHS =
endif

all: $(TARGET)

$(TARGET): ../../shared/SimulatorPluginLibrary.mm
	$(CC) $(ARCHS) $(CFLAGS) $(INCLUDES) -objc++ -std=c++11 $(LDFLAGS) $< -o $@
	cp $@ ../plugin_http3.dylib

clean:
	rm -f *.dylib *.so *.o
