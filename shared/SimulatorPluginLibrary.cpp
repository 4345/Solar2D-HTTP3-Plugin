// SimulatorPluginLibrary.cpp
//
// Windows-реализация плагина plugin.http3.native для Solar2D.
// Собирается как DLL без CRT (clang -nostdlib -m32 -mno-stack-arg-probe), поэтому
// у нас нет ни стандартной библиотеки, ни настоящих заголовков Windows SDK —
// только заглушки из win32/include_fake/ и статическая линковка с рукописными
// def/lib для kernel32/winhttp/ws2_32.
//
// АРХИТЕКТУРА (см. также HTTP3/IMPLEMENTATION.md для кросс-платформенного обзора):
//   Ровно как на iOS/macOS (Network.framework) и Android (Cronet), этот модуль
//   реализует гонку Happy Eyeballs между QUIC (HTTP/3) и обычным TCP+TLS —
//   разница в том, что на Windows нет системного HTTP-клиента с готовой
//   поддержкой QUIC, поэтому гонка реализована вручную, на два потока:
//     - Http3ThreadFunc — самодельный HTTP/3-клиент поверх MsQuic (ручной
//       QUIC-хендшейк, HTTP/3-фрейминг, QPACK-кодирование/декодирование);
//     - Http1ThreadFunc — надёжный резерв поверх WinHTTP (TCP+TLS, HTTP/1.1).
//   Оркестрирует их RaceAndRequestThreadFunc: HTTP/3 стартует сразу, HTTP/1.1 —
//   через 200 мс форы. Первый успешный результат побеждает (RaceFinish
//   гарантирует ровно один отчёт через атомарный CAS).
//
//   Lua-контракт отличается от Android/iOS/macOS: initiateRequest здесь
//   возвращает ЧИСЛО (ID запроса), а не true/false — результат вычитывается
//   отдельным вызовом checkRequest (поллинг), а не push-колбэком в listener.
//   Обёртка plugin_http3.lua различает эти два протокола по ТИПУ возвращаемого
//   значения, а не по имени платформы.
//
#include "SimulatorPluginLibrary.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <stdint.h>
#include "msquic.h"

#ifdef _MSC_VER
#include <intrin.h>
#pragma comment(lib, "kernel32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "winhttp.lib")
static inline bool __sync_bool_compare_and_swap(volatile long* ptr, long oldval, long newval) {
    return _InterlockedCompareExchange(ptr, newval, oldval) == oldval;
}
static inline long __sync_add_and_fetch(volatile long* ptr, long value) {
    return _InterlockedExchangeAdd(ptr, value) + value;
}
#endif

// Отключение подробной пошаговой трассировки для релизной сборки
#define HTTP3_VERBOSE_LOGGING 0

#define HTTP3_REQUEST_TIMEOUT_MS 3000
// Сколько соединение может простаивать, прежде чем QUIC его закроет. Это НЕ
// таймаут запроса: запрос ограничен тремя секундами, а соединение обязано
// переживать паузы между запросами — иначе переиспользовать нечего.
#define HTTP3_IDLE_TIMEOUT_MS 30000

#ifndef _MSC_VER
extern "C" {
void* memcpy(void* dest, const void* src, size_t count) {
    char* d = (char*)dest;
    const char* s = (const char*)src;
    for (size_t i = 0; i < count; i++) d[i] = s[i];
    return dest;
}
void* memset(void* dest, int c, size_t count) {
    char* d = (char*)dest;
    for (size_t i = 0; i < count; i++) d[i] = (char)c;
    return dest;
}
int memcmp(const void* buf1, const void* buf2, size_t count) {
    const unsigned char* s1 = (const unsigned char*)buf1;
    const unsigned char* s2 = (const unsigned char*)buf2;
    for (size_t i = 0; i < count; i++) {
        if (s1[i] < s2[i]) return -1;
        else if (s1[i] > s2[i]) return 1;
    }
    return 0;
}
}
#endif

// ===========================================================================
// Базовые утилиты для nostdlib-сборки (нет ни CRT, ни строковых функций libc)
// и общее состояние результатов запросов, которое читает checkRequest.
// ===========================================================================
static CRITICAL_SECTION g_CritSec;
static int g_NextRequestId = 1;
static int g_CritSecInitialized = 0;

// Определение длины строки для nostdlib сборки
static int MyStrLenW(const wchar_t* s) {
    int len = 0;
    while (s[len]) len++;
    return len;
}

static int MyStrLen(const char* s) {
    int len = 0;
    while (s[len]) len++;
    return len;
}

static int MyStrCmp(const char* a, const char* b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

static void MyStrCopy(char* dst, int dstCap, const char* src) {
    int i = 0;
    while (src[i] && i < dstCap - 1) { dst[i] = src[i]; i++; }
    dst[i] = '\0';
}

static int MyAtoi(const char* s) {
    int v = 0;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    return v;
}

// Запись сообщений в лог отладки и стандартный вывод.
// Защищено критической секцией: ранее LogMsg вызывался из нескольких потоков
// одновременно (фоновый запрос + опрос из Lua), что приводило к «разорванным»
// строкам в консоли и было воспроизводимой гонкой (см. диагностику).
// ЖУРНАЛ ПЛАГИНА. Раньше обе функции были пустыми ((void)msg;), и от нативного
// слоя не приходило ни строчки — разобрать гонку Happy Eyeballs было нечем:
// кто из двух потоков стартовал, когда и почему проиграл, видно только изнутри.
//
// Пишем в файл plugin_http3.log рядом с рабочим каталогом процесса (для
// Solar2D Simulator это каталог проекта). Каждая строка несёт:
//   <мс от старта системы> [<номер потока>] <текст>
// Время в миллисекундах от GetTickCount — абсолютная дата тут не нужна, важны
// ИНТЕРВАЛЫ: задержка перед стартом TCP, длительность рукопожатия QUIC, кто
// ответил первым. Номер потока обязателен: записи Http3ThreadFunc и
// Http1ThreadFunc идут вперемешку, и без него их не разделить.
//
// Файл открывается на каждую запись и закрывается сразу: диагностика нечастая,
// зато не нужно держать дескриптор и синхронизировать его между потоками, а
// дозапись (FILE_APPEND_DATA) с общим доступом не теряет строк соседа.
//
// Стандартной библиотеки здесь нет (см. шапку файла), поэтому число в строку
// переводим сами.
#define HTTP3_LOG_ENABLED 0   // 0 — собрать без журнала (боевая сборка)

#if HTTP3_LOG_ENABLED
static void LogPutNum(unsigned long v, char* out, int* pos, int cap) {
    char tmp[16];
    int n = 0;
    if (v == 0) { tmp[n++] = '0'; }
    while (v > 0 && n < 15) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n > 0 && *pos < cap - 1) { out[(*pos)++] = tmp[--n]; }
}

static void LogPutStr(const char* s, char* out, int* pos, int cap) {
    if (!s) return;
    while (*s && *pos < cap - 1) { out[(*pos)++] = *s++; }
}

static void LogWrite(const char* msg, const char* dopolnenie, unsigned long chislo, int s_chislom) {
    char stroka[512];
    int pos = 0;
    LogPutNum(GetTickCount(), stroka, &pos, sizeof(stroka));
    LogPutStr(" [", stroka, &pos, sizeof(stroka));
    LogPutNum(GetCurrentThreadId(), stroka, &pos, sizeof(stroka));
    LogPutStr("] ", stroka, &pos, sizeof(stroka));
    LogPutStr(msg, stroka, &pos, sizeof(stroka));
    if (dopolnenie) { LogPutStr(dopolnenie, stroka, &pos, sizeof(stroka)); }
    if (s_chislom) { LogPutStr(" = ", stroka, &pos, sizeof(stroka)); LogPutNum(chislo, stroka, &pos, sizeof(stroka)); }
    LogPutStr("\r\n", stroka, &pos, sizeof(stroka));

    // ПУТЬ АБСОЛЮТНЫЙ, во временный каталог пользователя. Относительное имя
    // не годится: файл лёг бы в рабочий каталог процесса, а у Solar2D
    // Simulator это каталог установки в Program Files — туда запись запрещена,
    // CreateFileA молча возвращает INVALID_HANDLE_VALUE, и журнала нет вовсе
    // (ровно это и наблюдалось: игра шла, а файл не появлялся нигде).
    char put[320];
    DWORD n = GetTempPathA(sizeof(put) - 24, put);
    if (n == 0 || n > sizeof(put) - 24) { n = 0; }
    {
        const char* imya = "plugin_http3.log";
        DWORD i = 0;
        while (imya[i] && n + i < sizeof(put) - 1) { put[n + i] = imya[i]; i++; }
        put[n + i] = 0;
    }

    HANDLE h = CreateFileA(put, FILE_APPEND_DATA,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, 0,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD zapisano = 0;
        WriteFile(h, stroka, (DWORD)pos, &zapisano, 0);
        CloseHandle(h);
    }
    // Дублируем в отладочный вывод: под отладчиком/DebugView видно без файла.
    stroka[pos] = 0;
    OutputDebugStringA(stroka);
}
#endif

static void LogMsg(const char* msg) {
#if HTTP3_LOG_ENABLED
    LogWrite(msg, 0, 0, 0);
#else
    (void)msg;
#endif
}

static void LogHexVal(const char* label, unsigned long val) {
#if HTTP3_LOG_ENABLED
    LogWrite(label, 0, val, 1);
#else
    (void)label; (void)val;
#endif
}

typedef struct RequestResult {
    int id;
    int ready;
    int is_error;
    int status_code;
    char* response_data;
    int response_len;
    char transport[16];
    struct RequestResult* next;
} RequestResult;

static RequestResult* g_ResultsList = NULL;

// Глобальные счетчики метрик активности задач для системных отчетов getMemoryStats
static volatile long g_ActiveTasksCount = 0;
static volatile long g_TotalCompletedCount = 0;
static volatile long g_TotalFailedCount = 0;

// Буфер отслеживания отмененных идентификаторов запросов для предотвращения утечек памяти
#define MAX_CANCELLED_IDS 128
static int g_CancelledIds[MAX_CANCELLED_IDS];
static int g_CancelledIdsCount = 0;

// Проверка, был ли запрос отменен со стороны Lua
static int IsRequestCancelled(int id) {
    for (int i = 0; i < g_CancelledIdsCount; i++) {
        if (g_CancelledIds[i] == id) return 1;
    }
    return 0;
}

// Добавление идентификатора запроса в список отмененных
static void AddCancelledId(int id) {
    if (IsRequestCancelled(id)) return;
    if (g_CancelledIdsCount < MAX_CANCELLED_IDS) {
        g_CancelledIds[g_CancelledIdsCount++] = id;
    } else {
        // Сдвиг при переполнении очереди отмененных задач
        for (int i = 0; i < MAX_CANCELLED_IDS - 1; i++) {
            g_CancelledIds[i] = g_CancelledIds[i + 1];
        }
        g_CancelledIds[MAX_CANCELLED_IDS - 1] = id;
    }
}

// Удаление идентификатора из списка отмененных
static void RemoveCancelledId(int id) {
    for (int i = 0; i < g_CancelledIdsCount; i++) {
        if (g_CancelledIds[i] == id) {
            for (int j = i; j < g_CancelledIdsCount - 1; j++) {
                g_CancelledIds[j] = g_CancelledIds[j + 1];
            }
            g_CancelledIdsCount--;
            break;
        }
    }
}

// Добавление результата запроса в потокобезопасный список с проверкой на отмену и очисткой старых результатов
static void AddResult(int id, int is_error, int status, const char* data, int len, const char* transport) {
    EnterCriticalSection(&g_CritSec);

    // Обновление метрик задач
    if (g_ActiveTasksCount > 0) g_ActiveTasksCount--;
    if (is_error) g_TotalFailedCount++;
    else g_TotalCompletedCount++;

    // Если запрос был отменен до завершения, отбрасываем результат для предотвращения утечки
    if (IsRequestCancelled(id)) {
        RemoveCancelledId(id);
        LeaveCriticalSection(&g_CritSec);
        return;
    }

    // Автоматическое удаление старых результатов из списка при превышении лимита (более 64 записей)
    int count = 0;
    RequestResult* curr = g_ResultsList;
    while (curr) { count++; curr = curr->next; }
    if (count >= 64 && g_ResultsList) {
        RequestResult* prev = NULL;
        curr = g_ResultsList;
        while (curr->next) { prev = curr; curr = curr->next; }
        if (prev) prev->next = NULL;
        else g_ResultsList = NULL;
        void* heap = GetProcessHeap();
        if (curr->response_data) HeapFree(heap, 0, curr->response_data);
        HeapFree(heap, 0, curr);
    }

    void* heap = GetProcessHeap();
    RequestResult* res = (RequestResult*)HeapAlloc(heap, 0, sizeof(RequestResult));
    res->id = id;
    res->ready = 1;
    res->is_error = is_error;
    res->status_code = status;

    if (data && len > 0) {
        res->response_data = (char*)HeapAlloc(heap, 0, len + 1);
        for (int i = 0; i < len; i++) res->response_data[i] = data[i];
        res->response_data[len] = '\0';
        res->response_len = len;
    } else {
        res->response_data = NULL;
        res->response_len = 0;
    }

    int t_idx = 0;
    while (transport[t_idx] && t_idx < 15) {
        res->transport[t_idx] = transport[t_idx];
        t_idx++;
    }
    res->transport[t_idx] = '\0';

    res->next = g_ResultsList;
    g_ResultsList = res;

    LeaveCriticalSection(&g_CritSec);
}

// Извлечение и удаление результата по ID
static RequestResult* GetAndRemoveResult(int id) {
    EnterCriticalSection(&g_CritSec);
    RequestResult* prev = NULL;
    RequestResult* curr = g_ResultsList;
    while (curr) {
        if (curr->id == id) {
            if (prev) {
                prev->next = curr->next;
            } else {
                g_ResultsList = curr->next;
            }
            LeaveCriticalSection(&g_CritSec);
            return curr;
        }
        prev = curr;
        curr = curr->next;
    }
    LeaveCriticalSection(&g_CritSec);
    return NULL;
}

