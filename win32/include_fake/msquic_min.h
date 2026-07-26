// msquic_min.h
// Минимальные ABI-совместимые объявления MsQuic для nostdlib-сборки.
// НЕ используем настоящий msquic.h/msquic_winuser.h напрямую: они тянут реальные
// winsock2/ws2tcpip типы, а соответствующие include_fake-заглушки пустые.
// Здесь объявлены только те поля/функции, которые реально используются,
// но порядок полей в QUIC_API_TABLE и структурах событий совпадает с реальным
// msquic.h (Version 2 API table), чтобы смещения полей были ABI-совместимы
// с msquic.dll.

#ifndef _MSQUIC_MIN_H_
#define _MSQUIC_MIN_H_

#include <stdint.h>

typedef struct QUIC_HANDLE* HQUIC;
typedef unsigned short QUIC_ADDRESS_FAMILY;
#define QUIC_ADDRESS_FAMILY_UNSPEC 0

typedef uint64_t QUIC_UINT62;

typedef struct QUIC_BUFFER {
    uint32_t Length;
    uint8_t* Buffer;
} QUIC_BUFFER;

typedef enum QUIC_EXECUTION_PROFILE {
    QUIC_EXECUTION_PROFILE_LOW_LATENCY = 0,
} QUIC_EXECUTION_PROFILE;

typedef struct QUIC_REGISTRATION_CONFIG {
    const char* AppName;
    QUIC_EXECUTION_PROFILE ExecutionProfile;
} QUIC_REGISTRATION_CONFIG;

// Полная структура QUIC_SETTINGS (не preview-сборка) — воспроизведена ПОЛНОСТЬЮ,
// поле в поле, как в реальном msquic.h, чтобы смещения совпадали 1-в-1 с ABI msquic.dll.
// Нужна, чтобы явно задать окна flow control для стримов вместо NULL/0 в ConfigurationOpen
// (по умолчанию через NULL сервер может решить, что ему "заблокировано" отправлять ответ).
typedef struct QUIC_SETTINGS {
    union {
        uint64_t IsSetFlags;
        struct {
            uint64_t MaxBytesPerKey                         : 1;
            uint64_t HandshakeIdleTimeoutMs                 : 1;
            uint64_t IdleTimeoutMs                          : 1;
            uint64_t MtuDiscoverySearchCompleteTimeoutUs    : 1;
            uint64_t TlsClientMaxSendBuffer                 : 1;
            uint64_t TlsServerMaxSendBuffer                 : 1;
            uint64_t StreamRecvWindowDefault                : 1;
            uint64_t StreamRecvBufferDefault                : 1;
            uint64_t ConnFlowControlWindow                  : 1;
            uint64_t MaxWorkerQueueDelayUs                  : 1;
            uint64_t MaxStatelessOperations                 : 1;
            uint64_t InitialWindowPackets                   : 1;
            uint64_t SendIdleTimeoutMs                      : 1;
            uint64_t InitialRttMs                           : 1;
            uint64_t MaxAckDelayMs                          : 1;
            uint64_t DisconnectTimeoutMs                    : 1;
            uint64_t KeepAliveIntervalMs                    : 1;
            uint64_t CongestionControlAlgorithm             : 1;
            uint64_t PeerBidiStreamCount                    : 1;
            uint64_t PeerUnidiStreamCount                   : 1;
            uint64_t MaxBindingStatelessOperations          : 1;
            uint64_t StatelessOperationExpirationMs         : 1;
            uint64_t MinimumMtu                             : 1;
            uint64_t MaximumMtu                             : 1;
            uint64_t SendBufferingEnabled                   : 1;
            uint64_t PacingEnabled                          : 1;
            uint64_t MigrationEnabled                       : 1;
            uint64_t DatagramReceiveEnabled                 : 1;
            uint64_t ServerResumptionLevel                  : 1;
            uint64_t MaxOperationsPerDrain                  : 1;
            uint64_t MtuDiscoveryMissingProbeCount          : 1;
            uint64_t DestCidUpdateIdleTimeoutMs             : 1;
            uint64_t GreaseQuicBitEnabled                   : 1;
            uint64_t EcnEnabled                             : 1;
            uint64_t HyStartEnabled                         : 1;
            uint64_t StreamRecvWindowBidiLocalDefault       : 1;
            uint64_t StreamRecvWindowBidiRemoteDefault      : 1;
            uint64_t StreamRecvWindowUnidiDefault           : 1;
            uint64_t RESERVED                               : 26;
        } IsSet;
    };

    uint64_t MaxBytesPerKey;
    uint64_t HandshakeIdleTimeoutMs;
    uint64_t IdleTimeoutMs;
    uint64_t MtuDiscoverySearchCompleteTimeoutUs;
    uint32_t TlsClientMaxSendBuffer;
    uint32_t TlsServerMaxSendBuffer;
    uint32_t StreamRecvWindowDefault;
    uint32_t StreamRecvBufferDefault;
    uint32_t ConnFlowControlWindow;
    uint32_t MaxWorkerQueueDelayUs;
    uint32_t MaxStatelessOperations;
    uint32_t InitialWindowPackets;
    uint32_t SendIdleTimeoutMs;
    uint32_t InitialRttMs;
    uint32_t MaxAckDelayMs;
    uint32_t DisconnectTimeoutMs;
    uint32_t KeepAliveIntervalMs;
    uint16_t CongestionControlAlgorithm;
    uint16_t PeerBidiStreamCount;
    uint16_t PeerUnidiStreamCount;
    uint16_t MaxBindingStatelessOperations;
    uint16_t StatelessOperationExpirationMs;
    uint16_t MinimumMtu;
    uint16_t MaximumMtu;
    uint8_t SendBufferingEnabled            : 1;
    uint8_t PacingEnabled                   : 1;
    uint8_t MigrationEnabled                : 1;
    uint8_t DatagramReceiveEnabled          : 1;
    uint8_t ServerResumptionLevel           : 2;
    uint8_t GreaseQuicBitEnabled            : 1;
    uint8_t EcnEnabled                      : 1;
    uint8_t MaxOperationsPerDrain;
    uint8_t MtuDiscoveryMissingProbeCount;
    uint32_t DestCidUpdateIdleTimeoutMs;
    union {
        uint64_t Flags;
        struct {
            uint64_t HyStartEnabled            : 1;
            uint64_t ReservedFlags             : 63;
        };
    };
    uint32_t StreamRecvWindowBidiLocalDefault;
    uint32_t StreamRecvWindowBidiRemoteDefault;
    uint32_t StreamRecvWindowUnidiDefault;
} QUIC_SETTINGS;

