#ifndef _FAKE_WINSOCK2_H_
#define _FAKE_WINSOCK2_H_

#include <windows.h>

typedef uintptr_t SOCKET;

#define AF_UNSPEC 0
#define AF_INET 2
#define AF_INET6 23
#define INVALID_SOCKET (uintptr_t)(~0)

#define SOCK_STREAM 1
#define IPPROTO_TCP 6

typedef unsigned short ADDRESS_FAMILY;

typedef struct in_addr {
    union {
        struct { unsigned char s_b1, s_b2, s_b3, s_b4; } S_un_b;
        unsigned long S_addr;
    } S_un;
} IN_ADDR;

#define s_addr S_un.S_addr

struct sockaddr_in {
    short sin_family;
    unsigned short sin_port;
    struct in_addr sin_addr;
    char sin_zero[8];
};

typedef struct in6_addr {
    union {
        unsigned char Byte[16];
        unsigned short Word[8];
    } u;
} IN6_ADDR;

struct sockaddr_in6 {
    short sin6_family;
    unsigned short sin6_port;
    unsigned long sin6_flowinfo;
    struct in6_addr sin6_addr;
    unsigned long sin6_scope_id;
};

struct sockaddr {
    unsigned short sa_family;
    char sa_data[14];
};

typedef union _SOCKADDR_INET {
    struct sockaddr_in Ipv4;
    struct sockaddr_in6 Ipv6;
    ADDRESS_FAMILY si_family;
} SOCKADDR_INET;

typedef struct WSAData {
    uint16_t wVersion;
    uint16_t wHighVersion;
    char szDescription[257];
    char szSystemStatus[129];
    unsigned short iMaxSockets;
    unsigned short iMaxUdpDg;
    char* lpVendorInfo;
} WSADATA;

#endif // _FAKE_WINSOCK2_H_