// Собственная вспомогательная функция преобразования числа в строку для nostdlib сборки
static void MyIntToStr(int val, char* buf) {
    int i = 0;
    if (val == 0) {
        buf[i++] = '0';
        buf[i] = '\0';
        return;
    }
    char tmp[16];
    int t_idx = 0;
    while (val > 0) {
        tmp[t_idx++] = '0' + (val % 10);
        val /= 10;
    }
    for (int j = t_idx - 1; j >= 0; j--) {
        buf[i++] = tmp[j];
    }
    buf[i] = '\0';
}

// Парсер URL. host/path — буферы вызывающей стороны фиксированного размера
// (см. AsyncRequestContext: host[256], path[1024]) — раньше копирование в host
// не проверяло границы и переполняло стек на хостах длиннее 256 символов.
static int ParseUrl(const char* url, char* host, int hostCap, int* port, char* path, int pathCap, int* secure) {
    *secure = 0;
    *port = 80;
    const char* p = url;
    if (url[0] == 'h' && url[1] == 't' && url[2] == 't' && url[3] == 'p') {
        p += 4;
        if (*p == 's') {
            *secure = 1;
            *port = 443;
            p++;
        }
        if (*p == ':' && *(p+1) == '/' && *(p+2) == '/') {
            p += 3;
        } else {
            return 0;
        }
    } else {
        return 0;
    }

    char* h = host;
    int h_idx = 0;
    while (*p && *p != '/' && *p != ':') {
        if (h_idx < hostCap - 1) { *h++ = *p; h_idx++; }
        p++;
    }
    *h = '\0';

    if (*p == ':') {
        p++;
        int prt = 0;
        while (*p && *p >= '0' && *p <= '9') {
            prt = prt * 10 + (*p - '0');
            p++;
        }
        *port = prt;
    }

    if (*p == '/') {
        char* pt = path;
        int p_idx = 0;
        while (*p) {
            if (p_idx < pathCap - 1) { *pt++ = *p; p_idx++; }
            p++;
        }
        *pt = '\0';
    } else {
        path[0] = '/';
        path[1] = '\0';
    }
    return 1;
}

// Конвертация ANSI в Wide-строку (UTF-16)
static void AnsiToWide(const char* src, wchar_t* dst, int max_chars) {
    int i = 0;
    while (src[i] && i < max_chars - 1) {
        dst[i] = (wchar_t)src[i];
        i++;
    }
    dst[i] = L'\0';
}

// Контекст асинхронного выполнения запроса
typedef struct AsyncRequestContext {
    int id;
    char url[1024];
    char method[16];
    char body[4096];
    int body_len;
    char headers[2048];
    int secure;
    // Таймаут ЭТОГО запроса, мс. Раньше нативный слой брал зашитую константу, а
    // параметр timeout из Lua не читал вовсе, хотя Lua его передавал. Любой
    // запрос, которому вызывающий разрешил больше, чем зашито, обрывался раньше
    // срока и выглядел как отказ транспорта - хотя ни сеть, ни сервер ни при чём.
    int timeout_ms;
} AsyncRequestContext;

// ===========================================================================
// Гонка Happy Eyeballs: общее состояние между Http3ThreadFunc и Http1ThreadFunc.
// Ровно один из потоков должен вызвать AddResult для данного req->id — это
// гарантируется атомарным CAS на winnerAssigned (через компиляторные атомики
// __sync_*, без новых импортов из kernel32).
// ===========================================================================
typedef struct RaceContext {
    AsyncRequestContext* req;
    volatile long winnerAssigned; // 0 = none, 1 = QUIC, 2 = TCP, 3 = error
    volatile long quicFinished;   // 0 = in-flight, 1 = success, 2 = failed
    volatile long quicSuccess;    // 1 if QUIC succeeded, 0 if failed
    volatile long quicProgress;   // 1 если QUIC успешно прошёл handshake/connected
    volatile long tcpFinished;    // 0 = in-flight, 1 = success, 2 = failed
    volatile long tcpSuccess;     // 1 if TCP succeeded, 0 if failed
    volatile long refCount;       // Счетчик ссылок потоков на контекст гонки для атомарного освобождения памяти

    HANDLE quicDoneEvent;
} RaceContext;

enum RaceOutcome { RACE_SKIPPED, RACE_SUCCESS, RACE_FAILURE };

// Атомарное уменьшение счетчика ссылок и освобождение памяти контекста гонки при refCount == 0
static void ReleaseRaceContext(RaceContext* race) {
    if (!race) return;
    long remaining = __sync_add_and_fetch(&race->refCount, -1);
    if (remaining == 0) {
        void* heap = GetProcessHeap();
        if (race->quicDoneEvent) CloseHandle(race->quicDoneEvent);
        if (race->req) HeapFree(heap, 0, race->req);
        HeapFree(heap, 0, race);
    }
}

// Завершение гонки и фиксация результата. Публикует результат в AddResult без прямого освобождения race.
static void RaceFinish(RaceContext* race, RaceOutcome outcome, int status,
                        const char* data, int len, const char* transport, const char* errMsg) {
    if (outcome == RACE_SUCCESS) {
        race->quicSuccess = 1;
        race->quicFinished = 1;
        if (race->quicDoneEvent) SetEvent(race->quicDoneEvent);
        if (__sync_bool_compare_and_swap(&race->winnerAssigned, 0, 1)) {
            AddResult(race->req->id, 0, status, data, len, transport);
        }
    } else if (outcome == RACE_FAILURE) {
        race->quicSuccess = 0;
        race->quicFinished = 2;
        if (race->quicDoneEvent) SetEvent(race->quicDoneEvent);

        // Публикуем результат ошибки если TCP завершён, отменён или QUIC потерпел сбой
        if (__sync_bool_compare_and_swap(&race->winnerAssigned, 0, 3)) {
            const char* msg = errMsg ? errMsg : "Transport failed";
            AddResult(race->req->id, 1, 0, msg, MyStrLen(msg), "Error");
        }
    }
}

// ===========================================================================
// QUIC variable-length integers (RFC 9000 §16) — используются для обрамления
// HTTP/3-фреймов (тип/длина) и типов потоков. НЕ путать с QPACK prefixed
// integers ниже — это два разных формата varint.
// ===========================================================================
static int WriteQuicVarint(uint8_t* out, uint64_t value) {
    if (value <= 0x3F) {
        out[0] = (uint8_t)value;
        return 1;
    } else if (value <= 0x3FFF) {
        out[0] = 0x40 | (uint8_t)(value >> 8);
        out[1] = (uint8_t)value;
        return 2;
    } else if (value <= 0x3FFFFFFF) {
        out[0] = 0x80 | (uint8_t)(value >> 24);
        out[1] = (uint8_t)(value >> 16);
        out[2] = (uint8_t)(value >> 8);
        out[3] = (uint8_t)value;
        return 4;
    } else {
        out[0] = 0xC0 | (uint8_t)(value >> 56);
        out[1] = (uint8_t)(value >> 48);
        out[2] = (uint8_t)(value >> 40);
        out[3] = (uint8_t)(value >> 32);
        out[4] = (uint8_t)(value >> 24);
        out[5] = (uint8_t)(value >> 16);
        out[6] = (uint8_t)(value >> 8);
        out[7] = (uint8_t)value;
        return 8;
    }
}

// Возвращает число прочитанных байт (0 при нехватке данных)
static int ReadQuicVarint(const uint8_t* data, int len, int pos, uint64_t* value) {
    if (pos >= len) return 0;
    int lenBits = data[pos] >> 6;
    int n = 1 << lenBits; // 1, 2, 4 или 8 байт
    if (pos + n > len) return 0;
    uint64_t v = data[pos] & 0x3F;
    for (int i = 1; i < n; i++) v = (v << 8) | data[pos + i];
    *value = v;
    return n;
}

// ===========================================================================
// QPACK prefixed integers (RFC 7541 §5.1, используется QPACK/RFC 9204)
// ===========================================================================
static int WriteQpackInt(uint8_t* out, int prefixBits, uint8_t fixedBits, uint64_t value) {
    uint64_t max = (1ULL << prefixBits) - 1;
    if (value < max) {
        out[0] = fixedBits | (uint8_t)value;
        return 1;
    }
    out[0] = fixedBits | (uint8_t)max;
    int pos = 1;
    value -= max;
    while (value >= 128) {
        out[pos++] = (uint8_t)((value & 0x7F) | 0x80);
        value >>= 7;
    }
    out[pos++] = (uint8_t)value;
    return pos;
}

// Возвращает число прочитанных байт (0 при ошибке/нехватке данных)
static int ReadQpackInt(const uint8_t* data, int len, int pos, int prefixBits, uint64_t* value) {
    if (pos >= len) return 0;
    uint64_t max = (1ULL << prefixBits) - 1;
    uint64_t v = data[pos] & max;
    int p = pos + 1;
    if (v == max) {
        int shift = 0;
        uint8_t b;
        do {
            if (p >= len) return 0;
            b = data[p++];
            v += (uint64_t)(b & 0x7F) << shift;
            shift += 7;
        } while (b & 0x80);
    }
    *value = v;
    return p - pos;
}

// ===========================================================================
// Huffman-декодер (RFC 7541 Appendix B). Таблица кодов взята из проверенной
// эталонной реализации (Go net/http2/hpack), побитно совместима с RFC.
// ===========================================================================
static const uint32_t kHuffmanCodes[256] = {
    0x1ff8, 0x7fffd8, 0xfffffe2, 0xfffffe3, 0xfffffe4, 0xfffffe5, 0xfffffe6, 0xfffffe7,
    0xfffffe8, 0xffffea, 0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb, 0xfffffec,
    0xfffffed, 0xfffffee, 0xfffffef, 0xffffff0, 0xffffff1, 0xffffff2, 0x3ffffffe, 0xffffff3,
    0xffffff4, 0xffffff5, 0xffffff6, 0xffffff7, 0xffffff8, 0xffffff9, 0xffffffa, 0xffffffb,
    0x14, 0x3f8, 0x3f9, 0xffa, 0x1ff9, 0x15, 0xf8, 0x7fa, 0x3fa, 0x3fb, 0xf9, 0x7fb,
    0xfa, 0x16, 0x17, 0x18, 0x0, 0x1, 0x2, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    0x5c, 0xfb, 0x7ffc, 0x20, 0xffb, 0x3fc, 0x1ffa, 0x21, 0x5d, 0x5e, 0x5f, 0x60, 0x61,
    0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f,
    0x70, 0x71, 0x72, 0xfc, 0x73, 0xfd, 0x1ffb, 0x7fff0, 0x1ffc, 0x3ffc, 0x22, 0x7ffd,
    0x3, 0x23, 0x4, 0x24, 0x5, 0x25, 0x26, 0x27, 0x6, 0x74, 0x75, 0x28, 0x29, 0x2a,
    0x7, 0x2b, 0x76, 0x2c, 0x8, 0x9, 0x2d, 0x77, 0x78, 0x79, 0x7a, 0x7b, 0x7ffe, 0x7fc,
    0x3ffd, 0x1ffd, 0xffffffc, 0xfffe6, 0x3fffd2, 0xfffe7, 0xfffe8, 0x3fffd3, 0x3fffd4, 0x3fffd5,
    0x7fffd9, 0x3fffd6, 0x7fffda, 0x7fffdb, 0x7fffdc, 0x7fffdd, 0x7fffde, 0xffffeb, 0x7fffdf, 0xffffec,
    0xffffed, 0x3fffd7, 0x7fffe0, 0xffffee, 0x7fffe1, 0x7fffe2, 0x7fffe3, 0x7fffe4, 0x1fffdc, 0x3fffd8,
    0x7fffe5, 0x3fffd9, 0x7fffe6, 0x7fffe7, 0xffffef, 0x3fffda, 0x1fffdd, 0xfffe9, 0x3fffdb, 0x3fffdc,
    0x7fffe8, 0x7fffe9, 0x1fffde, 0x7fffea, 0x3fffdd, 0x3fffde, 0xfffff0, 0x1fffdf, 0x3fffdf, 0x7fffeb,
    0x7fffec, 0x1fffe0, 0x1fffe1, 0x3fffe0, 0x1fffe2, 0x7fffed, 0x3fffe1, 0x7fffee, 0x7fffef, 0xfffea,
    0x3fffe2, 0x3fffe3, 0x3fffe4, 0x7ffff0, 0x3fffe5, 0x3fffe6, 0x7ffff1, 0x3ffffe0, 0x3ffffe1, 0xfffeb,
    0x7fff1, 0x3fffe7, 0x7ffff2, 0x3fffe8, 0x1ffffec, 0x3ffffe2, 0x3ffffe3, 0x3ffffe4, 0x7ffffde, 0x7ffffdf,
    0x3ffffe5, 0xfffff1, 0x1ffffed, 0x7fff2, 0x1fffe3, 0x3ffffe6, 0x7ffffe0, 0x7ffffe1, 0x3ffffe7, 0x7ffffe2,
    0xfffff2, 0x1fffe4, 0x1fffe5, 0x3ffffe8, 0x3ffffe9, 0xffffffd, 0x7ffffe3, 0x7ffffe4, 0x7ffffe5, 0xfffec,
    0xfffff3, 0xfffed, 0x1fffe6, 0x3fffe9, 0x1fffe7, 0x1fffe8, 0x7ffff3, 0x3fffea, 0x3fffeb, 0x1ffffee,
    0x1ffffef, 0xfffff4, 0xfffff5, 0x3ffffea, 0x7ffff4, 0x3ffffeb, 0x7ffffe6, 0x3ffffec, 0x3ffffed, 0x7ffffe7,
    0x7ffffe8, 0x7ffffe9, 0x7ffffea, 0x7ffffeb, 0xffffffe, 0x7ffffec, 0x7ffffed, 0x7ffffee, 0x7ffffef, 0x7fffff0,
    0x3ffffee,
};
static const uint8_t kHuffmanCodeLen[256] = {
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6,
    5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10,
    13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6,
    15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5,
    6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
};

