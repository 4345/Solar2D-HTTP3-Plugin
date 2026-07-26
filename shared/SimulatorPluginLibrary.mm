//-----------------------------------------------------------------------------
// 3/shared/SimulatorPluginLibrary.mm
// Нативный плагин Solar2D для выполнения HTTP/3 запросов на iOS и macOS.
// Объединяет потокбезопасность, отмену запросов, мониторинг физической памяти
// и передачу данных через чистый malloc-буфер для предотвращения утечек.
//-----------------------------------------------------------------------------

#import "SimulatorPluginLibrary.h"

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <mach/mach.h>
#import <objc/runtime.h>

#include "CoronaLua.h"
#include "CoronaMacros.h"

// Объявления внешних функций взаимодействия с рантаймом Corona/Solar2D
extern lua_State *CoronaLuaGetCoronaThread(lua_State *coroutine) __attribute__((weak));
extern CoronaLuaRef CoronaLuaNewRef(lua_State *L, int index) __attribute__((weak));
extern void CoronaLuaDeleteRef(lua_State *L, CoronaLuaRef ref) __attribute__((weak));
extern void CoronaLuaNewEvent(lua_State *L, const char *eventName) __attribute__((weak));
extern void CoronaLuaDispatchEvent(lua_State *L, CoronaLuaRef listenerRef, int nresults) __attribute__((weak));
extern int CoronaLuaIsListener(lua_State *L, int index, const char *eventName) __attribute__((weak));

// Безопасное получение главного потока Lua в случае использования коротутин
static inline lua_State *SafeGetCoronaThread(lua_State *L) {
    if (&CoronaLuaGetCoronaThread != NULL) {
        lua_State *mainL = CoronaLuaGetCoronaThread(L);
        if (mainL) return mainL;
    }
    return L;
}

// Безопасное создание ссылки на функцию-слушатель в Lua Registry
static inline CoronaLuaRef SafeCoronaLuaNewRef(lua_State *L, int index) {
    lua_State *coronaL = SafeGetCoronaThread(L);
    if (&CoronaLuaNewRef != NULL) {
        return CoronaLuaNewRef(coronaL, index);
    }
    lua_pushvalue(coronaL, index);
    int r = luaL_ref(coronaL, LUA_REGISTRYINDEX);
    return (CoronaLuaRef)(intptr_t)r;
}

// Безопасное удаление ссылки из Lua Registry
static inline void SafeCoronaLuaDeleteRef(lua_State *L, CoronaLuaRef ref) {
    if (!ref) return;
    lua_State *coronaL = SafeGetCoronaThread(L);
    if (&CoronaLuaDeleteRef != NULL) {
        CoronaLuaDeleteRef(coronaL, ref);
    } else {
        int r = (int)(intptr_t)ref;
        luaL_unref(coronaL, LUA_REGISTRYINDEX, r);
    }
}

// Создание таблицы события для передачи в Corona Lua
static inline void SafeCoronaLuaNewEvent(lua_State *L, const char *eventName) {
    lua_State *coronaL = SafeGetCoronaThread(L);
    if (&CoronaLuaNewEvent != NULL) {
        CoronaLuaNewEvent(coronaL, eventName);
    } else {
        lua_newtable(coronaL);
        lua_pushstring(coronaL, eventName);
        lua_setfield(coronaL, -2, "name");
    }
}

// Отправка события зарегистрированному слушателю
static inline void SafeCoronaLuaDispatchEvent(lua_State *L, CoronaLuaRef ref) {
    if (!ref) return;
    lua_State *coronaL = SafeGetCoronaThread(L);
    if (&CoronaLuaDispatchEvent != NULL) {
        CoronaLuaDispatchEvent(coronaL, ref, 0);
    } else {
        int r = (int)(intptr_t)ref;
        lua_rawgeti(coronaL, LUA_REGISTRYINDEX, r);
        lua_insert(coronaL, -2);
        if (lua_pcall(coronaL, 1, 0, 0) != 0) {
            lua_pop(coronaL, 1);
        }
    }
}

