# -----------------------------------------------------------------------------
# 3/plugin/Makefile
# Makefile для компиляции динамических библиотек plugin/http3.dylib / .so
# -----------------------------------------------------------------------------

CC = clang
CFLAGS = -O3 -Wall -fPIC -fobjc-arc
INCLUDES = -I../../shared -I../shared/include -I../shared/include/Corona -I../shared/include/lua -I/usr/local/include

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
    TARGET = http3.dylib
    LDFLAGS = -dynamiclib -undefined dynamic_lookup -framework Foundation -framework Network
else
    TARGET = http3.so
    LDFLAGS = -shared
endif

all: $(TARGET)

$(TARGET): ../../shared/SimulatorPluginLibrary.mm
	$(CC) $(CFLAGS) $(INCLUDES) -objc++ -std=c++11 $(LDFLAGS) $< -o $@

clean:
	rm -f *.dylib *.so *.o