static int HuffmanGetBit(const uint8_t* data, int bitPos) {
    return (data[bitPos >> 3] >> (7 - (bitPos & 7))) & 1;
}

static int HuffmanDecode(const uint8_t* data, int byteLen, char* out, int outCap) {
    int totalBits = byteLen * 8;
    int bitPos = 0;
    int outLen = 0;
    while (totalBits - bitPos >= 5 && outLen < outCap - 1) {
        uint32_t code = 0;
        int matched = 0;
        for (int len = 1; len <= 30 && bitPos + len <= totalBits; len++) {
            code = (code << 1) | HuffmanGetBit(data, bitPos + len - 1);
            for (int sym = 0; sym < 256; sym++) {
                if (kHuffmanCodeLen[sym] == len && kHuffmanCodes[sym] == code) {
                    out[outLen++] = (char)sym;
                    bitPos += len;
                    matched = 1;
                    break;
                }
            }
            if (matched) break;
        }
        if (!matched) break; // остаток — паддинг (RFC 7541 §5.2)
    }
    out[outLen] = '\0';
    return outLen;
}

// Запись строки без Huffman (H=0) — валидно по RFC 9204, компрессия не обязательна
static int WriteQpackString(uint8_t* out, const char* s, int len) {
    int pos = WriteQpackInt(out, 7, 0x00, (uint64_t)len);
    for (int i = 0; i < len; i++) out[pos + i] = (uint8_t)s[i];
    return pos + len;
}

// Чтение строки (учитывает H-бит: 0 = сырые байты, 1 = Huffman)
static int ReadQpackString(const uint8_t* data, int len, int pos, char* out, int outCap) {
    if (pos >= len) return 0;
    int huffman = (data[pos] & 0x80) != 0;
    uint64_t strLen;
    int n = ReadQpackInt(data, len, pos, 7, &strLen);
    if (n == 0 || pos + n + (int)strLen > len) return 0;
    int start = pos + n;
    if (huffman) {
        HuffmanDecode(data + start, (int)strLen, out, outCap);
    } else {
        int copyLen = (int)strLen;
        if (copyLen > outCap - 1) copyLen = outCap - 1;
        for (int i = 0; i < copyLen; i++) out[i] = (char)data[start + i];
        out[copyLen] = '\0';
    }
    return n + (int)strLen;
}

// ===========================================================================
// QPACK static table (RFC 9204 Appendix A) — только записи, нужные для
// кодирования запроса и для распознавания ":status" в ответе.
// ===========================================================================
typedef struct QpackStaticEntry { const char* name; const char* value; } QpackStaticEntry;
static const QpackStaticEntry kQpackStatic[99] = {
    {":authority", ""}, {":path", "/"}, {"age", "0"}, {"content-disposition", ""},
    {"content-length", "0"}, {"cookie", ""}, {"date", ""}, {"etag", ""},
    {"if-modified-since", ""}, {"if-none-match", ""}, {"last-modified", ""}, {"link", ""},
    {"location", ""}, {"referer", ""}, {"set-cookie", ""},
    {":method", "CONNECT"}, {":method", "DELETE"}, {":method", "GET"}, {":method", "HEAD"},
    {":method", "OPTIONS"}, {":method", "POST"}, {":method", "PUT"},
    {":scheme", "http"}, {":scheme", "https"},
    {":status", "103"}, {":status", "200"}, {":status", "304"}, {":status", "404"}, {":status", "503"},
    {"accept", "*/*"}, {"accept", "application/dns-message"}, {"accept-encoding", "gzip, deflate, br"},
    {"accept-ranges", "bytes"}, {"access-control-allow-headers", "cache-control"},
    {"access-control-allow-headers", "content-type"}, {"access-control-allow-origin", "*"},
    {"cache-control", "max-age=0"}, {"cache-control", "max-age=2592000"}, {"cache-control", "max-age=604800"},
    {"cache-control", "no-cache"}, {"cache-control", "no-store"}, {"cache-control", "public, max-age=31536000"},
    {"content-encoding", "br"}, {"content-encoding", "gzip"},
    {"content-type", "application/dns-message"}, {"content-type", "application/javascript"},
    {"content-type", "application/json"}, {"content-type", "application/x-www-form-urlencoded"},
    {"content-type", "image/gif"}, {"content-type", "image/jpeg"}, {"content-type", "image/png"},
    {"content-type", "text/css"}, {"content-type", "text/html; charset=utf-8"},
    {"content-type", "text/plain"}, {"content-type", "text/plain;charset=utf-8"},
    {"range", "bytes=0-"},
    {"strict-transport-security", "max-age=31536000"},
    {"strict-transport-security", "max-age=31536000; includesubdomains"},
    {"strict-transport-security", "max-age=31536000; includesubdomains; preload"},
    {"vary", "accept-encoding"}, {"vary", "origin"},
    {"x-content-type-options", "nosniff"}, {"x-xss-protection", "1; mode=block"},
    {":status", "100"}, {":status", "204"}, {":status", "206"}, {":status", "302"}, {":status", "400"},
    {":status", "403"}, {":status", "421"}, {":status", "425"}, {":status", "500"},
    {"accept-language", ""}, {"access-control-allow-credentials", "FALSE"},
    {"access-control-allow-credentials", "TRUE"}, {"access-control-allow-headers", "*"},
    {"access-control-allow-methods", "get"}, {"access-control-allow-methods", "get, post, options"},
    {"access-control-allow-methods", "options"}, {"access-control-expose-headers", "content-length"},
    {"access-control-request-headers", "content-type"}, {"access-control-request-method", "get"},
    {"access-control-request-method", "post"}, {"alt-svc", "clear"}, {"authorization", ""},
    {"content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"},
    {"early-data", "1"}, {"expect-ct", ""}, {"forwarded", ""}, {"if-range", ""}, {"origin", ""},
    {"purpose", "prefetch"}, {"server", ""}, {"timing-allow-origin", "*"},
    {"upgrade-insecure-requests", "1"}, {"user-agent", ""}, {"x-forwarded-for", ""},
    {"x-frame-options", "deny"}, {"x-frame-options", "sameorigin"},
};
#define QPACK_IDX_AUTHORITY 0
#define QPACK_IDX_PATH_ROOT 1
#define QPACK_IDX_SCHEME_HTTPS 23
#define QPACK_IDX_USER_AGENT 95

static int QpackStaticMethodIndex(const char* method) {
    static const char* kMethods[7] = {"CONNECT","DELETE","GET","HEAD","OPTIONS","POST","PUT"};
    for (int i = 0; i < 7; i++) {
        if (MyStrCmp(method, kMethods[i]) == 0) return 15 + i;
    }
    return -1;
}

static int WriteQpackIndexed(uint8_t* out, int idx) {
    out[0] = 0xC0 | (uint8_t)idx; // 1 T=1 IIIIII — все нужные нам индексы < 64
    return 1;
}
static int WriteQpackLiteralWithNameRef(uint8_t* out, int staticIdx, const char* value) {
    // Байт-паттерн "01 N T JJJJ": 0x40 задаёт только префикс "01", но T (бит 4) им
    // не установлен — с 0x40 получалось T=0 (ссылка на ПУСТУЮ динамическую таблицу,
    // невалидно), а не T=1 (статическая таблица). Именно это ловил QPACK-декодер
    // Wireshark как ERR_QPACK_DECOMPRESSION_FAILED сразу после :scheme — тот же баг
    // одинаково валил и Cloudflare, и quic.tech, что и объясняло идентичный 0xFF
    // на обоих серверах (это не серверная особенность, а детерминированный баг кодирования).
    int pos = WriteQpackInt(out, 4, 0x50, (uint64_t)staticIdx); // 01 N=0 T=1 JJJJ
    pos += WriteQpackString(out + pos, value, MyStrLen(value));
    return pos;
}
static int WriteQpackLiteralWithLiteralName(uint8_t* out, const char* name, const char* value) {
    int nlen = MyStrLen(name);
    int pos = WriteQpackInt(out, 3, 0x20, (uint64_t)nlen); // 001 N=0 H=0 KKK
    for (int i = 0; i < nlen; i++) {
        char c = name[i];
        if (c >= 'A' && c <= 'Z') c = c - 'A' + 'a'; // имена полей должны быть в нижнем регистре
        out[pos + i] = (uint8_t)c;
    }
    pos += nlen;
    pos += WriteQpackString(out + pos, value, MyStrLen(value));
    return pos;
}

// Кодирует HEADERS-фрейм запроса. Всегда Required Insert Count=0 / Base=0
// (только статическая таблица + литералы) — см. пояснение по динамической
// таблице в отчёте: на одно соединение выполняется ровно один запрос, поэтому
// динамическая таблица не даёт выигрыша, а полный энкодер/декодер-стрим —
// это отдельный протокол поверх QPACK. Вместо этого клиент объявляет
// SETTINGS_QPACK_MAX_TABLE_CAPACITY=0 (см. Http3ThreadFunc), что по RFC 9204
// обязывает и сервер не использовать динамическую таблицу в ответе.
static int QpackEncodeRequestHeaders(uint8_t* out, const char* method, const char* path,
                                      const char* authority, const char* userAgent,
                                      const char* rawHeaders) {
    int pos = 0;
    out[pos++] = 0x00; // Required Insert Count = 0
    out[pos++] = 0x00; // Sign=0, Delta Base=0

    int midx = QpackStaticMethodIndex(method);
    if (midx >= 0) pos += WriteQpackIndexed(out + pos, midx);
    else pos += WriteQpackLiteralWithLiteralName(out + pos, ":method", method);

    if (MyStrCmp(path, "/") == 0) pos += WriteQpackIndexed(out + pos, QPACK_IDX_PATH_ROOT);
    else pos += WriteQpackLiteralWithNameRef(out + pos, QPACK_IDX_PATH_ROOT, path);

    pos += WriteQpackIndexed(out + pos, QPACK_IDX_SCHEME_HTTPS);
    pos += WriteQpackLiteralWithNameRef(out + pos, QPACK_IDX_AUTHORITY, authority);
    pos += WriteQpackLiteralWithNameRef(out + pos, QPACK_IDX_USER_AGENT, userAgent);

    // Пользовательские заголовки из rawHeaders ("Key: Value\r\n...").
    // key/val — в куче, а не на стеке: эта функция вызывается из ConnectionCallback,
    // который выполняется на внутреннем рабочем потоке msquic с неизвестным (возможно,
    // небольшим) размером стека — крупные локальные буферы там реально роняли процесс
    // (SIGSEGV, воспроизводилось против google.com, см. диагностику).
    void* heap = GetProcessHeap();
    char* key = (char*)HeapAlloc(heap, 0, 256);
    char* val = (char*)HeapAlloc(heap, 0, 1536);
    int i = 0;
    int rawLen = MyStrLen(rawHeaders);
    while (i < rawLen) {
        int k = 0;
        while (i < rawLen && rawHeaders[i] != ':' && k < 255) key[k++] = rawHeaders[i++];
        key[k] = '\0';
        if (i < rawLen && rawHeaders[i] == ':') i++;
        if (i < rawLen && rawHeaders[i] == ' ') i++;
        int v = 0;
        while (i < rawLen && rawHeaders[i] != '\r' && v < 1535) val[v++] = rawHeaders[i++];
        val[v] = '\0';
        while (i < rawLen && (rawHeaders[i] == '\r' || rawHeaders[i] == '\n')) i++;
        if (k > 0) pos += WriteQpackLiteralWithLiteralName(out + pos, key, val);
    }
    HeapFree(heap, 0, key);
    HeapFree(heap, 0, val);

    return pos;
}

// Декодирует HEADERS-фрейм ответа, извлекая только ":status" (единственное,
// что нужно вызывающей стороне — тело ответа читается отдельно из DATA-фреймов).
static void QpackDecodeStatus(const uint8_t* data, int len, int* outStatus) {
    if (len < 2) return;
    int pos = 2; // пропускаем Required Insert Count(1B) + Base(1B): у нас всегда 0x00 0x00
    while (pos < len) {
        uint8_t b = data[pos];
        if (b & 0x80) { // Indexed Field Line: 1 T IIIIII
            int t = (b >> 6) & 1;
            uint64_t idx;
            int n = ReadQpackInt(data, len, pos, 6, &idx);
            if (n == 0) break;
            if (t == 1 && idx < 99 && MyStrCmp(kQpackStatic[idx].name, ":status") == 0) {
                *outStatus = MyAtoi(kQpackStatic[idx].value);
            }
            pos += n;
        } else if ((b & 0xC0) == 0x40) { // Literal With Name Reference: 01 N T JJJJ
            int t = (b >> 4) & 1;
            uint64_t idx;
            int n = ReadQpackInt(data, len, pos, 4, &idx);
            if (n == 0) break;
            pos += n;
            char isStatus = (t == 1 && idx < 99 && MyStrCmp(kQpackStatic[idx].name, ":status") == 0);
            char val[64];
            int vn = ReadQpackString(data, len, pos, val, sizeof(val));
            if (vn == 0) break;
            if (isStatus) *outStatus = MyAtoi(val);
            pos += vn;
        } else if ((b & 0xE0) == 0x20) { // Literal With Literal Name: 001 N H KKK
            char name[256];
            int nn = ReadQpackString(data, len, pos, name, sizeof(name));
            if (nn == 0) break;
            pos += nn;
            char isStatus = (MyStrCmp(name, ":status") == 0);
            char val[64];
            int vn = ReadQpackString(data, len, pos, val, sizeof(val));
            if (vn == 0) break;
            if (isStatus) *outStatus = MyAtoi(val);
            pos += vn;
        } else {
            break;
        }
    }
}

#define HTTP3_FRAME_DATA    0x00
#define HTTP3_FRAME_HEADERS 0x01
#define HTTP3_FRAME_SETTINGS 0x04
#define HTTP3_STREAM_CONTROL 0x00
#define HTTP3_STREAM_QPACK_ENCODER 0x02
#define HTTP3_STREAM_QPACK_DECODER 0x03

