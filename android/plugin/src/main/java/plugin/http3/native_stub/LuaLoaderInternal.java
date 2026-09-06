package plugin.http3.native_stub;

import android.content.Context;
import android.util.Log;
import com.naef.jnlua.LuaState;
import com.naef.jnlua.LuaType;
import com.naef.jnlua.JavaFunction;
import com.naef.jnlua.NamedJavaFunction;
import com.ansca.corona.CoronaEnvironment;
import com.ansca.corona.CoronaLua;
import com.ansca.corona.CoronaRuntime;
import com.ansca.corona.CoronaRuntimeTask;
import com.ansca.corona.CoronaRuntimeTaskDispatcher;
import com.google.android.gms.net.CronetProviderInstaller;
import com.google.android.gms.tasks.Task;
import com.google.android.gms.tasks.Tasks;
import org.chromium.net.CronetEngine;
import org.chromium.net.CronetProvider;
import org.chromium.net.UrlRequest;
import org.chromium.net.UrlResponseInfo;
import org.chromium.net.CronetException;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.channels.Channels;
import java.nio.channels.WritableByteChannel;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

// ===========================================================================
// Унифицированная реализация плагина plugin.http3.native для Android.
//
// АРХИТЕКТУРА И ВОЗМОЖНОСТИ:
//   - Использует движок Chromium Cronet через Google Play Services.
//   - Возвращает уникальный числовой requestId для каждого запроса.
//   - Поддерживает динамический таймаут (по умолчанию 3.0 секунды).
//   - Формирует полный набор полей ответа (isError, error, status, response,
//     bytesTotal, headers, protocol, transport, isNative, requestId).
//   - Экспортирует функции cancel(requestId), getMemoryStats(), collectGarbage().
// ===========================================================================
public class LuaLoaderInternal implements JavaFunction {

    private static final String TAG = "HTTP3_Cronet";

    // --- Состояние CronetEngine (инициализируется лениво, один раз на процесс) ---
    private static boolean sCronetInitialized = false;
    private static boolean sCronetInitializationFailed = false;
    private static CronetEngine sCronetEngine = null;

    // Пул потоков для выполнения запросов Cronet
    private static final Executor sExecutor = Executors.newCachedThreadPool();

    // Планировщик таймаутов (Watchdog)
    private static final ScheduledExecutorService sWatchdog = Executors.newSingleThreadScheduledExecutor();

    // Счетчик и реестр активных запросов по уникальному ID
    private static final AtomicInteger sRequestIdCounter = new AtomicInteger(1);
    private static final Map<Integer, UrlRequest> sActiveRequestsMap = new ConcurrentHashMap<>();
    private static final AtomicLong sTotalCompleted = new AtomicLong(0);
    private static final AtomicLong sTotalFailed = new AtomicLong(0);

    /**
     * Точка входа в плагин при require "plugin.http3.native".
     */
    @Override
    public int invoke(LuaState L) {
        NamedJavaFunction[] luaFunctions = new NamedJavaFunction[] {
            new InitiateRequestWrapper(),
            new InitiateRequestWrapper("request"),
            new CancelWrapper(),
            new GetMemoryStatsWrapper(),
            new CollectGarbageWrapper()
        };
        L.register("plugin.http3.native", luaFunctions);
        return 1;
    }

    // ===========================================================================
    // Инициализация Cronet
    // ===========================================================================

