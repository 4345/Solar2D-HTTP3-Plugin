#ifndef _FAKE_WS2TCPIP_H_
#define _FAKE_WS2TCPIP_H_

#include <winsock2.h>

struct addrinfo {
    int ai_flags;
    int ai_family;
    int ai_socktype;
    int ai_protocol;
    size_t ai_addrlen;
    char* ai_canonname;
    struct sockaddr* ai_addr;
    struct addrinfo* ai_next;
};

// Прототипы системных вызовов WinSock ws2_32.dll
#ifdef __cplusplus
extern "C" {
#endif

__declspec(dllimport) int __stdcall WSAStartup(unsigned short wVersionRequested, WSADATA* lpWSAData);
__declspec(dllimport) int __stdcall WSACleanup(void);
__declspec(dllimport) SOCKET __stdcall socket(int af, int type, int protocol);
__declspec(dllimport) int __stdcall connect(SOCKET s, const struct sockaddr* name, int namelen);
__declspec(dllimport) int __stdcall closesocket(SOCKET s);

__declspec(dllimport) int __stdcall getaddrinfo(const char* nodename, const char* servname, const struct addrinfo* hints, struct addrinfo** res);
__declspec(dllimport) void __stdcall freeaddrinfo(struct addrinfo* ai);

#ifdef __cplusplus
}
#endif

#endif // _FAKE_WS2TCPIP_H_