static int WriteHttp3Frame(uint8_t* out, uint8_t frameType, const uint8_t* payload, int payloadLen) {
    int pos = WriteQuicVarint(out, frameType);
    pos += WriteQuicVarint(out + pos, (uint64_t)payloadLen);
    for (int i = 0; i < payloadLen; i++) out[pos + i] = payload[i];
    return pos + payloadLen;
}

static void GrowBufferAppend(uint8_t** buf, int* len, int* cap, const uint8_t* data, int dataLen) {
    void* heap = GetProcessHeap();
    if (*len + dataLen > *cap) {
        int newCap = *cap > 0 ? *cap * 2 : 4096;
        while (newCap < *len + dataLen) newCap *= 2;
        uint8_t* nb = (uint8_t*)HeapAlloc(heap, 0, newCap);
        for (int i = 0; i < *len; i++) nb[i] = (*buf)[i];
        if (*buf) HeapFree(heap, 0, *buf);
        *buf = nb;
        *cap = newCap;
    }
    for (int i = 0; i < dataLen; i++) (*buf)[*len + i] = data[i];
    *len += dataLen;
}

static void ParseHttp3ResponseStream(const uint8_t* data, int len, int* outStatus,
                                      uint8_t** outBody, int* outBodyLen, int* outBodyCap) {
    int pos = 0;
    while (pos < len) {
        uint64_t type, flen;
        int tn = ReadQuicVarint(data, len, pos, &type);
        if (tn == 0) break;
        int ln = ReadQuicVarint(data, len, pos + tn, &flen);
        if (ln == 0) break;
        int payloadStart = pos + tn + ln;
        if (payloadStart + (int)flen > len) break;
        if (type == HTTP3_FRAME_HEADERS) {
            QpackDecodeStatus(data + payloadStart, (int)flen, outStatus);
        } else if (type == HTTP3_FRAME_DATA) {
            GrowBufferAppend(outBody, outBodyLen, outBodyCap, data + payloadStart, (int)flen);
        }
        pos = payloadStart + (int)flen;
    }
}

typedef struct Http3State {
    HANDLE doneEvent;
    QUIC_API_TABLE* api;
    HQUIC registration;
    HQUIC configuration;
    HQUIC connection;
    HQUIC ctrlStream;
    HQUIC encoderStream;
    HQUIC decoderStream;
    HQUIC requestStream;

    AsyncRequestContext* req;
    RaceContext* race;
    char host[256];
    char path[1024];
    int port;

    volatile long success;
    volatile long failed;
    volatile long shutdownComplete;
    HANDLE shutdownEvent;
    int status;

    uint8_t* streamAccum; int streamAccumLen; int streamAccumCap;
    uint8_t* respBody; int respBodyLen; int respBodyCap;

    uint8_t ctrlBuf[16];
    uint8_t encoderBuf[8];
    uint8_t decoderBuf[8];
    uint8_t* sendBuf;
    QUIC_BUFFER sendBuffers[2];
    QUIC_BUFFER ctrlSendBuf;
    QUIC_BUFFER encoderSendBuf;
    QUIC_BUFFER decoderSendBuf;
} Http3State;

static long __cdecl NoopStreamCallback(HQUIC Stream, void* Context, QUIC_STREAM_EVENT* Event) {
    (void)Stream; (void)Context; (void)Event;
    return 0;
}

// ===========================================================================
// ПУЛ СОЕДИНЕНИЙ QUIC (в отладке, см. журнал plugin_http3.log)
//
// Соединение создавалось заново на КАЖДЫЙ запрос и закрывалось сразу после
// ответа. По журналу рукопожатие стоило 93-407 мс — до 75% времени запроса
// уходило на приветствие, ровно то, чего QUIC призван избежать.
//
// ОСТОРОЖНОСТЬ ПО УСТРОЙСТВУ: на одном соединении не больше одного запроса за
// раз. Занято или не готово — открываем новое, как раньше.
// ===========================================================================
#define HTTP3_POOL_SIZE 8
// Сколько живёт соединение без запросов. ДОЛЖНО БЫТЬ МЕНЬШЕ, чем таймаут
// простоя самого QUIC (HTTP3_IDLE_TIMEOUT_MS): иначе пул отдаёт соединение,
// которое транспорт уже закрыл, и запрос падает на ровном месте.
#define HTTP3_CONN_IDLE_MS 20000

typedef struct Http3State Http3State;

typedef struct Http3Conn {
    QUIC_API_TABLE* api;
    HQUIC connection;
    HQUIC ctrlStream;
    HQUIC encoderStream;
    HQUIC decoderStream;
    char host[256];
    int port;
    volatile long zanyat;
    volatile long gotovo;
    volatile long mertvo;
    unsigned long poslednee;
    unsigned long prostoy;   // сколько соединение простояло к моменту выдачи из пула
    unsigned long nachalo_rukopozhatiya;   // засечка для замера, см. ZapomnitRukopozhatie
    Http3State* ozhidayushchiy;
    uint8_t ctrlBuf[16];
    uint8_t encoderBuf[8];
    uint8_t decoderBuf[8];
    QUIC_BUFFER ctrlSendBuf;
    QUIC_BUFFER encoderSendBuf;
    QUIC_BUFFER decoderSendBuf;
} Http3Conn;

// ===========================================================================
// ЗАМЕР РУКОПОЖАТИЯ ПО ХОСТАМ — основание для первого окна гонки.
//
// Первое окно (Connection Attempt Delay) отмеряет, сколько ждать установления
// соединения по QUIC, прежде чем поднимать запасную попытку по TCP. Раньше это
// была константа, и никакая константа тут не годится: стоимость рукопожатия
// целиком определяется расстоянием до сервера. На плече в 5000 км RTT по
// волокну не меньше 50 мс, реально около сотни, и рукопожатие стоит столько же;
// на сервере в километре это единицы миллисекунд. Разница в десятки раз, и одно
// число обслужить оба случая не может: тесное окно даёт лишние попытки TCP там,
// где QUIC просто не успел поздороваться, а широкое заставляет застрявший QUIC
// ждать страховки непозволительно долго — и это как раз случай БЛИЗКОГО
// сервера, где всё остальное укладывается в миллисекунды.
//
// Поэтому окно считается от измеренного: держим по хосту скользящее среднее
// длительности рукопожатия и берём его с запасом. Пока измерений нет — окно
// максимальное, то есть заведомо безопасное.
// ===========================================================================
#define OKNO_SOED_MIN_MS 150
#define OKNO_SOED_MAX_MS 700
#define OKNO_SOED_ZAPAS 2       // во столько раз окно шире среднего рукопожатия
#define ZAMEROV_HOSTOV 8

typedef struct ZamerHosta {
    char host[256];
    unsigned long srednee;   // скользящее среднее рукопожатия, мс
    int est;
} ZamerHosta;

static ZamerHosta g_Zamery[ZAMEROV_HOSTOV];
static CRITICAL_SECTION g_ZameryLock;
static volatile long g_ZameryReady = 0;

static void ZameryInitOnce(void) {
    if (__sync_bool_compare_and_swap(&g_ZameryReady, 0, 1)) {
        InitializeCriticalSection(&g_ZameryLock);
        for (int i = 0; i < ZAMEROV_HOSTOV; i++) { g_Zamery[i].host[0] = 0; g_Zamery[i].est = 0; }
        __sync_bool_compare_and_swap(&g_ZameryReady, 1, 2);
    }
    while (g_ZameryReady != 2) { Sleep(1); }
}

// Скользящее среднее с весом 1/4 у нового замера: реагирует на смену сети, но
// не дёргается от одиночного выброса.
static void ZapomnitRukopozhatie(const char* host, unsigned long ms) {
    if (!host || !host[0]) return;
    ZameryInitOnce();
    EnterCriticalSection(&g_ZameryLock);
    int svobodnyy = -1;
    for (int i = 0; i < ZAMEROV_HOSTOV; i++) {
        if (g_Zamery[i].est && MyStrCmp(g_Zamery[i].host, host) == 0) {
            g_Zamery[i].srednee = (g_Zamery[i].srednee * 3 + ms) / 4;
            LeaveCriticalSection(&g_ZameryLock);
            return;
        }
        if (!g_Zamery[i].est && svobodnyy < 0) svobodnyy = i;
    }
    if (svobodnyy < 0) svobodnyy = 0;   // таблица полна: вытесняем первую запись
    MyStrCopy(g_Zamery[svobodnyy].host, sizeof(g_Zamery[svobodnyy].host), host);
    g_Zamery[svobodnyy].srednee = ms;
    g_Zamery[svobodnyy].est = 1;
    LeaveCriticalSection(&g_ZameryLock);
}

static unsigned long OknoSoedineniya(const char* host) {
    if (!host || !host[0]) return OKNO_SOED_MAX_MS;
    ZameryInitOnce();
    unsigned long okno = OKNO_SOED_MAX_MS;
    EnterCriticalSection(&g_ZameryLock);
    for (int i = 0; i < ZAMEROV_HOSTOV; i++) {
        if (g_Zamery[i].est && MyStrCmp(g_Zamery[i].host, host) == 0) {
            okno = g_Zamery[i].srednee * OKNO_SOED_ZAPAS;
            break;
        }
    }
    LeaveCriticalSection(&g_ZameryLock);
    if (okno < OKNO_SOED_MIN_MS) okno = OKNO_SOED_MIN_MS;
    if (okno > OKNO_SOED_MAX_MS) okno = OKNO_SOED_MAX_MS;
    return okno;
}

static volatile long g_OtkrytyhPotokov = 0;   // диагностика: живых потоков запросов
static Http3Conn* g_Pool[HTTP3_POOL_SIZE];
static CRITICAL_SECTION g_PoolLock;
static volatile long g_PoolReady = 0;

static void PoolInitOnce(void) {
    if (__sync_bool_compare_and_swap(&g_PoolReady, 0, 1)) {
        InitializeCriticalSection(&g_PoolLock);
        for (int i = 0; i < HTTP3_POOL_SIZE; i++) g_Pool[i] = NULL;
        __sync_bool_compare_and_swap(&g_PoolReady, 1, 2);
    }
    while (g_PoolReady != 2) { Sleep(1); }
}

static void PoolCloseConn(Http3Conn* c) {
    if (!c) return;
    LogHexVal("Пул: закрываю соединение", (unsigned long)(size_t)c);
    if (c->connection && c->api) {
        c->api->ConnectionShutdown(c->connection, QUIC_CONNECTION_SHUTDOWN_FLAG_SILENT, 0);
        c->api->ConnectionClose(c->connection);
    }
    HeapFree(GetProcessHeap(), 0, c);
}

static Http3Conn* PoolTake(const char* host, int port) {
    PoolInitOnce();
    Http3Conn* nash = NULL;
    unsigned long teper = GetTickCount();
    EnterCriticalSection(&g_PoolLock);
    for (int i = 0; i < HTTP3_POOL_SIZE; i++) {
        Http3Conn* c = g_Pool[i];
        if (!c) continue;
        if (c->mertvo || (teper - c->poslednee) > HTTP3_CONN_IDLE_MS) {
            if (!c->zanyat) { g_Pool[i] = NULL; LeaveCriticalSection(&g_PoolLock); PoolCloseConn(c); EnterCriticalSection(&g_PoolLock); }
            continue;
        }
        if (!nash && c->gotovo && !c->zanyat && c->port == port && MyStrCmp(c->host, host) == 0) {
            c->zanyat = 1;
            c->prostoy = teper - c->poslednee;   // ДО обновления метки
            c->poslednee = teper;
            nash = c;
        }
    }
    LeaveCriticalSection(&g_PoolLock);
    // Адрес соединения в журнале: по нему видно, не выдали ли одно и то же
    // соединение двум запросам разом, пока первый ещё не ответил.
    if (nash) LogHexVal("Пул: НАЙДЕНО тёплое соединение", (unsigned long)(size_t)nash);
    else LogMsg("Пул: тёплого соединения нет");
    return nash;
}

static void PoolReturn(Http3Conn* c) {
    if (!c) return;
    PoolInitOnce();
    c->poslednee = GetTickCount();
    c->zanyat = 0;
    if (c->mertvo) {
        LogMsg("Пул: соединение мёртво, не сохраняю");
        EnterCriticalSection(&g_PoolLock);
        for (int i = 0; i < HTTP3_POOL_SIZE; i++) if (g_Pool[i] == c) g_Pool[i] = NULL;
        LeaveCriticalSection(&g_PoolLock);
        PoolCloseConn(c);
        return;
    }
    EnterCriticalSection(&g_PoolLock);
    for (int i = 0; i < HTTP3_POOL_SIZE; i++) if (g_Pool[i] == c) { LeaveCriticalSection(&g_PoolLock); LogHexVal("Пул: соединение ОСВОБОЖДЕНО", (unsigned long)(size_t)c); return; }
    for (int i = 0; i < HTTP3_POOL_SIZE; i++) if (!g_Pool[i]) { g_Pool[i] = c; LeaveCriticalSection(&g_PoolLock); LogHexVal("Пул: соединение СОХРАНЕНО", (unsigned long)(size_t)c); return; }
    LeaveCriticalSection(&g_PoolLock);
    LogMsg("Пул: полон, соединение закрываю");
    PoolCloseConn(c);
}

