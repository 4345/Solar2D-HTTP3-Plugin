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

// Не чаще этого шлём события хода передачи. Порции приходят часто, и на
// быстрой сети их десятки в секунду; каждое событие — задача в очередь
// Lua-потока, а перерисовывать индикатор чаще двух раз в секунду глазу всё
// равно нечего. Последнее значение доезжает с фазой "ended", так что на
// точности итога порог не сказывается. Порог тот же, что у Android.
static const NSTimeInterval kProgressPauza = 0.5;

// Контекст одной задачи. Появился вместе с прогрессом: обработчик-блок
// (completionHandler) вызывается ОДИН раз, готовым ответом, и промежуточных
// событий из него не достать — NSURLSession не зовёт didReceiveData, когда
// задаче дан блок. Поэтому тело собирается делегатом, а всё, что делегату
// нужно знать о запросе, живёт здесь.
@interface HTTP3Zadacha : NSObject
@property (nonatomic, assign) NSInteger reqId;
@property (nonatomic, assign) CoronaLuaRef listenerRef;
@property (nonatomic, assign) lua_State *mainLuaState;
@property (nonatomic, strong) NSMutableData *telo;
// -1 означает «сервер не сказал, сколько всего» — ровно так же ведёт себя
// Solar2D, когда в ответе нет Content-Length. Полосу в этом случае рисовать
// не по чему, и вызывающий должен показывать неопределённое ожидание.
@property (nonatomic, assign) long long ozhidaetsyaPriyoma;
@property (nonatomic, assign) BOOL progressPriyoma;
@property (nonatomic, assign) BOOL progressOtpravki;
@property (nonatomic, assign) BOOL nachaloPriyoma;
@property (nonatomic, assign) BOOL nachaloOtpravki;
// Отсчёт троттлинга у каждого направления свой. С одним общим полем при
// progress = true (оба направления) отправка и приём отнимали окно друг у
// друга: событие одного направления сдвигало порог другому. На Android они
// тоже независимы — там счётчик отправки живёт в самом UploadDataProvider.
@property (nonatomic, assign) NSTimeInterval posledneePriyoma;
@property (nonatomic, assign) NSTimeInterval posledneeOtpravki;
@end

@implementation HTTP3Zadacha
- (instancetype)init {
    self = [super init];
    if (self) {
        _telo = [NSMutableData data];
        _ozhidaetsyaPriyoma = -1;
        _posledneePriyoma = 0;
        _posledneeOtpravki = 0;
    }
    return self;
}
@end