    /**
     * Попытка инициализировать CronetEngine (синхронно, на вызывающем потоке).
     */
    private static synchronized boolean initializeCronet(Context context) {
        if (sCronetInitialized) {
            return true;
        }

        try {
            Log.i(TAG, "Инициализация Cronet через Google Play Services...");

            CronetEngine.Builder builder = null;

            // 1. Проверяем наличие уже доступных и включенных провайдеров Cronet на устройстве
            try {
                List<CronetProvider> providers = CronetProvider.getAllProviders(context);
                for (CronetProvider provider : providers) {
                    if (provider.isEnabled()) {
                        builder = provider.createBuilder();
                        Log.i(TAG, "Успешно найден доступный CronetProvider: " + provider.getName() + " (v" + provider.getVersion() + ")");
                        break;
                    }
                }
            } catch (Throwable t) {
                Log.w(TAG, "Не удалось опросить список CronetProvider: " + t.getMessage());
            }

            // 2. Если готовый провайдер еще не был инициализирован, запрашиваем установку Cronet через Google Play Services
            if (builder == null) {
                try {
                    Task<Void> installTask = CronetProviderInstaller.installProvider(context);
                    Tasks.await(installTask, 5, TimeUnit.SECONDS);
                    builder = new CronetEngine.Builder(context);
                } catch (Throwable t) {
                    Log.w(TAG, "Установка CronetProvider через Google Play Services завершилась с ошибкой: " + t.getMessage());
                    return false;
                }
            }

            // Включаем поддержку протоколов QUIC (HTTP/3), HTTP/2 и сжатия Brotli
            builder.enableQuic(true);
            builder.enableHttp2(true);
            builder.enableBrotli(true);

            // Настраиваем дисковый кэш исключительно для сохранения Alt-Svc, сертификатов и сессионных токенов QUIC.
            // Использование HTTP_CACHE_DISK_NO_HTTP гарантирует, что сам HTTP-контент ответов НЕ кэшируется на диске,
            // и каждый сетевой запрос из приложения отправляется в реальную сеть.
            try {
                java.io.File cacheDir = new java.io.File(context.getCacheDir(), "cronet_cache");
                if (!cacheDir.exists()) {
                    cacheDir.mkdirs();
                }
                builder.setStoragePath(cacheDir.getAbsolutePath());
                builder.enableHttpCache(CronetEngine.Builder.HTTP_CACHE_DISK_NO_HTTP, 10 * 1024 * 1024); // Дисковый кэш QUIC-метаданных 10 МБ
            } catch (Exception e) {
                Log.w(TAG, "Не удалось настроить дисковый кэш Cronet: " + e.getMessage());
            }

            // Экспериментальные JSON-опции Cronet:
            // 1. race_cert_verification: параллельная проверка сертификатов для ускорения рукопожатия.
            // 2. delay_tcp_race: старт QUIC на 250 мс раньше TCP в соответствии с Happy Eyeballs v3.
            // 3. initial_delay_for_broken_alternative_service_seconds: 10 секунд задержки перед повторной попыткой использовать H3/QUIC после сбоя.
            //    При блокировке UDP Cronet временно отключает HTTP/3 на 10 секунд, а после восстановления пропуска UDP
            //    по истечении 10 секунд новые сессии автоматически возвращаются на транспорт HTTP/3.
            // 4. connection_id_length: длина идентификатора соединения QUIC (Connection ID) 4 байта.
            String experimentalOptions = "{\"QUIC\":{\"race_cert_verification\":true,\"delay_tcp_race\":true,\"initial_delay_for_broken_alternative_service_seconds\":10,\"connection_id_length\":4}}";
            try {
                if (builder instanceof org.chromium.net.ExperimentalCronetEngine.Builder) {
                    ((org.chromium.net.ExperimentalCronetEngine.Builder) builder).setExperimentalOptions(experimentalOptions);
                } else {
                    java.lang.reflect.Method setExpMethod = builder.getClass().getMethod("setExperimentalOptions", String.class);
                    setExpMethod.invoke(builder, experimentalOptions);
                }
            } catch (Exception e) {
                Log.w(TAG, "Не удалось применить экспериментальные опции Cronet: " + e.getMessage());
            }

            sCronetEngine = builder.build();
            sCronetInitialized = true;
            Log.i(TAG, "Cronet успешно инициализирован через Google Play Services.");
            return true;
        } catch (Throwable t) {
            Log.w(TAG, "Не удалось инициализировать Cronet: " + t.getMessage());
            return false;
        }
    }