static long __cdecl RequestStreamCallback(HQUIC Stream, void* Context, QUIC_STREAM_EVENT* Event) {
    (void)Stream;
    Http3State* state = (Http3State*)Context;
    LogHexVal("RequestStreamCallback: Event->Type", Event->Type);
    switch (Event->Type) {
        case QUIC_STREAM_EVENT_RECEIVE: {
            for (uint32_t i = 0; i < Event->RECEIVE.BufferCount; i++) {
                GrowBufferAppend(&state->streamAccum, &state->streamAccumLen, &state->streamAccumCap,
                                  Event->RECEIVE.Buffers[i].Buffer, (int)Event->RECEIVE.Buffers[i].Length);
            }
            // Проверяем наличие флага FIN в самом событии приёма данных.
            // Сервера HTTP/3 (например, Cloudflare) могут передавать FIN вместе с последним кадром данных,
            // не вызывая отдельное событие QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN.
            if (Event->RECEIVE.Flags & QUIC_RECEIVE_FLAG_FIN) {
                LogMsg("RequestStreamCallback: RECEIVE с флагом FIN (ответ HTTP/3 полностью получен)");
                if (!state->success) {
                    ParseHttp3ResponseStream(state->streamAccum, state->streamAccumLen, &state->status,
                                              &state->respBody, &state->respBodyLen, &state->respBodyCap);
                    __sync_bool_compare_and_swap(&state->success, 0, 1);
                    if (state->doneEvent) SetEvent(state->doneEvent);
                }
            }
            break;
        }
        case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN: {
            LogMsg("RequestStreamCallback: PEER_SEND_SHUTDOWN (ответ принят)");
            if (!state->success) {
                ParseHttp3ResponseStream(state->streamAccum, state->streamAccumLen, &state->status,
                                          &state->respBody, &state->respBodyLen, &state->respBodyCap);
                __sync_bool_compare_and_swap(&state->success, 0, 1);
                if (state->doneEvent) SetEvent(state->doneEvent);
            }
            break;
        }
        case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE: {
            LogMsg("RequestStreamCallback: SHUTDOWN_COMPLETE");
            if (!state->success) {
                __sync_bool_compare_and_swap(&state->failed, 0, 1);
                if (state->doneEvent) SetEvent(state->doneEvent);
            }
            break;
        }
        default: break;
    }
    return 0;
}

// Отправка запроса по ГОТОВОМУ соединению. Нужна в двух местах: сразу после
// рукопожатия (холодный путь) и на соединении из пула (тёплый, без рукопожатия).
static void Http3OtpravitZapros(Http3Conn* c, Http3State* state, int tyoploe) {
    QUIC_API_TABLE* api = c->api;
    AsyncRequestContext* req = state->req;
    void* heap = GetProcessHeap();

    char* authority = (char*)HeapAlloc(heap, 0, 300);
    if (state->port == 443) MyStrCopy(authority, 300, state->host);
    else {
        MyStrCopy(authority, 300, state->host);
        int al = MyStrLen(authority);
        authority[al++] = ':';
        MyIntToStr(state->port, authority + al);
    }

    uint8_t* headersPayload = (uint8_t*)HeapAlloc(heap, 0, 3072);
    int hlen = QpackEncodeRequestHeaders(headersPayload, req->method, state->path,
                                          authority, "Solar2D-HTTP3-Plugin/1.0", req->headers);
    HeapFree(heap, 0, authority);

    state->sendBuf = (uint8_t*)HeapAlloc(heap, 0, 4096 + req->body_len + 16);
    int pos = WriteHttp3Frame(state->sendBuf, HTTP3_FRAME_HEADERS, headersPayload, hlen);
    HeapFree(heap, 0, headersPayload);
    int dataPos = pos;
    if (req->body_len > 0) {
        // Именно +=, а не =. WriteHttp3Frame возвращает длину СВОЕГО кадра, а
        // не смещение в буфере. При присваивании pos становился длиной кадра
        // тела, и длина второго буфера считалась как (тело - заголовки). У
        // запросов с коротким телом разность отрицательна, в uint32_t это ~4
        // млрд, MsQuic ловит переполнение суммы длин и отвечает
        // QUIC_STATUS_INVALID_PARAMETER (0x80070057). Из-за этого HTTP/3 не
        // работал НИ ДЛЯ ОДНОГО запроса с телом: все POST молча уходили на
        // запасной HTTP/1.1. Заголовки обычно длиннее короткого тела, поэтому
        // разность уходила в минус почти всегда.
        pos += WriteHttp3Frame(state->sendBuf + pos, HTTP3_FRAME_DATA, (const uint8_t*)req->body, req->body_len);
    }

    long sOpen = api->StreamOpen(c->connection, QUIC_STREAM_OPEN_FLAG_NONE, RequestStreamCallback, state, &state->requestStream);
    LogHexVal("Http3OtpravitZapros: соединение", (unsigned long)(size_t)c);
    LogHexVal("Http3OtpravitZapros: StreamOpen", (unsigned long)sOpen);
    if (sOpen == 0) __sync_add_and_fetch(&g_OtkrytyhPotokov, 1);
    LogHexVal("  живых потоков запросов", (unsigned long)g_OtkrytyhPotokov);
    if (sOpen == 0) {
        uint32_t bufCount;
        if (req->body_len > 0) {
            state->sendBuffers[0].Length = (uint32_t)dataPos; state->sendBuffers[0].Buffer = state->sendBuf;
            state->sendBuffers[1].Length = (uint32_t)(pos - dataPos); state->sendBuffers[1].Buffer = state->sendBuf + dataPos;
            bufCount = 2;
        } else {
            state->sendBuffers[0].Length = (uint32_t)pos; state->sendBuffers[0].Buffer = state->sendBuf;
            bufCount = 1;
        }
        long sSend = api->StreamSend(state->requestStream, state->sendBuffers, bufCount, QUIC_SEND_FLAG_START | QUIC_SEND_FLAG_FIN, NULL);
        // Метка пути и возраст соединения — чтобы по журналу понять, отказы
        // приходятся на тёплые соединения или на холодные, и связаны ли они с
        // тем, сколько соединение простояло.
        LogHexVal(tyoploe ? "StreamSend[тёплое]" : "StreamSend[холодное]", (unsigned long)sSend);
        if (tyoploe) LogHexVal("  простой перед выдачей, мс", c->prostoy);
    } else {
        LogMsg("Http3OtpravitZapros: StreamOpen не удался, соединение помечено мёртвым");
        c->mertvo = 1;
        __sync_bool_compare_and_swap(&state->failed, 0, 1);
        if (state->doneEvent) SetEvent(state->doneEvent);
    }
}

// Колбэк СОЕДИНЕНИЯ. Контекст — Http3Conn, а не запрос: соединение живёт дольше
// запроса, и держать запрос в контексте значило бы обращаться к освобождённой
// памяти после его завершения.
static long __cdecl ConnectionCallback(HQUIC Connection, void* Context, QUIC_CONNECTION_EVENT* Event) {
    Http3Conn* c = (Http3Conn*)Context;
    QUIC_API_TABLE* api = c->api;
    LogHexVal("ConnectionCallback: Event->Type", Event->Type);
    switch (Event->Type) {
        case QUIC_CONNECTION_EVENT_CONNECTED: {
            LogMsg("Http3ThreadFunc: QUIC handshake завершён (CONNECTED)");
            // Стоимость рукопожатия до этого хоста — основание для первого окна
            // гонки (см. ZapomnitRukopozhatie).
            if (c->nachalo_rukopozhatiya) {
                unsigned long ushlo = GetTickCount() - c->nachalo_rukopozhatiya;
                c->nachalo_rukopozhatiya = 0;   // повторно на том же соединении не считаем
                ZapomnitRukopozhatie(c->host, ushlo);
                LogHexVal("  рукопожатие, мс", ushlo);
            }
            Http3State* pend = c->ozhidayushchiy;
            LogMsg(pend ? "ConnectionCallback: ожидающий запрос ЕСТЬ" : "ConnectionCallback: ожидающего запроса НЕТ");
            if (pend && pend->race) {
                pend->race->quicProgress = 1;
                if (pend->race->quicDoneEvent) SetEvent(pend->race->quicDoneEvent);
            }
            LogMsg("ConnectionCallback: отправка HTTP/3 SETTINGS (один раз на соединение)");
            {
                int pos = WriteQuicVarint(c->ctrlBuf, HTTP3_STREAM_CONTROL);
                pos += WriteHttp3Frame(c->ctrlBuf + pos, HTTP3_FRAME_SETTINGS, NULL, 0);
                if (api->StreamOpen(Connection, QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL, NoopStreamCallback, NULL, &c->ctrlStream) == 0) {
                    c->ctrlSendBuf.Length = (uint32_t)pos;
                    c->ctrlSendBuf.Buffer = c->ctrlBuf;
                    api->StreamSend(c->ctrlStream, &c->ctrlSendBuf, 1, QUIC_SEND_FLAG_START, NULL);
                }
                int p1 = WriteQuicVarint(c->encoderBuf, HTTP3_STREAM_QPACK_ENCODER);
                if (api->StreamOpen(Connection, QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL, NoopStreamCallback, NULL, &c->encoderStream) == 0) {
                    c->encoderSendBuf.Length = (uint32_t)p1;
                    c->encoderSendBuf.Buffer = c->encoderBuf;
                    api->StreamSend(c->encoderStream, &c->encoderSendBuf, 1, QUIC_SEND_FLAG_START, NULL);
                }
                int p2 = WriteQuicVarint(c->decoderBuf, HTTP3_STREAM_QPACK_DECODER);
                if (api->StreamOpen(Connection, QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL, NoopStreamCallback, NULL, &c->decoderStream) == 0) {
                    c->decoderSendBuf.Length = (uint32_t)p2;
                    c->decoderSendBuf.Buffer = c->decoderBuf;
                    api->StreamSend(c->decoderStream, &c->decoderSendBuf, 1, QUIC_SEND_FLAG_START, NULL);
                }
            }
            c->gotovo = 1;
            if (pend) Http3OtpravitZapros(c, pend, 0);
            break;
        }
        case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT: {
            LogHexVal("Http3: SHUTDOWN_INITIATED_BY_TRANSPORT Status", (unsigned long)Event->SHUTDOWN_INITIATED_BY_TRANSPORT.Status);
            LogHexVal("Http3: SHUTDOWN_INITIATED_BY_TRANSPORT ErrorCode", (unsigned long)Event->SHUTDOWN_INITIATED_BY_TRANSPORT.ErrorCode);
            c->mertvo = 1;
            { Http3State* s = c->ozhidayushchiy;
              if (s) { __sync_bool_compare_and_swap(&s->failed, 0, 1); if (s->doneEvent) SetEvent(s->doneEvent); } }
            break;
        }
        case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER: {
            LogHexVal("Http3: SHUTDOWN_INITIATED_BY_PEER ErrorCode", (unsigned long)Event->SHUTDOWN_INITIATED_BY_PEER.ErrorCode);
            c->mertvo = 1;
            { Http3State* s = c->ozhidayushchiy;
              if (s) { __sync_bool_compare_and_swap(&s->failed, 0, 1); if (s->doneEvent) SetEvent(s->doneEvent); } }
            break;
        }
        case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE: {
            LogMsg("ConnectionCallback: SHUTDOWN_COMPLETE получен от MsQuic");
            c->mertvo = 1;
            { Http3State* s = c->ozhidayushchiy;
              if (s) { s->shutdownComplete = 1; if (s->shutdownEvent) SetEvent(s->shutdownEvent); } }
            break;
        }
        case QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED: {
            api->SetCallbackHandler(Event->PEER_STREAM_STARTED.Stream, (void*)NoopStreamCallback, NULL);
            break;
        }
        default: break;
    }
    return 0;
}
static HMODULE g_hMsQuicModule = NULL;
static QUIC_API_TABLE* g_MsQuicApiTable = NULL;
static HQUIC g_MsQuicRegistration = NULL;
static HQUIC g_MsQuicConfiguration = NULL;

static QUIC_API_TABLE* GetGlobalMsQuicApi() {
    if (g_MsQuicApiTable && g_MsQuicRegistration && g_MsQuicConfiguration) return g_MsQuicApiTable;
    EnterCriticalSection(&g_CritSec);
    if (!g_MsQuicApiTable) {
        g_hMsQuicModule = LoadLibraryA("msquic.dll");
        if (!g_hMsQuicModule) g_hMsQuicModule = LoadLibraryA("msquic_winuser.dll");
        if (!g_hMsQuicModule) {
            char dllPath[MAX_PATH];
            HMODULE hSelf = NULL;
            GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)&GetGlobalMsQuicApi, &hSelf);
            if (hSelf && GetModuleFileNameA(hSelf, dllPath, MAX_PATH)) {
                int len = MyStrLen(dllPath);
                while (len > 0 && dllPath[len - 1] != '\\' && dllPath[len - 1] != '/') len--;
                if (len < MAX_PATH - 12) {
                    MyStrCopy(dllPath + len, MAX_PATH - len, "msquic.dll");
                    g_hMsQuicModule = LoadLibraryA(dllPath);
                }
            }
        }
        if (g_hMsQuicModule) {
            MsQuicOpenVersionFn openFn = (MsQuicOpenVersionFn)GetProcAddress(g_hMsQuicModule, "MsQuicOpenVersion");
            if (openFn) {
                openFn(QUIC_API_VERSION_2, (const void**)&g_MsQuicApiTable);
            }
        }
    }

    if (g_MsQuicApiTable && !g_MsQuicRegistration) {
        QUIC_REGISTRATION_CONFIG regConfig = { "Solar2DHTTP3", QUIC_EXECUTION_PROFILE_LOW_LATENCY };
        g_MsQuicApiTable->RegistrationOpen(&regConfig, &g_MsQuicRegistration);
    }

    if (g_MsQuicRegistration && !g_MsQuicConfiguration) {
        QUIC_BUFFER alpn; alpn.Length = 2; alpn.Buffer = (uint8_t*)"h3";
        QUIC_SETTINGS settings;
        memset(&settings, 0, sizeof(settings));
        settings.PeerBidiStreamCount = 100;
        settings.IsSet.PeerBidiStreamCount = 1;
        settings.PeerUnidiStreamCount = 100;
        settings.IsSet.PeerUnidiStreamCount = 1;
        // ТАЙМАУТ ПРОСТОЯ СОЕДИНЕНИЯ, а не запроса. Раньше сюда подставлялся
        // HTTP3_REQUEST_TIMEOUT_MS (3с) — два разных понятия были смешаны в
        // одно. Пока соединение жило ровно один запрос, разницы не было; с
        // пулом она стала решающей: после трёх секунд паузы транспорт закрывал
        // соединение, StreamOpen (он локальный) проходил, а StreamSend отдавал
        // 0x80070057. В журнале это дало 9 отказов на 37 отправок.
        settings.IdleTimeoutMs = HTTP3_IDLE_TIMEOUT_MS;
        settings.IsSet.IdleTimeoutMs = 1;

        if (g_MsQuicApiTable->ConfigurationOpen(g_MsQuicRegistration, &alpn, 1, &settings, sizeof(settings), NULL, &g_MsQuicConfiguration) == 0) {
            QUIC_CREDENTIAL_CONFIG cred;
            memset(&cred, 0, sizeof(cred));
            cred.Type = QUIC_CREDENTIAL_TYPE_NONE;
            cred.Flags = QUIC_CREDENTIAL_FLAG_CLIENT;
            g_MsQuicApiTable->ConfigurationLoadCredential(g_MsQuicConfiguration, &cred);
        }
    }

    LeaveCriticalSection(&g_CritSec);
    return g_MsQuicApiTable;
}