// Менеджер сетевых запросов HTTP/3
@interface HTTP3PluginManager : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSURLSessionDataTask *> *activeTasks;
// Согласованный протокол по идентификатору задачи. Заполняется в
// URLSession:task:didFinishCollectingMetrics: — единственном месте, где
// NSURLSession сообщает, ЧТО он на самом деле использовал.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *protokolZadachi;
// Контексты задач по taskIdentifier: делегат получает только задачу, а ему
// нужны и слушатель, и накопленное тело, и флаги прогресса.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, HTTP3Zadacha *> *zadachi;
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
            progressOtpravki:(BOOL)progressOtpravki
             progressPriyoma:(BOOL)progressPriyoma
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
        _protokolZadachi = [[NSMutableDictionary alloc] init];
        _zadachi = [[NSMutableDictionary alloc] init];
        _nextRequestId = 1;
        _totalCompleted = 0;
        _totalFailed = 0;
        _totalBytesReceived = 0;
        _isHTTP3Configured = NO;

        // Настройка сессии NSURLSession
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.HTTPMaximumConnectionsPerHost = 64;
        // Сколько ждать ОЧЕРЕДНЫХ данных. Значение перекрывается на каждом
        // запросе из params.timeout (см. requestWithURL ниже), здесь оно
        // остаётся только запасным.
        config.timeoutIntervalForRequest = 30.0;

        // Потолок на ВСЮ передачу. Здесь стояли 60 секунд, и это был предел на
        // размер передаваемого: всё, что не укладывалось в минуту, обрывалось
        // на середине с «The request timed out» — независимо от того, сколько
        // просил вызывающий и шли ли данные ровно, без единого простоя.
        // Замер: запрос с timeout = 300 к источнику, отдающему ровно 90 секунд,
        // обрывался на 60-й, приняв 491 520 байт из 737 280.
        //
        // Задать его на отдельный запрос нельзя — свойство сессии, и сессия
        // одна на все запросы. Поэтому потолка здесь нет вовсе (7 суток —
        // значение Apple по умолчанию), а от зависшей передачи защищает
        // timeoutIntervalForRequest: он считает простой, а не общее время.
        // Так же ведут себя и остальные платформы: на Android запрос отменяет
        // таймер по timeout вызывающего, на Windows по нему же идёт ожидание,
        // и ни там, ни там скрытой минуты нет.
        config.timeoutIntervalForResource = 604800.0;

        // Отключение локального кэша и куки для изоляции сетевого слоя
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        config.URLCache = nil;
        config.URLCredentialStorage = nil;
        config.HTTPCookieStorage = nil;

        // Свойство assumesHTTP3Capable принадлежит ЗАПРОСУ, а не конфигурации
        // сессии. Здесь стояла попытка выставить его на конфигурации по строке
        // через KVC: проверка respondsToSelector не проходила, блок не
        // выполнялся, и _isHTTP3Configured навсегда оставался NO — при том что
        // HTTP/3 работал. Отчёт getMemoryStats попросту врал.
        // Настоящую работу делает установка свойства на каждом запросе, см.
        // requestWithURL ниже; флаг отражает именно её доступность.
        if (@available(iOS 15.0, macOS 12.0, *)) {
            _isHTTP3Configured = YES;
        }

        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    }
    return self;
}

// Метрики задачи: отсюда берётся ИМЯ СОГЛАСОВАННОГО ПРОТОКОЛА. Раньше плагин
// его не спрашивал вовсе и всегда сообщал в событие строку HTTP/3 — независимо
// от того, что реально было на проводе. Диагностическая ценность такого поля
// нулевая, а вред прямой: точно такую же поломку, какую на Windows нашли по
// полю transport (все POST месяцами уходили по HTTP/1.1), на iOS не увидели бы
// вовсе. Вызывается до обработчика завершения, в том числе для задач с
// completionHandler.
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics {
    NSString *imya = metrics.transactionMetrics.lastObject.networkProtocolName;
    if (imya.length > 0) {
        @synchronized (self) {
            self.protokolZadachi[@(task.taskIdentifier)] = imya;
        }
    }
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

// Одно событие хода передачи в Lua. Поля те же, что у network.request Solar2D:
// phase ("began" / "progress"), bytesTransferred, bytesEstimated. Ссылку на
// слушателя НЕ отпускаем — запрос ещё идёт, событий будет много, и освободит
// её завершение.
static void OtpravitProgress(HTTP3Zadacha *z, NSString *faza,
                             long long peredano, long long ozhidaetsya) {
    if (!z || !z.listenerRef) return;
    CoronaLuaRef ref = z.listenerRef;
    lua_State *mainL = z.mainLuaState;
    NSInteger reqId = z.reqId;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            lua_State *L = SafeGetCoronaThread(mainL);
            if (!L) return;
            SafeCoronaLuaNewEvent(L, "http3");

            lua_pushinteger(L, reqId);
            lua_setfield(L, -2, "requestId");

            lua_pushstring(L, faza.UTF8String);
            lua_setfield(L, -2, "phase");

            lua_pushboolean(L, 0);
            lua_setfield(L, -2, "isError");

            lua_pushnumber(L, (lua_Number)peredano);
            lua_setfield(L, -2, "bytesTransferred");

            lua_pushnumber(L, (lua_Number)ozhidaetsya);
            lua_setfield(L, -2, "bytesEstimated");

            lua_pushboolean(L, 1);
            lua_setfield(L, -2, "isNative");

            SafeCoronaLuaDispatchEvent(L, ref);
        }
    });
}