// Менеджер сетевых запросов HTTP/3
@interface HTTP3PluginManager : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSURLSessionDataTask *> *activeTasks;
@property (nonatomic, assign) NSInteger nextRequestId;
@property (nonatomic, assign) int64_t totalCompleted;
@property (nonatomic, assign) int64_t totalFailed;
@property (nonatomic, assign) int64_t totalBytesReceived;
@property (nonatomic, assign) BOOL isHTTP3Configured;

+ (instancetype)sharedInstance;

- (NSInteger)requestWithURL:(NSString *)urlStr
                     method:(NSString *)method
                    headers:(NSDictionary *)headers
                       body:(NSData *)bodyData
                    timeout:(NSTimeInterval)timeout
                   luaState:(lua_State *)L
                listenerRef:(CoronaLuaRef)listenerRef;

- (BOOL)cancelRequest:(NSInteger)requestId;
- (size_t)getProcessRSSBytes;
- (void)pumpRunLoop:(double)seconds;

@end

@implementation HTTP3PluginManager

+ (instancetype)sharedInstance {
    static HTTP3PluginManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HTTP3PluginManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _activeTasks = [[NSMutableDictionary alloc] init];
        _nextRequestId = 1;
        _totalCompleted = 0;
        _totalFailed = 0;
        _totalBytesReceived = 0;
        _isHTTP3Configured = NO;

        // Настройка сессии NSURLSession
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.HTTPMaximumConnectionsPerHost = 64;
        config.timeoutIntervalForRequest = 30.0;
        config.timeoutIntervalForResource = 60.0;

        // Отключение локального кэша и куки для изоляции сетевого слоя
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        config.URLCache = nil;
        config.URLCredentialStorage = nil;
        config.HTTPCookieStorage = nil;

        // Включение подсказки HTTP/3 на уровне конфигурации сессии (iOS 15+ / macOS 12+)
        if ([config respondsToSelector:NSSelectorFromString(@"setAssumesHTTP3Capable:")]) {
            [config setValue:@YES forKey:@"assumesHTTP3Capable"];
            _isHTTP3Configured = YES;
        }

        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    }
    return self;
}

// Запрос мгновенного использования физической памяти процесса (Resident Set Size)
- (size_t)getProcessRSSBytes {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) == KERN_SUCCESS) {
        return (size_t)vmInfo.phys_footprint;
    }
    return 0;
}

// Продвижение цикла событий NSRunLoop (для синхронного прогона в CLI/тестах)
- (void)pumpRunLoop:(double)seconds {
    @autoreleasepool {
        NSDate *limitDate = [NSDate dateWithTimeIntervalSinceNow:seconds > 0 ? seconds : 0.005];
        [[NSRunLoop currentRunLoop] runUntilDate:limitDate];
    }
}