static unsigned long __stdcall Http1ThreadFunc(void* param);

static unsigned long __stdcall Http3ThreadFunc(void* param) {
    RaceContext* race = (RaceContext*)param;
    AsyncRequestContext* req = race->req;
    LogMsg("Http3ThreadFunc: запуск (MsQuic)");

    char host[256]; int port = 0; char path[1024]; int secure = 0;
    if (!ParseUrl(req->url, host, sizeof(host), &port, path, sizeof(path), &secure) || !secure) {
        RaceFinish(race, RACE_FAILURE, 0, NULL, 0, NULL, "HTTP/3 requires https URL");
        // При несовместимости с HTTP/3 передаем выполнение в HTTP/1.1
        __sync_add_and_fetch(&race->refCount, 1);
        HANDLE hHttp1 = CreateThread(NULL, 64 * 1024, Http1ThreadFunc, race, STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
        if (hHttp1) CloseHandle(hHttp1);
        else ReleaseRaceContext(race);

        ReleaseRaceContext(race);
        return 0;
    }

    QUIC_API_TABLE* api = GetGlobalMsQuicApi();
    if (!api || !g_MsQuicRegistration || !g_MsQuicConfiguration) {
        LogMsg("Http3ThreadFunc: msquic.dll / MsQuicOpenVersion недоступен, фоллбэк на TCP HTTP/1.1");
        RaceFinish(race, RACE_FAILURE, 0, NULL, 0, NULL, "msquic.dll not available");

        __sync_add_and_fetch(&race->refCount, 1);
        HANDLE hHttp1 = CreateThread(NULL, 64 * 1024, Http1ThreadFunc, race, STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
        if (hHttp1) CloseHandle(hHttp1);
        else ReleaseRaceContext(race);

        ReleaseRaceContext(race);
        return 0;
    }

    void* heap = GetProcessHeap();
    Http3State* state = (Http3State*)HeapAlloc(heap, 0, sizeof(Http3State));
    memset(state, 0, sizeof(Http3State));
    state->api = api;
    state->req = req;
    state->race = race;
    state->port = port;
    MyStrCopy(state->host, sizeof(state->host), host);
    MyStrCopy(state->path, sizeof(state->path), path);
    state->doneEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    state->shutdownEvent = CreateEventA(NULL, TRUE, FALSE, NULL);

    // HRESULT-семантика: успех — это (status >= 0), а не только 0.
#define QUIC_OK(x) (((long)(x)) >= 0)

    // ТЁПЛЫЙ ПУТЬ: к этому хосту уже есть открытое свободное соединение —
    // рукопожатия не будет вовсе, сразу открываем поток и шлём запрос.
    Http3Conn* conn = PoolTake(host, port);
    long st = 0;
    if (conn) {
        LogMsg("Http3ThreadFunc: соединение взято из пула (без рукопожатия)");
        LogHexVal("  занято ли соединение", (unsigned long)conn->zanyat);
        conn->ozhidayushchiy = state;
        state->connection = conn->connection;
        if (race) {
            race->quicProgress = 1;
            if (race->quicDoneEvent) SetEvent(race->quicDoneEvent);
        }
        Http3OtpravitZapros(conn, state, 1);
    } else {
        // ХОЛОДНЫЙ ПУТЬ: создаём соединение и запоминаем его для следующих
        // запросов. Контекст колбэка — соединение, не запрос.
        LogMsg("Http3ThreadFunc: создаю новое соединение");
        conn = (Http3Conn*)HeapAlloc(heap, 0, sizeof(Http3Conn));
        memset(conn, 0, sizeof(Http3Conn));
        conn->api = api;
        conn->port = port;
        conn->zanyat = 1;
        conn->poslednee = GetTickCount();
        conn->ozhidayushchiy = state;
        MyStrCopy(conn->host, sizeof(conn->host), host);

        conn->nachalo_rukopozhatiya = GetTickCount();
        st = api->ConnectionOpen(g_MsQuicRegistration, ConnectionCallback, conn, &conn->connection);
        LogHexVal("ConnectionOpen", st);
        state->connection = conn->connection;

        if (QUIC_OK(st)) {
            st = api->ConnectionStart(conn->connection, g_MsQuicConfiguration, QUIC_ADDRESS_FAMILY_UNSPEC, host, (uint16_t)port);
            LogHexVal("ConnectionStart", st);
        }
        if (!QUIC_OK(st)) { conn->mertvo = 1; }
    }

    if (QUIC_OK(st)) {
        // Ожидаем завершения QUIC-запроса интервалами по 50 мс.
        // Если через 250 мс QUIC не установил соединение, запускаем параллельный TCP поток (Happy Eyeballs v3).
        DWORD elapsed = 0;
        BOOL tcpSpawned = FALSE;
        while (elapsed < (DWORD)req->timeout_ms) {
            DWORD waitRes = WaitForSingleObject(state->doneEvent, 50);
            if (waitRes == WAIT_OBJECT_0) break;
            elapsed += 50;
            if (race->winnerAssigned != 0 && race->winnerAssigned != 1) {
                LogMsg("Http3ThreadFunc: TCP победил по Happy Eyeballs v3, досрочный выход из ожидания QUIC");
                __sync_bool_compare_and_swap(&state->failed, 0, 1);
                break;
            }
        }
        LogHexVal("state->success", state->success);
        LogHexVal("state->failed", state->failed);
    }
#undef QUIC_OK

    RaceOutcome outcome;
    if (!state->success) outcome = RACE_FAILURE;
    else outcome = RACE_SUCCESS;

    if (outcome == RACE_SUCCESS) {
        LogMsg("Http3ThreadFunc: успешный ответ по MsQuic/HTTP3 (QUIC победил по Happy Eyeballs v3)");
        RaceFinish(race, RACE_SUCCESS, state->status, (const char*)state->respBody, state->respBodyLen, "MsQuic/HTTP3", NULL);
    } else {
        // Различаем ПРОИГРЫШ В ГОНКЕ и настоящий сбой: раньше и то и другое
        // писалось как «сбой транспорта», хотя в журнале рядом стояло
        // «handshake завершён» и «StreamSend отправлен успешно» — QUIC
        // отработал, просто TCP успел раньше. По такому журналу нельзя было
        // отличить исправный QUIC от сломанного.
        if (race->winnerAssigned == 2) {
            LogMsg("Http3ThreadFunc: QUIC исправен, но проиграл гонку TCP (это не сбой)");
        } else {
            LogMsg("Http3ThreadFunc: сбой транспорта MsQuic/HTTP3");
        }
        RaceFinish(race, RACE_FAILURE, 0, NULL, 0, "Error", "MsQuic/HTTP3 transport failed");
    }

    LogMsg("Http3ThreadFunc: начало очистки MsQuic объектов сессии...");

    // МsQuic-безопасная очистка:
    // 1) Тихий shutdown (не отправляет CONNECTION_CLOSE кадр) +
    //    ожидание колбэка SHUTDOWN_COMPLETE от MsQuic, гарантирующего,
    //    что все колбэки потоков/соединения завершены.
    // 2) ConnectionClose — автоматически закрывает все дочерние потоки.
    // СОЕДИНЕНИЕ НЕ ЗАКРЫВАЕМ — возвращаем в пул для следующего запроса.
    // Закроется само: по простою (HTTP3_CONN_IDLE_MS) либо когда MsQuic сообщит
    // о его смерти (тогда PoolReturn закроет сразу).
    // ОСВОБОЖДАЕМ ПОТОК ЗАПРОСА. Раньше StreamClose не вызывался нигде, и это
    // не было заметно: соединение закрывалось после каждого запроса и забирало
    // свои потоки с собой. С пулом соединение живёт дальше, потоки копятся и
    // упираются в предел одновременных — StreamSend начинает возвращать
    // 0x80070057 (E_INVALIDARG). В журнале это дало 43 отказа на 109 запросов,
    // и ровно столько же раз выигрывал запасной TCP.
    //
    // Закрываем ЗДЕСЬ, из потока-владельца, а не из колбэка потока: StreamClose
    // дожидается завершения колбэков, и делать это до освобождения state —
    // единственный порядок, при котором колбэк не обратится к освобождённой
    // памяти.
    if (state->requestStream) {
        api->StreamClose(state->requestStream);
        state->requestStream = NULL;
        __sync_add_and_fetch(&g_OtkrytyhPotokov, -1);
    }
    if (conn) {
        conn->ozhidayushchiy = NULL;
        PoolReturn(conn);
    }
    state->connection = NULL;
    state->ctrlStream = NULL;
    state->encoderStream = NULL;
    state->decoderStream = NULL;

    // Освобождение ресурсов Win32 и памяти кучи
    if (state->doneEvent) CloseHandle(state->doneEvent);
    if (state->shutdownEvent) CloseHandle(state->shutdownEvent);
    if (state->streamAccum) HeapFree(heap, 0, state->streamAccum);
    if (state->respBody) HeapFree(heap, 0, state->respBody);
    if (state->sendBuf) HeapFree(heap, 0, state->sendBuf);
    HeapFree(heap, 0, state);

    LogMsg("Http3ThreadFunc: сессия MsQuic успешно завершена.");
    ReleaseRaceContext(race);
    return 0;
}

// ===========================================================================
// ===========================================================================
// WinHttp-клиент (Http1ThreadFunc) — надёжный TCP/HTTP1.1-путь гонки.
// ===========================================================================
static HINTERNET g_hWinHttpSession = NULL;

static HINTERNET GetGlobalWinHttpSession() {
    if (g_hWinHttpSession) return g_hWinHttpSession;
    EnterCriticalSection(&g_CritSec);
    if (!g_hWinHttpSession) {
        g_hWinHttpSession = WinHttpOpen(L"Solar2D-HTTP3-Plugin/1.0", 0, NULL, NULL, 0);
        if (g_hWinHttpSession) {
            WinHttpSetTimeouts(g_hWinHttpSession, HTTP3_REQUEST_TIMEOUT_MS, HTTP3_REQUEST_TIMEOUT_MS,
                               HTTP3_REQUEST_TIMEOUT_MS, HTTP3_REQUEST_TIMEOUT_MS);
        }
    }
    LeaveCriticalSection(&g_CritSec);
    return g_hWinHttpSession;
}

static unsigned long __stdcall Http1ThreadFunc(void* param) {
    RaceContext* race = (RaceContext*)param;
    AsyncRequestContext* req = race->req;
    LogMsg("Http1ThreadFunc: Фоновый поток успешно запущен");

    if (race->winnerAssigned) {
        LogMsg("Http1ThreadFunc: MsQuic/HTTP3 уже победил, пропускаем WinHttp");
        RaceFinish(race, RACE_SKIPPED, 0, NULL, 0, NULL, NULL);
        ReleaseRaceContext(race);
        return 0;
    }

    char host[256];
    int port = 80;
    char path[1024];
    int secure = 0;

    if (!ParseUrl(req->url, host, sizeof(host), &port, path, sizeof(path), &secure)) {
        RaceFinish(race, RACE_FAILURE, 0, NULL, 0, NULL, "Невалидный URL");
        ReleaseRaceContext(race);
        return 0;
    }

    HINTERNET hSession = GetGlobalWinHttpSession();
    if (!hSession) {
        LogMsg("Http1ThreadFunc: WinHttpOpen failed");
        RaceFinish(race, RACE_FAILURE, 0, NULL, 0, NULL, "WinHttpOpen failed");
        ReleaseRaceContext(race);
        return 0;
    }

    wchar_t w_host[256];
    AnsiToWide(host, w_host, 256);
    HINTERNET hConnect = WinHttpConnect(hSession, w_host, (INTERNET_PORT)port, 0);
    if (!hConnect) {
        RaceFinish(race, RACE_FAILURE, 0, NULL, 0, NULL, "WinHttpConnect failed");
        ReleaseRaceContext(race);
        return 0;
    }

    wchar_t w_method[16];
    AnsiToWide(req->method, w_method, 16);
    wchar_t w_path[1024];
    AnsiToWide(path, w_path, 1024);

    unsigned long req_flags = secure ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hRequest = WinHttpOpenRequest(hConnect, w_method, w_path, NULL, NULL, NULL, req_flags);
    if (!hRequest) {
        WinHttpCloseHandle(hConnect);
        RaceFinish(race, RACE_FAILURE, 0, NULL, 0, NULL, "WinHttpOpenRequest failed");
        ReleaseRaceContext(race);
        return 0;
    }

    // Таймауты у сессии WinHTTP общие на все запросы, поэтому таймаут ЭТОГО
    // запроса ставим на его собственный дескриптор. Иначе запасной TCP-путь
    // продолжал бы жить по зашитой константе и обрывал бы долгие запросы,
    // которым вызывающий разрешил больше.
    WinHttpSetTimeouts(hRequest, req->timeout_ms, req->timeout_ms,
                       req->timeout_ms, req->timeout_ms);

    wchar_t w_headers[1024];
    w_headers[0] = L'\0';
    if (req->headers[0]) {
        AnsiToWide(req->headers, w_headers, 1024);
    }

    if (race->winnerAssigned) {
        LogMsg("Http1ThreadFunc: MsQuic/HTTP3 победил перед отправкой запроса, прерываем");
        WinHttpCloseHandle(hRequest);
        WinHttpCloseHandle(hConnect);
        RaceFinish(race, RACE_SKIPPED, 0, NULL, 0, NULL, NULL);
        ReleaseRaceContext(race);
        return 0;
    }

    LogMsg("Http1ThreadFunc: WinHttpSendRequest...");
    int send_res = WinHttpSendRequest(
        hRequest,
        w_headers[0] ? w_headers : NULL,
        w_headers[0] ? (unsigned long)MyStrLenW(w_headers) : 0,
        req->body_len > 0 ? req->body : NULL,
        (unsigned long)req->body_len,
        (unsigned long)req->body_len,
        0
    );

    if (!send_res || !WinHttpReceiveResponse(hRequest, NULL)) {
        WinHttpCloseHandle(hRequest);
        WinHttpCloseHandle(hConnect);
        RaceFinish(race, RACE_FAILURE, 0, NULL, 0, NULL, "WinHttp Send/Receive failed");
        ReleaseRaceContext(race);
        return 0;
    }

    const char* transport_name = "HTTP/1.1";

    wchar_t w_status[16];
    unsigned long w_status_len = sizeof(w_status);
    int status_val = 0;
    if (WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_STATUS_CODE, NULL, w_status, &w_status_len, NULL)) {
        int s_idx = 0;
        while (w_status[s_idx] >= L'0' && w_status[s_idx] <= L'9') {
            status_val = status_val * 10 + (w_status[s_idx] - L'0');
            s_idx++;
        }
    }

    void* heap = GetProcessHeap();
    char* resp_buf = NULL;
    int resp_cap = 4096;
    int resp_len = 0;
    resp_buf = (char*)HeapAlloc(heap, 0, resp_cap);

    unsigned long bytes_read = 0;
    char read_buf[512];
    while (WinHttpReadData(hRequest, read_buf, sizeof(read_buf), &bytes_read) && bytes_read > 0) {
        if (resp_len + (int)bytes_read >= resp_cap) {
            resp_cap *= 2;
            char* new_buf = (char*)HeapAlloc(heap, 0, resp_cap);
            for (int i = 0; i < resp_len; i++) new_buf[i] = resp_buf[i];
            HeapFree(heap, 0, resp_buf);
            resp_buf = new_buf;
        }
        for (unsigned long i = 0; i < bytes_read; i++) {
            resp_buf[resp_len++] = read_buf[i];
        }
    }
    resp_buf[resp_len] = '\0';
    LogMsg("Http1ThreadFunc: Тело ответа успешно считано, проверка статуса QUIC по draft-ietf-happy-happyeyeballs-v3...");

    race->tcpSuccess = 1;
    race->tcpFinished = 1;

    // Согласно draft-ietf-happy-happyeyeballs-v3:
    // Вторичное TCP-подключение при получении ответа УДЕРЖИВАЕТ свой результат и ждёт
    // завершения первичного QUIC-подключения (если оно ещё выполняется in-flight).
    if (race->quicFinished == 0) {
        LogMsg("Http1ThreadFunc: QUIC в процессе (in-flight), ожидание QUIC (окно приоритета 50 мс)...");
        if (race->quicDoneEvent) {
            WaitForSingleObject(race->quicDoneEvent, 50);
        }
    }

    if (race->quicSuccess == 1 || race->winnerAssigned == 1) {
        LogMsg("Http1ThreadFunc: QUIC успешно завершился (QUIC победил по Happy Eyeballs v3), отменяем TCP результат");
    } else {
        LogMsg("Http1ThreadFunc: QUIC дал сбой или таймаут, TCP побеждает по Happy Eyeballs v3");
        if (__sync_bool_compare_and_swap(&race->winnerAssigned, 0, 2)) {
            AddResult(race->req->id, 0, status_val, resp_buf, resp_len, transport_name);
        }
    }

    HeapFree(heap, 0, resp_buf);
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    ReleaseRaceContext(race);
    return 0;
}

// ===========================================================================
// Оркестратор гонки Happy Eyeballs v3 (draft-ietf-happy-happyeyeballs-v3):
//   - Первичное подключение: QUIC / HTTP/3 стартует при t = 0.
//   - Connection Attempt Delay: измеряется, см. OknoSoedineniya выше.
//   - Вторичное подключение: TCP / HTTP/1.1 стартует по истечении окна.
//
// ПОЧЕМУ ОКНО НЕ КОНСТАНТА.
// Здесь стояли 700 мс — величина, подобранная под конкретное развёртывание, где
// сервер разработки намеренно вынесен за пять тысяч километров, чтобы ловить
// издержки больших задержек. На таком плече рукопожатие стоит сотни
// миллисекунд, и спецификационные 250 мс были бы слишком тесны: вторичная
// попытка уходила бы там, где QUIC просто не успел поздороваться. Но на боевом
// сервере в километре от клиента рукопожатие — единицы миллисекунд, и те же
// 700 мс превращаются в свою противоположность: застрявший QUIC ждёт страховки
// почти секунду там, где всё остальное укладывается в миллисекунды.
//
// Одно число не обслуживает оба случая, поэтому числа больше нет: окно берётся
// от измеренной стоимости рукопожатия до КАЖДОГО хоста (ZapomnitRukopozhatie
// и OknoSoedineniya выше). Пол и потолок оставлены — 150 и 700 мс, — чтобы
// одиночный выброс не сделал окно бессмысленно узким или широким.
//
// Для истории: пока соединения не переиспользовались, каждый запрос платил
// полное рукопожатие, и вторичная попытка уходила почти всегда — из 27 запусков
// QUIC до TCP добегали 25, побеждал TCP в 18 случаях из 33. Пул это устранил, а
// измеряемое окно снимает и остаток.
// ===========================================================================
// Второе окно — на ОТВЕТ по уже установленному соединению QUIC (см. ниже, в
// оркестраторе). Соединение может встать молча после подключения, и без этого
// окна запрос остался бы без запасного пути до самого таймаута.
//
// ПОЧЕМУ ЭТО НЕ ПОСТОЯННАЯ ВЕЛИЧИНА. Здесь стояли жёсткие 800 мс, и это было
// прямой ошибкой: запрос, который ДОЛЖЕН отвечать долго, в них не уложится
// никогда. Длинный опрос сервер держит секундами по замыслу - значит вторичная
// попытка уходила на КАЖДОМ таком запросе, хотя с QUIC всё было в порядке. По
// снятому дампу трафика это давало 411 пакетов и 104 КБ мимо QUIC - четверть
// байтов к серверу, - причём TCP, прогретый keep-alive, ещё и выигрывал изрядную
// часть гонок, и работа QUIC выбрасывалась.
//
// Happy Eyeballs - про гонку УСТАНОВЛЕНИЯ соединения. Когда соединение поднято
// и запрос отправлен, медленный ответ - это дело сервера, а не признак негодного
// транспорта. Поэтому окно берётся долей таймаута, который назначил вызывающий:
// именно он и есть верхняя граница разумного ожидания, и он же теперь честно
// доходит до нативного слоя. Молчащее соединение по-прежнему подстраховано - но
// порогом, который заведомо выше любого законного удержания ответа сервером.
#define HAPPY_EYEBALLS_OTVET_DOLYA 60      // процентов от таймаута запроса
#define HAPPY_EYEBALLS_OTVET_MIN_MS 1500   // и не короче этого
static unsigned long __stdcall RaceAndRequestThreadFunc(void* param) {
    RaceContext* race = (RaceContext*)param;
    LogMsg("RaceAndRequestThreadFunc: старт гонки MsQuic/HTTP3 vs WinHttp/HTTP1.1 по draft-ietf-happy-happyeyeballs-v3");

    // Первичный протокол (Primary): QUIC / HTTP/3 при t = 0
    HANDLE hHttp3 = CreateThread(NULL, 0, Http3ThreadFunc, race, 0, NULL);
    if (hHttp3) CloseHandle(hHttp3);

    // Окно берётся по измеренной стоимости рукопожатия до ЭТОГО хоста, а не из
    // константы: см. ZapomnitRukopozhatie. Хост разбираем здесь же — дешевле,
    // чем тащить его через контекст гонки.
    char hostOkna[256]; int portOkna = 0; char putOkna[1024]; int secOkna = 0;
    unsigned long oknoSoed = OKNO_SOED_MAX_MS;
    if (race->req && ParseUrl(race->req->url, hostOkna, sizeof(hostOkna), &portOkna,
                              putOkna, sizeof(putOkna), &secOkna)) {
        oknoSoed = OknoSoedineniya(hostOkna);
    }
    LogHexVal("RaceAndRequestThreadFunc: окно соединения, мс", oknoSoed);

    // Ожидание окна ИЛИ моментального сигнала об ошибке/завершении QUIC
    // (событие взводится и на успешном рукопожатии, так что при живом QUIC
    // ждать всю задержку не придётся).
    if (race->quicDoneEvent) {
        WaitForSingleObject(race->quicDoneEvent, oknoSoed);
    } else {
        Sleep(oknoSoed);
    }

    // По Happy Eyeballs v3 (RFC 8305): Если первичное QUIC-подключение НЕ установило связь (quicProgress == 0)
    // и НЕ завершилось успешно (quicSuccess == 1) за 250 мс, задействуем вторичный TCP
    if (race->quicSuccess == 0 && race->quicProgress == 0 && !race->winnerAssigned) {
        LogMsg("RaceAndRequestThreadFunc: QUIC не установил соединение (t=250ms или ошибка), запуск вторичной TCP попытки (Happy Eyeballs v3)...");
        __sync_add_and_fetch(&race->refCount, 1);
        HANDLE hHttp1 = CreateThread(NULL, 0, Http1ThreadFunc, race, 0, NULL);
        if (hHttp1) CloseHandle(hHttp1);
        else ReleaseRaceContext(race);
    } else if (race->quicSuccess == 0 && !race->winnerAssigned) {
        // СОЕДИНИЛСЯ — ЕЩЁ НЕ ЗНАЧИТ ОТВЕТИЛ. Раньше здесь запуск TCP просто
        // отменялся, стоило QUIC завершить рукопожатие. И этого хватало, пока
        // окно было 250мс: TCP успевал стартовать ДО рукопожатия и страховал
        // собой. Когда окно подняли выше стоимости рукопожатия, страховка
        // исчезла — а соединение может встать молча уже ПОСЛЕ подключения.
        // В журнале это выглядело так: SETTINGS и HEADERS отправлены, дальше
        // тишина до самого таймаута в 3с, потом откат через network.request, и
        // запрос обошёлся игроку в 5.1с (отчёт пользователя).
        //
        // Поэтому у гонки два окна: первое на СОЕДИНЕНИЕ (выше), второе на
        // ОТВЕТ. Не пришёл ответ и во втором — вторичная попытка всё равно
        // уходит, как и задумано в Happy Eyeballs.
        //
        // Ждём опросом, а не на quicDoneEvent: событие взводится с ручным
        // сбросом ещё на рукопожатии и остаётся взведённым, так что ожидание
        // на нём вернулось бы мгновенно.
        DWORD taymautZaprosa = race->req ? (DWORD)race->req->timeout_ms
                                         : (DWORD)HTTP3_REQUEST_TIMEOUT_MS;
        DWORD oknoOtveta = taymautZaprosa * HAPPY_EYEBALLS_OTVET_DOLYA / 100;
        if (oknoOtveta < HAPPY_EYEBALLS_OTVET_MIN_MS) oknoOtveta = HAPPY_EYEBALLS_OTVET_MIN_MS;
        LogMsg("RaceAndRequestThreadFunc: QUIC соединился, ждём ответа (второе окно)");
        LogHexVal("  окно ответа, мс", oknoOtveta);
        DWORD zhdali = 0;
        while (zhdali < oknoOtveta
               && !race->winnerAssigned
               && race->quicSuccess == 0
               && race->quicFinished == 0) {
            Sleep(50);
            zhdali += 50;
        }
        if (race->quicSuccess == 0 && race->quicFinished == 0 && !race->winnerAssigned) {
            LogMsg("RaceAndRequestThreadFunc: ответа по QUIC нет, запуск вторичной TCP попытки");
            __sync_add_and_fetch(&race->refCount, 1);
            HANDLE hHttp1 = CreateThread(NULL, 0, Http1ThreadFunc, race, 0, NULL);
            if (hHttp1) CloseHandle(hHttp1);
            else ReleaseRaceContext(race);
        } else {
            LogMsg("RaceAndRequestThreadFunc: ответ по QUIC получен, запуск TCP отменён");
        }
    } else {
        LogMsg("RaceAndRequestThreadFunc: QUIC уже завершился, запуск TCP отменён");
    }

    ReleaseRaceContext(race);
    return 0;
}

// ===========================================================================
// Граница с Lua (Solar2D). Контракт этого модуля — plugin.http3.native:
//   initiateRequest(url, params) -> число (ID) | nil     — старт гонки
//   checkRequest(reqId)          -> таблица события | nil — опрос результата
// ===========================================================================

// [Lua] native.initiateRequest( url, params ) -> returns reqId
static int initiateRequest( lua_State *L )
{
    const char* url = luaL_checkstring(L, 1);
    LogMsg("initiateRequest: Метод вызван из Lua");
    if (!url) {
        LogMsg("initiateRequest: Передан невалидный URL (nil)");
        lua_pushnil(L);
        return 1;
    }

    if (!g_CritSecInitialized) {
        InitializeCriticalSection(&g_CritSec);
        g_CritSecInitialized = 1;
    }

    void* heap = GetProcessHeap();
    AsyncRequestContext* req = (AsyncRequestContext*)HeapAlloc(heap, 0, sizeof(AsyncRequestContext));
    for (int i = 0; i < sizeof(AsyncRequestContext); i++) ((char*)req)[i] = 0;

    int u_idx = 0;
    while (url[u_idx] && u_idx < 1023) {
        req->url[u_idx] = url[u_idx];
        u_idx++;
    }
    req->url[u_idx] = '\0';

    req->method[0] = 'G'; req->method[1] = 'E'; req->method[2] = 'T'; req->method[3] = '\0';
    req->body_len = 0;
    req->headers[0] = '\0';
    req->timeout_ms = HTTP3_REQUEST_TIMEOUT_MS;   // умолчание, ниже перекроется параметром
    req->id = g_NextRequestId++;

    if (lua_isstring(L, 2)) {
        const char* method = lua_tostring(L, 2);
        if (method) {
            int m_idx = 0;
            while (method[m_idx] && m_idx < 15) {
                req->method[m_idx] = method[m_idx];
                m_idx++;
            }
            req->method[m_idx] = '\0';
        }
    }

    int tbl_idx = 0;
    if (lua_istable(L, 2)) tbl_idx = 2;
    else if (lua_istable(L, 4)) tbl_idx = 4;
    else if (lua_istable(L, 3)) tbl_idx = 3;

    if (tbl_idx > 0) {
        lua_getfield(L, tbl_idx, "method");
        if (lua_isstring(L, -1)) {
            const char* method = lua_tostring(L, -1);
            int m_idx = 0;
            while (method[m_idx] && m_idx < 15) {
                req->method[m_idx] = method[m_idx];
                m_idx++;
            }
            req->method[m_idx] = '\0';
        }
        lua_pop(L, 1);

        // timeout задаётся в СЕКУНДАХ, как в network.request, и может быть дробным.
        lua_getfield(L, tbl_idx, "timeout");
        if (lua_isnumber(L, -1)) {
            double sek = lua_tonumber(L, -1);
            if (sek > 0.0) {
                if (sek > 120.0) sek = 120.0;   // защита от бессмысленных значений
                req->timeout_ms = (int)(sek * 1000.0);
            }
        }
        lua_pop(L, 1);

        lua_getfield(L, tbl_idx, "body");
        if (lua_isstring(L, -1)) {
            size_t b_len = 0;
            const char* body = lua_tolstring(L, -1, &b_len);
            if (body && b_len > 0) {
                req->body_len = (int)b_len;
                if (req->body_len > 4095) req->body_len = 4095;
                for (int i = 0; i < req->body_len; i++) req->body[i] = body[i];
                req->body[req->body_len] = '\0';
            }
        }
        lua_pop(L, 1);

        lua_getfield(L, tbl_idx, "headers");
        if (lua_istable(L, -1)) {
            int h_pos = 0;
            lua_pushnil(L);
            while (lua_next(L, -2) != 0) {
                const char* key = lua_tostring(L, -2);
                const char* val = lua_tostring(L, -1);
                if (key && val) {
                    int k_idx = 0;
                    while (key[k_idx] && h_pos < 2040) req->headers[h_pos++] = key[k_idx++];
                    if (h_pos < 2040) req->headers[h_pos++] = ':';
                    if (h_pos < 2040) req->headers[h_pos++] = ' ';
                    int v_idx = 0;
                    while (val[v_idx] && h_pos < 2040) req->headers[h_pos++] = val[v_idx++];
                    if (h_pos < 2040) { req->headers[h_pos++] = '\r'; req->headers[h_pos++] = '\n'; }
                }
                lua_pop(L, 1);
            }
            req->headers[h_pos] = '\0';
        }
        lua_pop(L, 1);
    }

    RaceContext* race = (RaceContext*)HeapAlloc(heap, 0, sizeof(RaceContext));
    for (int i = 0; i < sizeof(RaceContext); i++) ((char*)race)[i] = 0;
    race->req = req;
    race->quicDoneEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    race->winnerAssigned = 0;
    race->refCount = 2; // 1 ссылка для RaceAndRequestThreadFunc, 1 для Http3ThreadFunc

    EnterCriticalSection(&g_CritSec);
    g_ActiveTasksCount++;
    LeaveCriticalSection(&g_CritSec);

    LogMsg("initiateRequest: Создание фонового потока-оркестратора гонки...");
    unsigned long thread_id;
    HANDLE hThread = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE)RaceAndRequestThreadFunc, race, 0, &thread_id);
    if (hThread) {
        LogMsg("initiateRequest: Поток CreateThread создан успешно");
        CloseHandle(hThread);
        lua_pushinteger(L, req->id);
    } else {
        LogMsg("initiateRequest: Ошибка CreateThread!");
        EnterCriticalSection(&g_CritSec);
        if (g_ActiveTasksCount > 0) g_ActiveTasksCount--;
        LeaveCriticalSection(&g_CritSec);
        if (race->quicDoneEvent) CloseHandle(race->quicDoneEvent);
        HeapFree(heap, 0, race);
        HeapFree(heap, 0, req);
        lua_pushnil(L);
    }
    return 1;
}