    // ===========================================================================
    // Lua-мост: initiateRequest(url, params) -> requestId (int)
    // ===========================================================================
    private static class InitiateRequestWrapper implements NamedJavaFunction {
        private final String mName;

        public InitiateRequestWrapper() {
            this.mName = "initiateRequest";
        }

        public InitiateRequestWrapper(String name) {
            this.mName = name;
        }

        @Override
        public String getName() {
            return mName;
        }

        @Override
        public int invoke(LuaState L) {
            String url = L.checkString(1);

            String method = "GET";
            double timeoutSec = 15.0;
            // Тело — БАЙТЫ, а не String. Строка Java хранит символы, и любой
            // перевод байт<->String идёт через кодировку: двоичные данные
            // (MessagePack, Protobuf, сырые файлы) валидным UTF-8 не являются,
            // невалидные последовательности заменяются на U+FFFD, и тело
            // портится молча.
            // JNLua в Corona даёт байтовые методы (toByteArray/pushString(byte[])),
            // они и работают по длине, а не до первого нулевого байта.
            byte[] body = null;
            Map<String, String> headers = new HashMap<>();
            int listenerIdx = 0;
            int tableIdx = 0;

            // Гибкое определение сигнатуры вызова (cLib.request или cLib.initiateRequest)
            if (L.type(2) == LuaType.STRING) {
                // Сигнатура cLib.request(url, method, listener [, params])
                method = L.toString(2);
                listenerIdx = 3;
                if (L.type(4) == LuaType.TABLE) {
                    tableIdx = 4;
                }
            } else if (L.type(2) == LuaType.TABLE) {
                // Сигнатура cLib.initiateRequest(url, params)
                tableIdx = 2;
                if (CoronaLua.isListener(L, 3, "http3")) {
                    listenerIdx = 3;
                }
            } else if (CoronaLua.isListener(L, 2, "http3")) {
                // Сигнатура cLib.request(url, listener [, params])
                listenerIdx = 2;
                if (L.type(3) == LuaType.TABLE) {
                    tableIdx = 3;
                }
            }

            // Извлечение параметров из таблицы, если она была передана
            if (tableIdx > 0) {
                L.getField(tableIdx, "method");
                if (L.type(-1) == LuaType.STRING) {
                    method = L.toString(-1);
                }
                L.pop(1);

                L.getField(tableIdx, "timeout");
                if (L.type(-1) == LuaType.NUMBER) {
                    timeoutSec = L.toNumber(-1);
                }
                L.pop(1);

                L.getField(tableIdx, "body");
                if (L.type(-1) == LuaType.STRING) {
                    // toByteArray, а не toString: строка Lua — это байты с
                    // длиной, и переводить их в java.lang.String нельзя (см.
                    // коммент у объявления body выше).
                    body = L.toByteArray(-1);
                }
                L.pop(1);

                L.getField(tableIdx, "headers");
                if (L.type(-1) == LuaType.TABLE) {
                    L.pushNil();
                    while (L.next(-2)) {
                        String key = L.toString(-2);
                        String val = L.toString(-1);
                        if (key != null && val != null) {
                            headers.put(key, val);
                        }
                        L.pop(1);
                    }
                }
                L.pop(1);

                if (listenerIdx == 0) {
                    L.getField(tableIdx, "listener");
                    if (CoronaLua.isListener(L, -1, "http3")) {
                        listenerIdx = L.getTop();
                    } else {
                        L.pop(1);
                    }
                }
            }

            if (timeoutSec <= 0) {
                timeoutSec = 15.0;
            }

            // Валидация слушателя событий Lua
            if (listenerIdx == 0 || !CoronaLua.isListener(L, listenerIdx, "http3")) {
                throw new IllegalArgumentException("HTTP3 Error: listener должен быть функцией или объектом слушателя");
            }
            final int listenerRef = CoronaLua.newRef(L, listenerIdx);
            if (listenerIdx == L.getTop() && tableIdx > 0) {
                L.pop(1);
            }

            final Context context = CoronaEnvironment.getApplicationContext();
            if (context == null) {
                CoronaLua.deleteRef(L, listenerRef);
                L.pushNil();
                return 1;
            }

            if (!initializeCronet(context)) {
                CoronaLua.deleteRef(L, listenerRef);
                L.pushNil();
                return 1;
            }

            final CoronaRuntimeTaskDispatcher dispatcher = new CoronaRuntimeTaskDispatcher(L);
            final int requestId = sRequestIdCounter.getAndIncrement();

            final String finalMethod = method;
            final byte[] finalBody = body;
            final Map<String, String> finalHeaders = headers;
            final double finalTimeout = timeoutSec;

            sExecutor.execute(new Runnable() {
                @Override
                public void run() {
                    try {
                        startCronetRequest(requestId, url, finalMethod, finalHeaders, finalBody, finalTimeout, dispatcher, listenerRef);
                    } catch (Exception e) {
                        Log.e(TAG, "Ошибка при запуске запроса Cronet: " + e.getMessage());
                        sActiveRequestsMap.remove(requestId);
                        sTotalFailed.incrementAndGet();
                        triggerFallback(dispatcher, listenerRef);
                    }
                }
            });

            L.pushInteger(requestId);
            return 1;
        }
    }

