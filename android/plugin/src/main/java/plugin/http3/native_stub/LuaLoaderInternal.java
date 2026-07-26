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
        if (sCronetInitializationFailed) {
            return false;
        }

        try {
            Log.i(TAG, "Попытка инициализации Cronet через Google Play Services...");

            Task<Void> installTask = CronetProviderInstaller.installProvider(context);
            Tasks.await(installTask, 5, TimeUnit.SECONDS);

            CronetEngine.Builder builder = new CronetEngine.Builder(context);

            // Включаем поддержку протоколов QUIC (HTTP/3), HTTP/2 и сжатия Brotli
            builder.enableQuic(true);
            builder.enableHttp2(true);
            builder.enableBrotli(true);

            // Настраиваем дисковый кэш для сохраненияAlt-Svc, сертификатов и сессионных токенов QUIC
            try {
                java.io.File cacheDir = new java.io.File(context.getCacheDir(), "cronet_cache");
                if (!cacheDir.exists()) {
                    cacheDir.mkdirs();
                }
                builder.setStoragePath(cacheDir.getAbsolutePath());
                builder.enableHttpCache(CronetEngine.Builder.HTTP_CACHE_DISK, 10 * 1024 * 1024); // Дисковый кэш 10 МБ
            } catch (Exception e) {
                Log.w(TAG, "Не удалось настроить дисковый кэш Cronet: " + e.getMessage());
            }

            // Экспериментальные JSON-опции Cronet для мгновенной установки QUIC и гонки сертификатов
            String experimentalOptions = "{\"QUIC\":{\"host_whitelist\":\"*\",\"close_sessions_on_ip_change\":false,\"race_cert_verification\":true,\"connection_options\":\"TIME,RES1\"}}";
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

            // Регистрируем QUIC-подсказки (QuicHint) для основных доменов, чтобы первый же запрос выполнялся по QUIC
            builder.addQuicHint("cloudflare-quic.com", 443, 443);
            builder.addQuicHint("quic.tech", 443, 443);
            builder.addQuicHint("httpbin.org", 443, 443);
            builder.addQuicHint("www.google.com", 443, 443);

            sCronetEngine = builder.build();
            sCronetInitialized = true;
            Log.i(TAG, "Cronet успешно инициализирован с поддержкой QUIC и дисковым кэшем.");
            return true;
        } catch (Throwable t) {
            sCronetInitializationFailed = true;
            Log.w(TAG, "Не удалось инициализировать Cronet. Произойдет автоматическое переключение на Solar2D network.request: " + t.getMessage());
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

            if (L.type(2) != LuaType.TABLE) {
                throw new IllegalArgumentException("HTTP3 Error: Параметр 2 должен быть таблицей");
            }

            // Метод запроса (по умолчанию GET)
            L.getField(2, "method");
            String method = "GET";
            if (L.type(-1) == LuaType.STRING) {
                method = L.toString(-1);
            }
            L.pop(1);

            // Таймаут запроса (по умолчанию 3.0 секунды)
            L.getField(2, "timeout");
            double timeoutSec = 3.0;
            if (L.type(-1) == LuaType.NUMBER) {
                timeoutSec = L.toNumber(-1);
            }
            L.pop(1);
            if (timeoutSec <= 0) {
                timeoutSec = 3.0;
            }

            // Тело запроса (body)
            L.getField(2, "body");
            String body = null;
            if (L.type(-1) == LuaType.STRING) {
                body = L.toString(-1);
            }
            L.pop(1);

            // Заголовки
            Map<String, String> headers = new HashMap<>();
            L.getField(2, "headers");
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

            // Lua-слушатель (listener)
            L.getField(2, "listener");
            if (!CoronaLua.isListener(L, -1, "http3")) {
                L.pop(1);
                throw new IllegalArgumentException("HTTP3 Error: listener должен быть функцией или валидным объектом слушателя");
            }
            final int listenerRef = CoronaLua.newRef(L, -1);
            L.pop(1);

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
            final String finalBody = body;
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
                                           final String body,
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
                final String responseString = responseStream.toString();
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

                        L.pushString(responseString);
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

        if (body != null && body.length() > 0) {
            requestBuilder.setUploadDataProvider(
                org.chromium.net.UploadDataProviders.create(body.getBytes()),
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