// Проверка статуса выполнения запроса
// [Lua] native.checkRequest( reqId ) -> returns table or nil
static int checkRequest( lua_State *L )
{
    int id = (int)luaL_checkinteger(L, 1);
    RequestResult* res = GetAndRemoveResult(id);
    if (!res) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);

    lua_pushstring(L, "name");
    lua_pushstring(L, "http3");
    lua_settable(L, -3);

    lua_pushstring(L, "requestId");
    lua_pushinteger(L, res->id);
    lua_settable(L, -3);

    lua_pushstring(L, "isError");
    lua_pushboolean(L, res->is_error);
    lua_settable(L, -3);

    if (res->is_error) {
        lua_pushstring(L, "reason");
        lua_pushstring(L, "NATIVE_TRANSPORT_FAILED");
        lua_settable(L, -3);

        lua_pushstring(L, "error");
        lua_pushstring(L, "NATIVE_TRANSPORT_FAILED");
        lua_settable(L, -3);
    } else {
        lua_pushstring(L, "error");
        lua_pushnil(L);
        lua_settable(L, -3);
    }

    lua_pushstring(L, "status");
    lua_pushinteger(L, res->status_code);
    lua_settable(L, -3);

    lua_pushstring(L, "response");
    if (res->response_data) {
        lua_pushlstring(L, res->response_data, res->response_len);
    } else {
        lua_pushstring(L, "");
    }
    lua_settable(L, -3);

    lua_pushstring(L, "bytesTotal");
    lua_pushinteger(L, res->response_len);
    lua_settable(L, -3);

    lua_pushstring(L, "transport");
    lua_pushstring(L, res->transport);
    lua_settable(L, -3);

    lua_pushstring(L, "protocol");
    // Проверяем различные наименования транспорта MsQuic/HTTP3 для правильной установки протокола в Lua
    if (MyStrCmp(res->transport, "MsQuic") == 0 || MyStrCmp(res->transport, "HTTP/3") == 0 || MyStrCmp(res->transport, "MsQuic/HTTP3") == 0) {
        lua_pushstring(L, "HTTP/3 (QUIC / MsQuic)");
    } else {
        lua_pushstring(L, "HTTP/1.1 (WinHTTP)");
    }
    lua_settable(L, -3);

    lua_pushstring(L, "isNative");
    lua_pushboolean(L, 1);
    lua_settable(L, -3);

    lua_pushstring(L, "headers");
    lua_newtable(L);
    lua_settable(L, -3);

    void* heap = GetProcessHeap();
    if (res->response_data) HeapFree(heap, 0, res->response_data);
    HeapFree(heap, 0, res);

    return 1;
}