typedef enum QUIC_CREDENTIAL_TYPE {
    QUIC_CREDENTIAL_TYPE_NONE = 0,
} QUIC_CREDENTIAL_TYPE;

typedef enum QUIC_CREDENTIAL_FLAGS {
    QUIC_CREDENTIAL_FLAG_NONE   = 0x00000000,
    QUIC_CREDENTIAL_FLAG_CLIENT = 0x00000001,
    QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION = 0x00000004,
} QUIC_CREDENTIAL_FLAGS;

// Полный layout (порядок полей) как в реальном msquic.h — важно для ABI.
typedef struct QUIC_CREDENTIAL_CONFIG {
    QUIC_CREDENTIAL_TYPE Type;
    QUIC_CREDENTIAL_FLAGS Flags;
    void* CertificateUnion;      // объединение указателей на сертификат — не используется (Type=NONE)
    const char* Principal;
    void* Reserved;
    void* AsyncHandler;
    uint32_t AllowedCipherSuites;
    const char* CaCertificateFile;
} QUIC_CREDENTIAL_CONFIG;

// --- Connection events ---

typedef enum QUIC_CONNECTION_EVENT_TYPE {
    QUIC_CONNECTION_EVENT_CONNECTED                       = 0,
    QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT  = 1,
    QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER       = 2,
    QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE                = 3,
    QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED              = 6,
} QUIC_CONNECTION_EVENT_TYPE;