    // ===========================================================================
    // Отмена запроса по ID
    // ===========================================================================
    private static class CancelWrapper implements NamedJavaFunction {
        @Override
        public String getName() {
            return "cancel";
        }

        @Override
        public int invoke(LuaState L) {
            if (L.type(1) == LuaType.NUMBER) {
                int reqId = L.toInteger(1);
                UrlRequest req = sActiveRequestsMap.remove(reqId);
                if (req != null) {
                    req.cancel();
                    sTotalFailed.incrementAndGet();
                    L.pushBoolean(true);
                    return 1;
                }
            }
            L.pushBoolean(false);
            return 1;
        }
    }

    // ===========================================================================
    // Метрики использования памяти (Java Heap + Native Heap)
    // ===========================================================================
    private static class GetMemoryStatsWrapper implements NamedJavaFunction {
        @Override
        public String getName() {
            return "getMemoryStats";
        }

        @Override
        public int invoke(LuaState L) {
            Runtime runtime = Runtime.getRuntime();
            long javaHeapBytes = runtime.totalMemory() - runtime.freeMemory();
            long nativeHeapBytes = android.os.Debug.getNativeHeapAllocatedSize();
            long totalAllocatedBytes = javaHeapBytes + nativeHeapBytes;
            double totalAllocatedMB = (double) totalAllocatedBytes / (1024.0 * 1024.0);

            L.newTable();

            L.pushNumber(totalAllocatedBytes);
            L.setField(-2, "nativeRSSBytes");

            L.pushNumber(totalAllocatedMB);
            L.setField(-2, "nativeRSSMB");

            L.pushInteger(sActiveRequestsMap.size());
            L.setField(-2, "activeTasks");

            L.pushNumber(sTotalCompleted.get());
            L.setField(-2, "totalCompleted");

            L.pushNumber(sTotalFailed.get());
            L.setField(-2, "totalFailed");

            L.pushBoolean(sCronetInitialized);
            L.setField(-2, "isHTTP3Configured");

            L.pushString("Chromium Cronet (Java & Native Heap)");
            L.setField(-2, "stackName");

            return 1;
        }
    }

    // ===========================================================================
    // Сборка мусора
    // ===========================================================================
    private static class CollectGarbageWrapper implements NamedJavaFunction {
        @Override
        public String getName() {
            return "collectGarbage";
        }

        @Override
        public int invoke(LuaState L) {
            System.gc();
            System.gc();
            L.pushBoolean(true);
            return 1;
        }
    }