// Отмена запроса на Windows
static int cancelRequest( lua_State *L )
{
    if (lua_isnumber(L, 1)) {
        int reqId = (int)lua_tointeger(L, 1);
        EnterCriticalSection(&g_CritSec);
        RequestResult* res = GetAndRemoveResult(reqId);
        if (res) {
            void* heap = GetProcessHeap();
            if (res->response_data) HeapFree(heap, 0, res->response_data);
            HeapFree(heap, 0, res);
            LeaveCriticalSection(&g_CritSec);
            lua_pushboolean(L, 1);
            return 1;
        } else {
            // Если результат ещё не добавлен, вносим ID в отменённые
            AddCancelledId(reqId);
            LeaveCriticalSection(&g_CritSec);
            lua_pushboolean(L, 1);
            return 1;
        }
    }
    lua_pushboolean(L, 0);
    return 1;
}

// Метрики использования памяти на Windows
typedef struct _PROCESS_MEMORY_COUNTERS_MIN {
    unsigned long cb;
    unsigned long PageFaultCount;
    size_t PeakWorkingSetSize;
    size_t WorkingSetSize;
    size_t QuotaPeakPagedPoolUsage;
    size_t QuotaPagedPoolUsage;
    size_t QuotaPeakNonPagedPoolUsage;
    size_t QuotaNonPagedPoolUsage;
    size_t PagefileUsage;
    size_t PeakPagefileUsage;
} PROCESS_MEMORY_COUNTERS_MIN;

typedef BOOL (WINAPI *PFN_GetProcessMemoryInfo)(HANDLE Process, PROCESS_MEMORY_COUNTERS_MIN* ppmc, DWORD cb);

static int getMemoryStats( lua_State *L )
{
    size_t rssBytes = 0;
    HMODULE hKernel = GetModuleHandleA("kernel32.dll");
    if (hKernel) {
        PFN_GetProcessMemoryInfo pfn = (PFN_GetProcessMemoryInfo)GetProcAddress(hKernel, "K32GetProcessMemoryInfo");
        if (pfn) {
            PROCESS_MEMORY_COUNTERS_MIN pmc;
            pmc.cb = sizeof(pmc);
            if (pfn(GetCurrentProcess(), &pmc, sizeof(pmc))) {
                rssBytes = pmc.WorkingSetSize;
            }
        }
    }

    double rssMB = (double)rssBytes / (1024.0 * 1024.0);

    lua_newtable(L);

    lua_pushnumber(L, (lua_Number)rssBytes);
    lua_setfield(L, -2, "nativeRSSBytes");

    lua_pushnumber(L, (lua_Number)rssMB);
    lua_setfield(L, -2, "nativeRSSMB");

    EnterCriticalSection(&g_CritSec);
    long activeTasks = g_ActiveTasksCount;
    long totalCompleted = g_TotalCompletedCount;
    long totalFailed = g_TotalFailedCount;
    LeaveCriticalSection(&g_CritSec);

    lua_pushinteger(L, activeTasks);
    lua_setfield(L, -2, "activeTasks");

    lua_pushinteger(L, totalCompleted);
    lua_setfield(L, -2, "totalCompleted");

    lua_pushinteger(L, totalFailed);
    lua_setfield(L, -2, "totalFailed");

    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "isHTTP3Configured");

    lua_pushstring(L, "MsQuic + WinHTTP (Windows Native)");
    lua_setfield(L, -2, "stackName");

    // Метка времени и дата сборки бинарного нативного плагина C++
    lua_pushstring(L, __DATE__ " " __TIME__);
    lua_setfield(L, -2, "buildTimestamp");

    return 1;
}

// Принудительное освобождение всех результатов из кучи и сброс TLS кэша сессий MsQuic
static void FreeAllResults() {
    EnterCriticalSection(&g_CritSec);
    void* heap = GetProcessHeap();
    RequestResult* curr = g_ResultsList;
    while (curr) {
        RequestResult* next = curr->next;
        if (curr->response_data) HeapFree(heap, 0, curr->response_data);
        HeapFree(heap, 0, curr);
        curr = next;
    }
    g_ResultsList = NULL;
    g_CancelledIdsCount = 0;

    LeaveCriticalSection(&g_CritSec);
}

// Запуск сборки мусора
static int collectGarbage( lua_State *L )
{
    FreeAllResults();
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    SetProcessWorkingSetSize(GetCurrentProcess(), (SIZE_T)-1, (SIZE_T)-1);
    lua_pushboolean(L, 1);
    return 1;
}

// Прокачка событий
static int pumpEvents( lua_State *L )
{
    return 0;
}

// Функция открытия библиотеки
static int Open( lua_State *L )
{
    const luaL_Reg kVTable[] =
    {
        { "request", initiateRequest },
        { "initiateRequest", initiateRequest },
        { "checkRequest", checkRequest },
        { "cancel", cancelRequest },
        { "getMemoryStats", getMemoryStats },
        { "collectGarbage", collectGarbage },
        { "pumpEvents", pumpEvents },
        { NULL, NULL }
    };
    luaL_openlib( L, "plugin.http3.native", kVTable, 0 );
    return 1;
}

// Точка входа для DLL без CRT
#ifdef _WIN32
int __stdcall DllMain(void* hModule, unsigned long ul_reason_for_call, void* lpReserved)
{
    if (ul_reason_for_call == 1) { // DLL_PROCESS_ATTACH
        if (!g_CritSecInitialized) {
            InitializeCriticalSection(&g_CritSec);
            g_CritSecInitialized = 1;
        }
    } else if (ul_reason_for_call == 0) { // DLL_PROCESS_DETACH
        if (g_CritSecInitialized) {
            DeleteCriticalSection(&g_CritSec);
            g_CritSecInitialized = 0;
        }
    }
    return 1;
}
#endif

// Экспортируемая функция открытия плагина для Solar2D
CORONA_EXPORT int luaopen_plugin_http3_native( lua_State *L )
{
    return Open( L );
}

// Новое имя модуля — plugin.http3.ntv, отсюда и символ. Прежнее оставлено выше
// для совместимости с уже собранными приложениями.
// Переименование понадобилось из-за Android: там Solar2D ищет загрузчик по
// имени модуля (require("a.b.c") -> класс a.b.c.LuaLoader), а пакет с сегментом
// native javac собрать не может — это ключевое слово Java. Ради обхода
// загрузчик держали на Kotlin и тащили в AAR весь kotlin-stdlib, что роняло
// сборку приложений дубликатами классов. Имя ntv снимает причину целиком.
CORONA_EXPORT int luaopen_plugin_http3_ntv( lua_State *L )
{
    return Open( L );
}

