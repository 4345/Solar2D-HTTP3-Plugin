#ifndef _FAKE_WINHTTP_H_
#define _FAKE_WINHTTP_H_

#include <windows.h>

typedef void* HINTERNET;
typedef unsigned short INTERNET_PORT;
typedef uintptr_t DWORD_PTR;
typedef DWORD* LPDWORD;

#define WINHTTP_ACCESS_TYPE_DEFAULT_PROXY 0
#define WINHTTP_NO_PROXY_NAME NULL
#define WINHTTP_NO_PROXY_BYPASS NULL
#define WINHTTP_FLAG_SECURE 0x00800000
#define WINHTTP_QUERY_STATUS_CODE 19

// Флаги HTTP/3 и HTTP/2 для WinHttp (Windows 11+, сборка 22000+)
#define WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL  133
#define WINHTTP_OPTION_HTTP_PROTOCOL_USED    134
#define WINHTTP_PROTOCOL_FLAG_HTTP2          0x00000001
#define WINHTTP_PROTOCOL_FLAG_HTTP3          0x00000002

#ifdef __cplusplus
extern "C" {
#endif

__declspec(dllimport) HINTERNET __stdcall WinHttpOpen(const wchar_t* pwszUserAgent, DWORD dwAccessType, const wchar_t* pwszProxyName, const wchar_t* pwszProxyBypass, DWORD dwFlags);
// WinHttpSetTimeouts — ограничивает каждую фазу (resolve/connect/send/receive) запроса
__declspec(dllimport) BOOL __stdcall WinHttpSetTimeouts(HINTERNET hInternet, int nResolveTimeout, int nConnectTimeout, int nSendTimeout, int nReceiveTimeout);
__declspec(dllimport) HINTERNET __stdcall WinHttpConnect(HINTERNET hSession, const wchar_t* pswzServerName, INTERNET_PORT nServerPort, DWORD dwReserved);
__declspec(dllimport) HINTERNET __stdcall WinHttpOpenRequest(HINTERNET hConnect, const wchar_t* pwszVerb, const wchar_t* pwszObjectName, const wchar_t* pwszVersion, const wchar_t* pwszReferrer, const wchar_t** ppwszAcceptTypes, DWORD dwFlags);
__declspec(dllimport) BOOL __stdcall WinHttpSendRequest(HINTERNET hRequest, const wchar_t* pwszHeaders, DWORD dwHeadersLength, LPVOID lpOptional, DWORD dwOptionalLength, DWORD dwTotalLength, DWORD_PTR dwContext);
__declspec(dllimport) BOOL __stdcall WinHttpReceiveResponse(HINTERNET hRequest, LPVOID lpReserved);
__declspec(dllimport) BOOL __stdcall WinHttpQueryHeaders(HINTERNET hRequest, DWORD dwInfoLevel, const wchar_t* pwszName, LPVOID lpBuffer, LPDWORD lpdwBufferLength, LPDWORD lpdwIndex);
__declspec(dllimport) BOOL __stdcall WinHttpReadData(HINTERNET hRequest, LPVOID lpBuffer, DWORD dwNumberOfBytesToRead, LPDWORD lpdwNumberOfBytesRead);
__declspec(dllimport) BOOL __stdcall WinHttpCloseHandle(HINTERNET hInternet);
// WinHttpSetOption — для включения HTTP/3 на Windows 11
__declspec(dllimport) BOOL __stdcall WinHttpSetOption(HINTERNET hInternet, DWORD dwOption, LPVOID lpBuffer, DWORD dwBufferLength);
// WinHttpQueryOption — для определения реально использованного протокола
__declspec(dllimport) BOOL __stdcall WinHttpQueryOption(HINTERNET hInternet, DWORD dwOption, LPVOID lpBuffer, LPDWORD lpdwBufferLength);

#ifdef __cplusplus
}
#endif

#endif // _FAKE_WINHTTP_H_