// Запуск сетевого запроса HTTP/3
- (NSInteger)requestWithURL:(NSString *)urlStr
                     method:(NSString *)method
                    headers:(NSDictionary *)headers
                       body:(NSData *)bodyData
                    timeout:(NSTimeInterval)timeout
            progressOtpravki:(BOOL)progressOtpravki
             progressPriyoma:(BOOL)progressPriyoma
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

        NSInteger reqId = 0;
        @synchronized (self) {
            reqId = self.nextRequestId++;
        }
        NSNumber *reqIdNum = @(reqId);

        // Задача БЕЗ обработчика-блока: с ним NSURLSession не зовёт
        // didReceiveData, и промежуточных событий приёма не будет вовсе.
        NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];

        HTTP3Zadacha *z = [[HTTP3Zadacha alloc] init];
        z.reqId = reqId;
        z.listenerRef = listenerRef;
        z.mainLuaState = SafeGetCoronaThread(L);
        z.progressOtpravki = progressOtpravki;
        z.progressPriyoma = progressPriyoma;

        @synchronized (self) {
            self.activeTasks[reqIdNum] = task;
            self.zadachi[@(task.taskIdentifier)] = z;
        }

        [task resume];
        return reqId;
    }
}

// --- Делегат: ход приёма ----------------------------------------------------

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    HTTP3Zadacha *z = nil;
    @synchronized (self) { z = self.zadachi[@(dataTask.taskIdentifier)]; }
    if (z) {
        // expectedContentLength сам отдаёт -1 (NSURLResponseUnknownLength),
        // когда Content-Length в ответе нет, — то же значение, что и у
        // Android, менять его не на что.
        z.ozhidaetsyaPriyoma = response.expectedContentLength;
        if (z.progressPriyoma && !z.nachaloPriyoma) {
            // "began" перед первой порцией: у network.request Solar2D передача
            // начинается именно этой фазой, и вызывающий по ней ставит
            // индикатор в ноль, а не додумывает начало по первому "progress".
            z.nachaloPriyoma = YES;
            OtpravitProgress(z, @"began", 0, z.ozhidaetsyaPriyoma);
        }
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    HTTP3Zadacha *z = nil;
    @synchronized (self) { z = self.zadachi[@(dataTask.taskIdentifier)]; }
    if (!z) return;

    [z.telo appendData:data];

    if (!z.progressPriyoma) return;
    if (!z.nachaloPriyoma) {
        // Ответа без заголовков не бывает, но если didReceiveResponse почему-то
        // не пришёл, начало всё равно надо объявить — иначе вызывающий увидит
        // "progress" без "began".
        z.nachaloPriyoma = YES;
        OtpravitProgress(z, @"began", 0, z.ozhidaetsyaPriyoma);
    }
    NSTimeInterval teper = [NSDate timeIntervalSinceReferenceDate];
    if (teper - z.posledneePriyoma >= kProgressPauza) {
        z.posledneePriyoma = teper;
        OtpravitProgress(z, @"progress", (long long)z.telo.length, z.ozhidaetsyaPriyoma);
    }
}

// --- Делегат: ход отправки --------------------------------------------------

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    HTTP3Zadacha *z = nil;
    @synchronized (self) { z = self.zadachi[@(task.taskIdentifier)]; }
    if (!z || !z.progressOtpravki) return;

    if (!z.nachaloOtpravki) {
        z.nachaloOtpravki = YES;
        OtpravitProgress(z, @"began", 0, totalBytesExpectedToSend);
    }
    NSTimeInterval teper = [NSDate timeIntervalSinceReferenceDate];
    if (teper - z.posledneeOtpravki >= kProgressPauza) {
        z.posledneeOtpravki = teper;
        OtpravitProgress(z, @"progress", totalBytesSent, totalBytesExpectedToSend);
    }
}

