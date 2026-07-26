//-----------------------------------------------------------------------------
// 3/shared/SimulatorPluginLibrary.h
// Заголовочный файл точек входа нативного плагина plugin.http3 для Solar2D.
// Поддерживает компиляцию под iOS, macOS и Windows.
//-----------------------------------------------------------------------------

#ifndef _SimulatorPluginLibrary_H__
#define _SimulatorPluginLibrary_H__

#include <CoronaLua.h>
#include <CoronaMacros.h>

#ifdef __cplusplus
extern "C" {
#endif

// Основная точка входа экспорта функции загрузки плагина в Lua
CORONA_EXPORT int luaopen_plugin_http3_native( lua_State *L );
CORONA_EXPORT int luaopen_plugin_http3( lua_State *L );
CORONA_EXPORT int luaopen_http3( lua_State *L );

#ifdef __cplusplus
}
#endif

#endif // _SimulatorPluginLibrary_H__
