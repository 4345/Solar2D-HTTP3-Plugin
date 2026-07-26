#ifndef _FAKE_WINDOWS_H_
#define _FAKE_WINDOWS_H_

#define WINAPI __stdcall
#define QUIC_API __cdecl
#define QUIC_STATUS HRESULT
typedef long HRESULT;
typedef void* HANDLE;
typedef void* HMODULE;
typedef void* HWND;
typedef unsigned long DWORD;
typedef unsigned short WORD;
typedef unsigned char BYTE;
typedef int BOOL;
typedef unsigned long ULONG;
typedef long LONG;
typedef unsigned int UINT;
typedef unsigned __int64 ULONG64;
typedef unsigned char BOOLEAN;

typedef uintptr_t ULONG_PTR;
typedef void* PVOID;
typedef void* LPVOID;
typedef size_t SIZE_T;

#define TRUE 1
#define FALSE 0

#ifndef NULL
#define NULL 0
#endif

// SAL Аннотации Microsoft
#define _In_
#define _Out_
#define _Inout_
#define _In_opt_
#define _Out_opt_
#define _Pre_defensive_
#define _IRQL_requires_max_(x)
#define PASSIVE_LEVEL 0
#define _In_range_(x, y)
#define DEFINE_ENUM_FLAG_OPERATORS(x)
#define _Function_class_(x)
#define _Out_writes_bytes_opt_(x)
#define _In_reads_(x)
#define _In_reads_bytes_(x)
#define _Out_writes_to_(x, y)
#define _Out_writes_bytes_to_opt_(x, y)
#define _Out_writes_to_opt_(x, y)
#define _Out_writes_all_(x)
#define _Out_writes_all_opt_(x)
#define _Success_(x)
#define _Field_size_(x)
#define _Field_size_bytes_(x)
#define _Field_size_opt_(x)
#define _Frees_ptr_opt_
#define _Ret_maybenull_
#define _Must_inspect_result_
#define _Writable_bytes_(x)
#define _Readable_bytes_(x)
#define _Null_terminated_
#define _In_reads_or_z_(x)
#define _In_reads_bytes_opt_(x)
#define _In_reads_opt_(x)
#define _Out_writes_bytes_(x)
#define _Out_writes_opt_(x)
#define _Field_size_bytes_opt_(x)
#define _When_(x, y)
#define _Reserved_
#define _Outptr_
#define _At_(x, y)
#define __drv_allocatesMem(x)
#define __drv_freesMem(x)
#define _Outptr_result_maybenull_
#define _Outptr_result_buffer_maybenull_(x)
#define _Out_writes_bytes_to_(x, y)
#define _In_reads_or_z_opt_(x)
#define _Out_writes_all_opt_(x)
#define _Out_writes_to_opt_(x, y)
#define _Inout_updates_bytes_(x)
#define _Inout_updates_bytes_opt_(x)
#define _Outptr_result_buffer_(x)
#define _Outptr_result_bytebuffer_(x)
#define _Outptr_result_bytebuffer_maybenull_(x)
#define _Field_range_(x, y)
#define _Check_return_

// LIST_ENTRY структура
typedef struct _LIST_ENTRY {
    struct _LIST_ENTRY* Flink;
    struct _LIST_ENTRY* Blink;
} LIST_ENTRY;

// RTL_CRITICAL_SECTION структура
typedef struct _RTL_CRITICAL_SECTION {
    void* DebugInfo;
    LONG LockCount;
    LONG RecursionCount;
    HANDLE OwningThread;
    HANDLE LockSemaphore;
    ULONG_PTR SpinCount;
} RTL_CRITICAL_SECTION, *PRTL_CRITICAL_SECTION, *LPCRITICAL_SECTION;

// Структуры для перекрывающегося ввода-вывода (WinHttp/MsQuic)
typedef struct _OVERLAPPED {
    ULONG_PTR Internal;
    ULONG_PTR InternalHigh;
    union {
        struct {
            DWORD Offset;
            DWORD OffsetHigh;
        } DUMMYSTRUCTNAME;
        PVOID Pointer;
    } DUMMYUNIONNAME;
    HANDLE  hEvent;
} OVERLAPPED;

typedef struct _OVERLAPPED_ENTRY {
    ULONG_PTR lpCompletionKey;
    struct _OVERLAPPED* lpOverlapped;
    ULONG_PTR Internal;
    DWORD dwNumberOfBytesTransferred;
} OVERLAPPED_ENTRY;

// Стандартные функции memset/memcmp
#ifdef __cplusplus
extern "C" {
#endif
void* memset(void* dest, int c, size_t count);
int memcmp(const void* buf1, const void* buf2, size_t count);
#ifdef __cplusplus
}
#endif

// Прототипы системных вызовов kernel32.dll
#ifdef __cplusplus
extern "C" {
#endif

typedef DWORD (__stdcall *LPTHREAD_START_ROUTINE)(void* lpParameter);

#define STD_OUTPUT_HANDLE ((DWORD)-11)

__declspec(dllimport) void __stdcall InitializeCriticalSection(LPCRITICAL_SECTION lpCriticalSection);
__declspec(dllimport) void __stdcall DeleteCriticalSection(LPCRITICAL_SECTION lpCriticalSection);
__declspec(dllimport) void __stdcall EnterCriticalSection(LPCRITICAL_SECTION lpCriticalSection);
__declspec(dllimport) void __stdcall LeaveCriticalSection(LPCRITICAL_SECTION lpCriticalSection);

__declspec(dllimport) HANDLE __stdcall GetProcessHeap(void);
__declspec(dllimport) LPVOID __stdcall HeapAlloc(HANDLE hHeap, DWORD dwFlags, SIZE_T dwBytes);
__declspec(dllimport) BOOL __stdcall HeapFree(HANDLE hHeap, DWORD dwFlags, LPVOID lpMem);

__declspec(dllimport) HANDLE __stdcall CreateThread(void* lpThreadAttributes, SIZE_T dwStackSize, LPTHREAD_START_ROUTINE lpStartAddress, void* lpParameter, DWORD dwCreationFlags, DWORD* lpThreadId);
__declspec(dllimport) BOOL __stdcall CloseHandle(HANDLE hObject);
__declspec(dllimport) void __stdcall Sleep(DWORD dwMilliseconds);
__declspec(dllimport) DWORD __stdcall GetTickCount(void);

__declspec(dllimport) HANDLE __stdcall CreateEventA(void* lpEventAttributes, BOOL bManualReset, BOOL bInitialState, const char* lpName);
__declspec(dllimport) BOOL __stdcall SetEvent(HANDLE hEvent);
__declspec(dllimport) DWORD __stdcall WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);

__declspec(dllimport) HMODULE __stdcall LoadLibraryA(const char* lpLibFileName);
__declspec(dllimport) void* __stdcall GetProcAddress(HMODULE hModule, const char* lpProcName);
__declspec(dllimport) BOOL __stdcall FreeLibrary(HMODULE hLibModule);

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD nStdHandle);
__declspec(dllimport) BOOL __stdcall WriteFile(HANDLE hFile, const void* lpBuffer, DWORD nNumberOfBytesToWrite, DWORD* lpNumberOfBytesWritten, OVERLAPPED* lpOverlapped);
__declspec(dllimport) void __stdcall OutputDebugStringA(const char* lpOutputString);
__declspec(dllimport) DWORD __stdcall GetLastError(void);

#ifdef __cplusplus
}
#endif

#endif // _FAKE_WINDOWS_H_