typedef struct QUIC_CONNECTION_EVENT {
    QUIC_CONNECTION_EVENT_TYPE Type;
    union {
        struct {
            uint8_t SessionResumed;
            uint8_t NegotiatedAlpnLength;
            const uint8_t* NegotiatedAlpn;
        } CONNECTED;
        struct {
            long Status;
            QUIC_UINT62 ErrorCode;
        } SHUTDOWN_INITIATED_BY_TRANSPORT;
        struct {
            QUIC_UINT62 ErrorCode;
        } SHUTDOWN_INITIATED_BY_PEER;
        struct {
            uint8_t Flags; // bit0 = HandshakeCompleted
        } SHUTDOWN_COMPLETE;
        struct {
            HQUIC Stream;
            uint32_t Flags;
        } PEER_STREAM_STARTED;
    };
} QUIC_CONNECTION_EVENT;

typedef long (__cdecl * QUIC_CONNECTION_CALLBACK_HANDLER)(HQUIC Connection, void* Context, QUIC_CONNECTION_EVENT* Event);

// --- Stream events ---

typedef enum QUIC_STREAM_EVENT_TYPE {
    QUIC_STREAM_EVENT_START_COMPLETE         = 0,
    QUIC_STREAM_EVENT_RECEIVE                = 1,
    QUIC_STREAM_EVENT_SEND_COMPLETE          = 2,
    QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN     = 3,
    QUIC_STREAM_EVENT_PEER_SEND_ABORTED      = 4,
    QUIC_STREAM_EVENT_PEER_RECEIVE_ABORTED   = 5,
    QUIC_STREAM_EVENT_SEND_SHUTDOWN_COMPLETE = 6,
    QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE      = 7,
} QUIC_STREAM_EVENT_TYPE;

typedef struct QUIC_STREAM_EVENT {
    QUIC_STREAM_EVENT_TYPE Type;
    union {
        struct {
            long Status;
            QUIC_UINT62 ID;
            uint8_t Flags;
        } START_COMPLETE;
        struct {
            uint64_t AbsoluteOffset;
            uint64_t TotalBufferLength;
            const QUIC_BUFFER* Buffers;
            uint32_t BufferCount;
            uint32_t Flags;
        } RECEIVE;
        struct {
            uint8_t Canceled;
            void* ClientContext;
        } SEND_COMPLETE;
        struct {
            QUIC_UINT62 ErrorCode;
        } PEER_SEND_ABORTED;
        struct {
            uint8_t Graceful;
        } SEND_SHUTDOWN_COMPLETE;
        struct {
            uint8_t ConnectionShutdown;
        } SHUTDOWN_COMPLETE;
    };
} QUIC_STREAM_EVENT;

typedef long (__cdecl * QUIC_STREAM_CALLBACK_HANDLER)(HQUIC Stream, void* Context, QUIC_STREAM_EVENT* Event);

// --- Flags ---

#define QUIC_STREAM_OPEN_FLAG_NONE           0x0000
#define QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL 0x0001

#define QUIC_STREAM_START_FLAG_NONE      0x0000
#define QUIC_STREAM_START_FLAG_IMMEDIATE 0x0001

#define QUIC_STREAM_SHUTDOWN_FLAG_NONE   0x0000
#define QUIC_STREAM_SHUTDOWN_FLAG_ABORT  0x0006

#define QUIC_CONNECTION_SHUTDOWN_FLAG_NONE 0x0000

#define QUIC_SEND_FLAG_NONE  0x0000
#define QUIC_SEND_FLAG_START 0x0002
#define QUIC_SEND_FLAG_FIN   0x0004

// --- Function pointer typedefs (only what we call) ---

typedef long (__cdecl * QUIC_SET_CALLBACK_HANDLER_FN)(HQUIC Handle, void* Handler, void* Context);

typedef long (__cdecl * QUIC_REGISTRATION_OPEN_FN)(const QUIC_REGISTRATION_CONFIG* Config, HQUIC* Registration);
typedef void (__cdecl * QUIC_REGISTRATION_CLOSE_FN)(HQUIC Registration);

