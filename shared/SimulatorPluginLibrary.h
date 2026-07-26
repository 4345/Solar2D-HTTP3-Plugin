//
//  SimulatorPluginLibrary.h
//  TemplateApp
//
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#ifndef _SimulatorPluginLibrary_H__
#define _SimulatorPluginLibrary_H__

#include <CoronaLua.h>
#include <CoronaMacros.h>

// Точка входа для загрузки нативной библиотеки в Lua
CORONA_EXPORT int luaopen_plugin_http3_native( lua_State *L );

#endif // _SimulatorPluginLibrary_H__