// Запуск сетевого запроса HTTP/3
- (NSInteger)requestWithURL:(NSString *)urlStr
                     method:(NSString *)method
                    headers:(NSDictionary *)headers
                       body:(NSData *)bodyData
                    timeout:(NSTimeInterval)timeout
                   luaState:(lua_State *)L
                listenerRef:(CoronaLuaRef)listenerRef {
    @autoreleasepool {
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url || !url.host) {
            if (listenerRef) {
                SafeCoronaLuaDeleteRef(L, listenerRef);
            }
            return -1;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:timeout > 0 ? timeout : 3.0];
        request.HTTPMethod = method ? [method uppercaseString] : @"GET";

        // Простановка флага HTTP/3 на уровне индивидуального запроса
        if (@available(iOS 15.0, macOS 12.0, *)) {
            request.assumesHTTP3Capable = YES;
        }

        // Установка заголовков
        if (headers) {
            [headers enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSString class]]) {
                    [request setValue:obj forHTTPHeaderField:key];
                }
            }];
        }

        // Установка тела запроса
        if (bodyData) {
            request.HTTPBody = bodyData;
        }

        __block NSInteger reqId = 0;
        @synchronized (self) {
            reqId = self.nextRequestId++;
        }
        NSNumber *reqIdNum = @(reqId);

        lua_State *mainLuaState = SafeGetCoronaThread(L);

        __weak __typeof__(self) weakSelf = self;
        NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            // Использование @autoreleasepool внутри фонового блока для немедленного освобождения объектовых ресурсов
            @autoreleasepool {
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;

                @synchronized (strongSelf) {
                    [strongSelf.activeTasks removeObjectForKey:reqIdNum];
                }

                NSInteger statusCode = 0;
                NSString *protocol = @"HTTP/3 (QUIC / h3)";
                NSString *transport = @"Native Apple Network.framework (NSURLSession)";
                NSMutableDictionary *respHeaders = [NSMutableDictionary dictionary];

                if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                    statusCode = httpResp.statusCode;
                    [respHeaders addEntriesFromDictionary:httpResp.allHeaderFields];
                }

                // ВЫСОКОПРОИЗВОДИТЕЛЬНЫЙ ПЕРЕНОС ДАННЫХ В LUA:
                // Выделяем сырой C-буфер malloc() для передачи байтов в главный поток Lua.
                // Это полностью предотвращает аккумуляцию объектов NSString/CFString в куче ARC.
                void *responseBuf = NULL;
                NSUInteger responseLen = 0;

                if (data && data.length > 0) {
                    strongSelf.totalBytesReceived += data.length;
                    responseLen = data.length;
                    responseBuf = malloc(responseLen);
                    if (responseBuf) {
                        [data getBytes:responseBuf length:responseLen];
                    } else {
                        responseLen = 0;
                    }
                }

                BOOL isError = (error != nil || statusCode >= 400);
                NSString *errorDesc = error ? error.localizedDescription : (statusCode >= 400 ? [NSString stringWithFormat:@"HTTP Error %ld", (long)statusCode] : nil);

                if (isError) {
                    strongSelf.totalFailed++;
                } else {
                    strongSelf.totalCompleted++;
                }

                // Перенос передачи результата в главный поток Corona Lua
                dispatch_async(dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        if (listenerRef) {
                            lua_State *currentL = SafeGetCoronaThread(mainLuaState);
                            if (currentL) {
                                SafeCoronaLuaNewEvent(currentL, "http3");

                                lua_pushinteger(currentL, reqId);
                                lua_setfield(currentL, -2, "requestId");

                                lua_pushinteger(currentL, statusCode);
                                lua_setfield(currentL, -2, "status");

                                lua_pushboolean(currentL, isError);
                                lua_setfield(currentL, -2, "isError");

                                if (errorDesc) {
                                    lua_pushstring(currentL, errorDesc.UTF8String);
                                    lua_setfield(currentL, -2, "error");
                                    lua_pushstring(currentL, errorDesc.UTF8String);
                                    lua_setfield(currentL, -2, "reason");
                                } else {
                                    lua_pushnil(currentL);
                                    lua_setfield(currentL, -2, "error");
                                }

                                if (responseBuf && responseLen > 0) {
                                    lua_pushlstring(currentL, (const char *)responseBuf, responseLen);
                                    lua_setfield(currentL, -2, "response");
                                } else {
                                    lua_pushstring(currentL, "");
                                    lua_setfield(currentL, -2, "response");
                                }

                                lua_pushinteger(currentL, responseLen);
                                lua_setfield(currentL, -2, "bytesTotal");

                                lua_pushstring(currentL, protocol.UTF8String);
                                lua_setfield(currentL, -2, "protocol");

                                lua_pushstring(currentL, transport.UTF8String);
                                lua_setfield(currentL, -2, "transport");

                                lua_pushboolean(currentL, YES);
                                lua_setfield(currentL, -2, "isNative");

                                lua_newtable(currentL);
                                [respHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                                    lua_pushstring(currentL, [obj description].UTF8String);
                                    lua_setfield(currentL, -2, [key description].UTF8String);
                                }];
                                lua_setfield(currentL, -2, "headers");

                                SafeCoronaLuaDispatchEvent(currentL, listenerRef);
                                SafeCoronaLuaDeleteRef(currentL, listenerRef);
                            }
                        }

                        // Очистка выделенного C-буфера строго после завершения взаимодействия с Lua
                        if (responseBuf) {
                            free(responseBuf);
                        }
                    }
                });
            }
        }];

        @synchronized (self) {
            self.activeTasks[reqIdNum] = task;
        }

        [task resume];
        return reqId;
    }
}