typedef long (__cdecl * QUIC_CONFIGURATION_OPEN_FN)(HQUIC Registration, const QUIC_BUFFER* AlpnBuffers, uint32_t AlpnBufferCount, const void* Settings, uint32_t SettingsSize, void* Context, HQUIC* Configuration);
typedef void (__cdecl * QUIC_CONFIGURATION_CLOSE_FN)(HQUIC Configuration);
typedef long (__cdecl * QUIC_CONFIGURATION_LOAD_CREDENTIAL_FN)(HQUIC Configuration, const QUIC_CREDENTIAL_CONFIG* CredConfig);

typedef long (__cdecl * QUIC_CONNECTION_OPEN_FN)(HQUIC Registration, QUIC_CONNECTION_CALLBACK_HANDLER Handler, void* Context, HQUIC* Connection);
typedef void (__cdecl * QUIC_CONNECTION_CLOSE_FN)(HQUIC Connection);
typedef void (__cdecl * QUIC_CONNECTION_SHUTDOWN_FN)(HQUIC Connection, uint32_t Flags, QUIC_UINT62 ErrorCode);
typedef long (__cdecl * QUIC_CONNECTION_START_FN)(HQUIC Connection, HQUIC Configuration, QUIC_ADDRESS_FAMILY Family, const char* ServerName, uint16_t ServerPort);

typedef long (__cdecl * QUIC_STREAM_OPEN_FN)(HQUIC Connection, uint32_t Flags, QUIC_STREAM_CALLBACK_HANDLER Handler, void* Context, HQUIC* Stream);
typedef void (__cdecl * QUIC_STREAM_CLOSE_FN)(HQUIC Stream);
typedef long (__cdecl * QUIC_STREAM_START_FN)(HQUIC Stream, uint32_t Flags);
typedef long (__cdecl * QUIC_STREAM_SHUTDOWN_FN)(HQUIC Stream, uint32_t Flags, QUIC_UINT62 ErrorCode);
typedef long (__cdecl * QUIC_STREAM_SEND_FN)(HQUIC Stream, const QUIC_BUFFER* Buffers, uint32_t BufferCount, uint32_t Flags, void* ClientSendContext);

// Таблица функций v2 — порядок полей ДОЛЖЕН совпадать с реальным msquic.h
// вплоть до последнего используемого нами поля (StreamSend). Поля, которые мы
// не вызываем, объявлены как void* — так offset-ы следующих полей остаются верными.
typedef struct QUIC_API_TABLE {
    void* SetContext;
    void* GetContext;
    QUIC_SET_CALLBACK_HANDLER_FN SetCallbackHandler;

    void* SetParam;
    void* GetParam;

    QUIC_REGISTRATION_OPEN_FN     RegistrationOpen;
    QUIC_REGISTRATION_CLOSE_FN    RegistrationClose;
    void* RegistrationShutdown;

    QUIC_CONFIGURATION_OPEN_FN    ConfigurationOpen;
    QUIC_CONFIGURATION_CLOSE_FN   ConfigurationClose;
    QUIC_CONFIGURATION_LOAD_CREDENTIAL_FN ConfigurationLoadCredential;

    void* ListenerOpen;
    void* ListenerClose;
    void* ListenerStart;
    void* ListenerStop;

    QUIC_CONNECTION_OPEN_FN     ConnectionOpen;
    QUIC_CONNECTION_CLOSE_FN    ConnectionClose;
    QUIC_CONNECTION_SHUTDOWN_FN ConnectionShutdown;
    QUIC_CONNECTION_START_FN    ConnectionStart;
    void* ConnectionSetConfiguration;
    void* ConnectionSendResumptionTicket;

    QUIC_STREAM_OPEN_FN     StreamOpen;
    QUIC_STREAM_CLOSE_FN    StreamClose;
    QUIC_STREAM_START_FN    StreamStart;
    QUIC_STREAM_SHUTDOWN_FN StreamShutdown;
    QUIC_STREAM_SEND_FN     StreamSend;
    // Далее (StreamReceiveComplete, StreamReceiveSetEnabled, DatagramSend, ...) не используются и не объявлены.
} QUIC_API_TABLE;

typedef long (__cdecl * MsQuicOpenVersionFn)(uint32_t Version, const void** QuicApi);
typedef void (__cdecl * MsQuicCloseFn)(const void* QuicApi);

#define QUIC_API_VERSION_2 2

#endif // _MSQUIC_MIN_H_