// --- Делегат: завершение ----------------------------------------------------

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    @autoreleasepool {
        NSNumber *klyuch = @(task.taskIdentifier);
        HTTP3Zadacha *z = nil;
        NSString *imyaProtokola = nil;
        @synchronized (self) {
            z = self.zadachi[klyuch];
            if (z) [self.zadachi removeObjectForKey:klyuch];
            imyaProtokola = self.protokolZadachi[klyuch];
            if (imyaProtokola) [self.protokolZadachi removeObjectForKey:klyuch];
            if (z) [self.activeTasks removeObjectForKey:@(z.reqId)];
        }
        if (!z) return;

        NSInteger statusCode = 0;

        // Протокол берётся из метрики задачи, а не выдумывается. Если метрика
        // не пришла, так и сообщаем — врать про HTTP/3 нельзя, на этом поле
        // держится вся диагностика транспорта.
        NSString *protocol;
        if ([imyaProtokola hasPrefix:@"h3"]) {
            protocol = [NSString stringWithFormat:@"HTTP/3 (QUIC / %@)", imyaProtokola];
        } else if ([imyaProtokola hasPrefix:@"h2"]) {
            protocol = [NSString stringWithFormat:@"HTTP/2.0 (%@)", imyaProtokola];
        } else if (imyaProtokola.length > 0) {
            protocol = [NSString stringWithFormat:@"HTTP (%@)", imyaProtokola];
        } else {
            protocol = @"HTTP (протокол не сообщён)";
        }
        NSString *transport = @"Native Apple Network.framework (NSURLSession)";
        NSMutableDictionary *respHeaders = [NSMutableDictionary dictionary];

        if ([task.response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)task.response;
            statusCode = httpResp.statusCode;
            [respHeaders addEntriesFromDictionary:httpResp.allHeaderFields];
        }

        // ВЫСОКОПРОИЗВОДИТЕЛЬНЫЙ ПЕРЕНОС ДАННЫХ В LUA:
        // Выделяем сырой C-буфер malloc() для передачи байтов в главный поток Lua.
        // Это полностью предотвращает аккумуляцию объектов NSString/CFString в куче ARC.
        void *responseBuf = NULL;
        NSUInteger responseLen = 0;
        NSData *data = z.telo;

        if (data && data.length > 0) {
            @synchronized (self) { self.totalBytesReceived += data.length; }
            responseLen = data.length;
            responseBuf = malloc(responseLen);
            if (responseBuf) {
                [data getBytes:responseBuf length:responseLen];
            } else {
                responseLen = 0;
            }
        }

        // isError — ТОЛЬКО про сбой транспорта, как у network.request в
        // Solar2D и как в версии для Windows. Код 4xx/5xx это нормально
        // доставленный ответ: он приезжает в status, а разбирает его
        // вызывающий.
        BOOL isError = (error != nil);
        NSString *errorDesc = error ? error.localizedDescription : nil;

        @synchronized (self) {
            if (isError) self.totalFailed++;
            else self.totalCompleted++;
        }

        CoronaLuaRef listenerRef = z.listenerRef;
        lua_State *mainLuaState = z.mainLuaState;
        NSInteger reqId = z.reqId;
        long long ozhidaetsya = z.ozhidaetsyaPriyoma;

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

                        // Завершение — тоже фаза, и вызывающий отличает его от
                        // промежуточных событий по ней, а не по наличию полей.
                        lua_pushstring(currentL, "ended");
                        lua_setfield(currentL, -2, "phase");

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

                        lua_pushnumber(currentL, (lua_Number)responseLen);
                        lua_setfield(currentL, -2, "bytesTransferred");

                        lua_pushnumber(currentL, (lua_Number)ozhidaetsya);
                        lua_setfield(currentL, -2, "bytesEstimated");

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
    int tablicaIdx = 0;   // где лежит таблица параметров, если она есть

    // 1. Определение параметров по типам аргументов
    if (lua_isstring(L, 2)) {
        // Сигнатура Solar2D: (url, method, listener [, params])
        method = [NSString stringWithUTF8String:lua_tostring(L, 2)];
        listenerIdx = 3;

        if (lua_istable(L, 4)) {
            tablicaIdx = 4;
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
        tablicaIdx = 2;
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
        // Раньше отсюда читался ТОЛЬКО timeout: метод, тело и заголовки
        // терялись молча, и запрос уходил пустым GET без единого заголовка.
        listenerIdx = 2;
        if (lua_istable(L, 3)) {
            tablicaIdx = 3;
            lua_getfield(L, 3, "method");
            if (lua_isstring(L, -1)) method = [NSString stringWithUTF8String:lua_tostring(L, -1)];
            lua_pop(L, 1);

            lua_getfield(L, 3, "timeout");
            if (lua_isnumber(L, -1)) timeout = lua_tonumber(L, -1);
            lua_pop(L, 1);

            lua_getfield(L, 3, "body");
            if (lua_isstring(L, -1)) {
                size_t len = 0;
                const char *bytes = lua_tolstring(L, -1, &len);
                bodyData = [NSData dataWithBytes:bytes length:len];
            }
            lua_pop(L, 1);

            lua_getfield(L, 3, "headers");
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
    }

    // Просят ли события хода передачи. Отдельный флаг, а не всегда: события
    // идут в очередь Lua-потока, и сыпать ими на каждый запрос игры незачем —
    // их ждёт только выгрузка и скачивание файлов.
    //
    // ЗНАЧЕНИЕ БЫВАЕТ И СТРОКОЙ. В Solar2D params.progress принимает "upload"
    // либо "download"; true понимается как «оба направления». Читается из той
    // же таблицы параметров, что и timeout, при любой из трёх сигнатур.
    BOOL progressOtpravki = NO;
    BOOL progressPriyoma = NO;
    if (tablicaIdx > 0) {
        lua_getfield(L, tablicaIdx, "progress");
        if (lua_isboolean(L, -1)) {
            progressOtpravki = lua_toboolean(L, -1) ? YES : NO;
            progressPriyoma = progressOtpravki;
        } else if (lua_isstring(L, -1)) {
            NSString *napravlenie = [NSString stringWithUTF8String:lua_tostring(L, -1)];
            progressOtpravki = [napravlenie caseInsensitiveCompare:@"upload"] == NSOrderedSame;
            progressPriyoma = [napravlenie caseInsensitiveCompare:@"download"] == NSOrderedSame;
        }
        lua_pop(L, 1);
    }

    CoronaLuaRef listenerRef = NULL;
    if (lua_isfunction(L, listenerIdx) || lua_istable(L, listenerIdx)) {
        listenerRef = SafeCoronaLuaNewRef(L, listenerIdx);
    } else if (tablicaIdx > 0) {
        // Слушатель может лежать полем в самой таблице параметров — так его
        // передаёт initiateRequest(url, params). Раньше это поле не читалось
        // вовсе, и при такой сигнатуре обратного вызова не было никогда.
        lua_getfield(L, tablicaIdx, "listener");
        if (lua_isfunction(L, -1) || lua_istable(L, -1)) {
            listenerRef = SafeCoronaLuaNewRef(L, lua_gettop(L));
        }
        lua_pop(L, 1);
    }

    if (listenerRef == NULL) {
        // Без слушателя запрос бессмысленен: вызывающий получил бы номер и
        // тишину. Раньше он в этом случае всё равно уходил в сеть.
        lua_pushinteger(L, -1);
        return 1;
    }

    HTTP3PluginManager *mgr = [HTTP3PluginManager sharedInstance];
    NSInteger reqId = [mgr requestWithURL:[NSString stringWithUTF8String:urlStr]
                                  method:method
                                 headers:headers
                                    body:bodyData
                                 timeout:timeout
                        progressOtpravki:progressOtpravki
                         progressPriyoma:progressPriyoma
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

// Новое имя модуля — plugin.http3.ntv (прежнее оставлено выше для
// совместимости). Понадобилось из-за Android: пакет с сегментом native javac
// собрать не может, это ключевое слово Java, и ради обхода загрузчик держали
// на Kotlin, подмешивая в AAR весь kotlin-stdlib.
CORONA_EXPORT int luaopen_plugin_http3_ntv(lua_State *L) {
    return luaopen_plugin_http3(L);
}

CORONA_EXPORT int CoronaPluginLuaLoad_plugin_http3_ntv(lua_State *L) {
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