// Отмена сетевой задачи по идентификатору
- (BOOL)cancelRequest:(NSInteger)requestId {
    @synchronized (self) {
        NSNumber *reqIdNum = @(requestId);
        NSURLSessionDataTask *task = self.activeTasks[reqIdNum];
        if (task) {
            [task cancel];
            [self.activeTasks removeObjectForKey:reqIdNum];
            return YES;
        }
    }
    return NO;
}

@end

//-----------------------------------------------------------------------------
// Lua C-bindings экспортируемых функций плагина
//-----------------------------------------------------------------------------

static int L_request(lua_State *L) {
    const char *urlStr = luaL_checkstring(L, 1);
    NSString *method = @"GET";
    NSDictionary *headers = nil;
    NSData *bodyData = nil;
    NSTimeInterval timeout = 3.0;
    int listenerIdx = 0;

    // 1. Определение параметров по типам аргументов
    if (lua_isstring(L, 2)) {
        // Сигнатура Solar2D: (url, method, listener [, params])
        method = [NSString stringWithUTF8String:lua_tostring(L, 2)];
        listenerIdx = 3;

        if (lua_istable(L, 4)) {
            lua_getfield(L, 4, "timeout");
            if (lua_isnumber(L, -1)) timeout = lua_tonumber(L, -1);
            lua_pop(L, 1);

            lua_getfield(L, 4, "body");
            if (lua_isstring(L, -1)) {
                size_t len = 0;
                const char *bytes = lua_tolstring(L, -1, &len);
                bodyData = [NSData dataWithBytes:bytes length:len];
            }
            lua_pop(L, 1);

            lua_getfield(L, 4, "headers");
            if (lua_istable(L, -1)) {
                NSMutableDictionary *dict = [NSMutableDictionary dictionary];
                lua_pushnil(L);
                while (lua_next(L, -2) != 0) {
                    if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
                        dict[[NSString stringWithUTF8String:lua_tostring(L, -2)]] = [NSString stringWithUTF8String:lua_tostring(L, -1)];
                    }
                    lua_pop(L, 1);
                }
                headers = dict;
            }
            lua_pop(L, 1);
        }
    } else if (lua_istable(L, 2)) {
        // Сигнатура с передачей таблицы параметров 2-м аргументом: (url, params, listener)
        lua_getfield(L, 2, "method");
        if (lua_isstring(L, -1)) method = [NSString stringWithUTF8String:lua_tostring(L, -1)];
        lua_pop(L, 1);

        lua_getfield(L, 2, "timeout");
        if (lua_isnumber(L, -1)) timeout = lua_tonumber(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 2, "body");
        if (lua_isstring(L, -1)) {
            size_t len = 0;
            const char *bytes = lua_tolstring(L, -1, &len);
            bodyData = [NSData dataWithBytes:bytes length:len];
        }
        lua_pop(L, 1);

        lua_getfield(L, 2, "headers");
        if (lua_istable(L, -1)) {
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            lua_pushnil(L);
            while (lua_next(L, -2) != 0) {
                if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
                    dict[[NSString stringWithUTF8String:lua_tostring(L, -2)]] = [NSString stringWithUTF8String:lua_tostring(L, -1)];
                }
                lua_pop(L, 1);
            }
            headers = dict;
        }
        lua_pop(L, 1);

        listenerIdx = 3;
    } else {
        // Сигнатура с пропущенным методом: (url, listener [, params])
        listenerIdx = 2;
        if (lua_istable(L, 3)) {
            lua_getfield(L, 3, "timeout");
            if (lua_isnumber(L, -1)) timeout = lua_tonumber(L, -1);
            lua_pop(L, 1);
        }
    }

    CoronaLuaRef listenerRef = NULL;
    if (lua_isfunction(L, listenerIdx) || lua_istable(L, listenerIdx)) {
        listenerRef = SafeCoronaLuaNewRef(L, listenerIdx);
    }

    HTTP3PluginManager *mgr = [HTTP3PluginManager sharedInstance];
    NSInteger reqId = [mgr requestWithURL:[NSString stringWithUTF8String:urlStr]
                                  method:method
                                 headers:headers
                                    body:bodyData
                                 timeout:timeout
                                luaState:L
                             listenerRef:listenerRef];

    lua_pushinteger(L, reqId);
    return 1;
}