    // ===========================================================================
    // Собственно запрос через Cronet
    // ===========================================================================
    private static void startCronetRequest(final int requestId,
                                           final String url,
                                           final String method,
                                           final Map<String, String> headers,
                                           final byte[] body,
                                           final double timeoutSec,
                                           final CoronaRuntimeTaskDispatcher dispatcher,
                                           final int listenerRef) {

        final ByteArrayOutputStream responseStream = new ByteArrayOutputStream();
        final WritableByteChannel responseChannel = Channels.newChannel(responseStream);
        final ScheduledFuture<?>[] watchdogHolder = new ScheduledFuture<?>[1];

        UrlRequest.Callback callback = new UrlRequest.Callback() {
            @Override
            public void onRedirectReceived(UrlRequest request, UrlResponseInfo info, String newLocation) {
                request.followRedirect();
            }

            @Override
            public void onResponseStarted(UrlRequest request, UrlResponseInfo info) {
                request.read(ByteBuffer.allocateDirect(32768));
            }

            @Override
            public void onReadCompleted(UrlRequest request, UrlResponseInfo info, ByteBuffer byteBuffer) {
                byteBuffer.flip();
                try {
                    responseChannel.write(byteBuffer);
                } catch (Exception e) {
                    Log.e(TAG, "Ошибка записи тела ответа: " + e.getMessage());
                }
                byteBuffer.clear();
                request.read(byteBuffer);
            }

            @Override
            public void onSucceeded(UrlRequest request, UrlResponseInfo info) {
                if (watchdogHolder[0] != null) watchdogHolder[0].cancel(false);
                sActiveRequestsMap.remove(requestId);

                final int statusCode = info.getHttpStatusCode();
                // toByteArray, а не toString(): ответ сервера тоже может быть
                // двоичным, и toString() без кодировки разобрал бы его как
                // UTF-8, заменив невалидные байты на U+FFFD.
                final byte[] responseBytes = responseStream.toByteArray();
                final int bytesTotal = responseStream.size();
                final boolean isError = statusCode >= 400;
                final String reason = isError ? "HTTP Error " + statusCode : null;
                final Map<String, List<String>> responseHeaders = info.getAllHeaders();

                if (isError) {
                    sTotalFailed.incrementAndGet();
                } else {
                    sTotalCompleted.incrementAndGet();
                }

                final String rawProtocol = info != null ? info.getNegotiatedProtocol() : "";
                final String protocolString;
                if (rawProtocol != null && (rawProtocol.startsWith("h3") || rawProtocol.startsWith("quic") || rawProtocol.contains("h3"))) {
                    protocolString = "HTTP/3 (QUIC / " + rawProtocol + ")";
                } else if (rawProtocol != null && rawProtocol.startsWith("h2")) {
                    protocolString = "HTTP/2.0 (" + rawProtocol + ")";
                } else if (rawProtocol != null && !rawProtocol.isEmpty()) {
                    protocolString = "HTTP (" + rawProtocol + ")";
                } else {
                    protocolString = "HTTP/3 (QUIC / Cronet)";
                }

                dispatcher.send(new CoronaRuntimeTask() {
                    @Override
                    public void executeUsing(CoronaRuntime runtime) {
                        LuaState L = runtime.getLuaState();
                        CoronaLua.newEvent(L, "http3");

                        L.pushInteger(requestId);
                        L.setField(-2, "requestId");

                        L.pushBoolean(isError);
                        L.setField(-2, "isError");

                        // pushString(byte[]) кладёт строку Lua ПО ДЛИНЕ — байты
                        // доходят до Lua ровно такими, какими пришли от сервера.
                        L.pushString(responseBytes);
                        L.setField(-2, "response");

                        L.pushInteger(bytesTotal);
                        L.setField(-2, "bytesTotal");

                        L.pushString("Cronet");
                        L.setField(-2, "transport");

                        L.pushString(protocolString);
                        L.setField(-2, "protocol");

                        L.pushBoolean(true);
                        L.setField(-2, "isNative");

                        if (reason != null) {
                            L.pushString(reason);
                            L.setField(-2, "reason");
                            L.pushString(reason);
                            L.setField(-2, "error");
                        } else {
                            L.pushNil();
                            L.setField(-2, "error");
                        }

                        L.pushInteger(statusCode);
                        L.setField(-2, "status");

                        // Формирование таблицы HTTP-заголовков ответа
                        L.newTable();
                        if (responseHeaders != null) {
                            for (Map.Entry<String, List<String>> entry : responseHeaders.entrySet()) {
                                if (entry.getKey() != null && !entry.getValue().isEmpty()) {
                                    L.pushString(entry.getValue().get(0));
                                    L.setField(-2, entry.getKey());
                                }
                            }
                        }
                        L.setField(-2, "headers");

                        try {
                            CoronaLua.dispatchEvent(L, listenerRef, 0);
                        } catch (Exception e) {
                            Log.e(TAG, "Ошибка диспетчеризации Lua события: " + e.getMessage());
                        } finally {
                            CoronaLua.deleteRef(L, listenerRef);
                        }
                    }
                });
            }

            @Override
            public void onFailed(UrlRequest request, UrlResponseInfo info, CronetException error) {
                if (watchdogHolder[0] != null) watchdogHolder[0].cancel(false);
                sActiveRequestsMap.remove(requestId);
                sTotalFailed.incrementAndGet();
                Log.w(TAG, "Cronet request failed: " + error.getMessage());
                triggerFallback(dispatcher, listenerRef);
            }

            @Override
            public void onCanceled(UrlRequest request, UrlResponseInfo info) {
                if (watchdogHolder[0] != null) watchdogHolder[0].cancel(false);
                sActiveRequestsMap.remove(requestId);
                sTotalFailed.incrementAndGet();
                triggerFallback(dispatcher, listenerRef);
            }
        };

        UrlRequest.Builder requestBuilder = sCronetEngine.newUrlRequestBuilder(url, callback, sExecutor);
        requestBuilder.setHttpMethod(method);

        for (Map.Entry<String, String> entry : headers.entrySet()) {
            requestBuilder.addHeader(entry.getKey(), entry.getValue());
        }

        if (body != null && body.length > 0) {
            // Байты уходят как есть, без getBytes(): перекодировка в UTF-8
            // испортила бы двоичное тело.
            requestBuilder.setUploadDataProvider(
                org.chromium.net.UploadDataProviders.create(body),
                sExecutor
            );
        }

        final UrlRequest request = requestBuilder.build();
        sActiveRequestsMap.put(requestId, request);

        long timeoutMillis = (long)(timeoutSec * 1000.0);
        watchdogHolder[0] = sWatchdog.schedule(new Runnable() {
            @Override
            public void run() {
                request.cancel();
            }
        }, timeoutMillis, TimeUnit.MILLISECONDS);

        request.start();
    }

    /**
     * Сообщает Lua-обёртке, что нативный транспорт недоступен/дал сбой.
     */
    private static void triggerFallback(final CoronaRuntimeTaskDispatcher dispatcher, final int listenerRef) {
        dispatcher.send(new CoronaRuntimeTask() {
            @Override
            public void executeUsing(CoronaRuntime runtime) {
                LuaState L = runtime.getLuaState();
                CoronaLua.newEvent(L, "http3");

                L.pushBoolean(true);
                L.setField(-2, "isError");

                L.pushString("NATIVE_TRANSPORT_FAILED");
                L.setField(-2, "reason");

                L.pushString("Cronet");
                L.setField(-2, "transport");

                try {
                    CoronaLua.dispatchEvent(L, listenerRef, 0);
                } catch (Exception e) {
                    Log.e(TAG, "Ошибка отправки события фоллбэка в Lua: " + e.getMessage());
                } finally {
                    CoronaLua.deleteRef(L, listenerRef);
                }
            }
        });
    }
}