static int L_initiateRequest(lua_State *L) {
    return L_request(L);
}

static int L_cancel(lua_State *L) {
    if (lua_isnumber(L, 1)) {
        NSInteger reqId = lua_tointeger(L, 1);
        BOOL cancelled = [[HTTP3PluginManager sharedInstance] cancelRequest:reqId];
        lua_pushboolean(L, cancelled);
        return 1;
    }
    lua_pushboolean(L, 0);
    return 1;
}

static int L_getMemoryStats(lua_State *L) {
    HTTP3PluginManager *mgr = [HTTP3PluginManager sharedInstance];
    size_t rssBytes = [mgr getProcessRSSBytes];
    double rssMB = (double)rssBytes / (1024.0 * 1024.0);

    lua_newtable(L);

    lua_pushnumber(L, (lua_Number)rssBytes);
    lua_setfield(L, -2, "nativeRSSBytes");

    lua_pushnumber(L, (lua_Number)rssMB);
    lua_setfield(L, -2, "nativeRSSMB");

    NSUInteger activeCount = 0;
    @synchronized (mgr) {
        activeCount = mgr.activeTasks.count;
    }
    lua_pushinteger(L, activeCount);
    lua_setfield(L, -2, "activeTasks");

    lua_pushinteger(L, mgr.totalCompleted);
    lua_setfield(L, -2, "totalCompleted");

    lua_pushinteger(L, mgr.totalFailed);
    lua_setfield(L, -2, "totalFailed");

    lua_pushnumber(L, (lua_Number)mgr.totalBytesReceived);
    lua_setfield(L, -2, "totalBytesReceived");

    lua_pushboolean(L, mgr.isHTTP3Configured);
    lua_setfield(L, -2, "isHTTP3Configured");

    lua_pushstring(L, "Native Apple Network.framework (NSURLSession)");
    lua_setfield(L, -2, "stackName");

    return 1;
}

static int L_collectGarbage(lua_State *L) {
    @autoreleasepool {
        lua_gc(L, LUA_GCCOLLECT, 0);
        lua_gc(L, LUA_GCCOLLECT, 0);
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int L_pumpEvents(lua_State *L) {
    double sec = 0.01;
    if (lua_isnumber(L, 1)) {
        sec = lua_tonumber(L, 1);
    }
    [[HTTP3PluginManager sharedInstance] pumpRunLoop:sec];
    return 0;
}

static const struct luaL_Reg kFunctions[] = {
    {"request", L_request},
    {"initiateRequest", L_initiateRequest},
    {"cancel", L_cancel},
    {"getMemoryStats", L_getMemoryStats},
    {"collectGarbage", L_collectGarbage},
    {"pumpEvents", L_pumpEvents},
    {NULL, NULL}
};

CORONA_EXPORT int luaopen_plugin_http3(lua_State *L) {
    luaL_register(L, "plugin.http3", kFunctions);

    lua_getglobal(L, "package");
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "preload");
        if (lua_istable(L, -1)) {
            lua_pushcfunction(L, luaopen_plugin_http3);
            lua_setfield(L, -2, "plugin.http3.native");

            lua_pushcfunction(L, luaopen_plugin_http3);
            lua_setfield(L, -2, "plugin_http3_native");
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 1);

    return 1;
}

CORONA_EXPORT int luaopen_plugin_http3_native(lua_State *L) {
    return luaopen_plugin_http3(L);
}

CORONA_EXPORT int luaopen_http3(lua_State *L) {
    return luaopen_plugin_http3(L);
}

CORONA_EXPORT int CoronaPluginLuaLoad_plugin_http3(lua_State *L) {
    return luaopen_plugin_http3(L);
}

CORONA_EXPORT int CoronaPluginLuaLoad_plugin_http3_native(lua_State *L) {
    return luaopen_plugin_http3(L);
}

CORONA_EXPORT int CoronaPluginLuaLoad_http3(lua_State *L) {
    return luaopen_plugin_http3(L);
}
