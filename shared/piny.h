//-----------------------------------------------------------------------------
// piny.h — привязка открытых ключей (SPKI pinning), общая для Windows
// (SimulatorPluginLibrary.cpp) и iOS/macOS (SimulatorPluginLibrary.mm).
//
// Набор задаёт приложение (http3.setPins): хосты поимённо, отпечатки SHA-256
// от SubjectPublicKeyInfo в base64 и срок набора. Пока срок не вышел, ответ
// хоста из списка принимается, только если в ПРОВЕРЕННОЙ системой цепочке
// (лист, промежуточные, корень) есть ключ из набора. Срок нужен, чтобы
// приложение, которое давно не обновляли, не осталось без связи, когда
// удостоверяющий центр сменит ключи: после срока проверка — только
// системная, как без привязки.
//
// Здесь только то, что не зависит от платформы: разбор DER сертификата до
// SubjectPublicKeyInfo, SHA-256, base64 и сам набор. Цепочку достаёт и
// проверяет платформа (CryptoAPI, Security.framework) и отдаёт сюда DER
// каждого сертификата. Своя SHA-256 вместо системной — чтобы один и тот же
// код считался одинаково на обеих платформах и проверялся одним стендом.
//
// Без CRT: файл .cpp обходится своими строковыми функциями, и этот — тоже.
//-----------------------------------------------------------------------------
#ifndef PLUGIN_HTTP3_PINY_H
#define PLUGIN_HTTP3_PINY_H

#include <stdint.h>
#include <stddef.h>

#define PINY_HOSTOV 16
#define PINY_KLYUCHEY 8
#define PINY_DLINA_HOSTA 256

typedef struct PinyNabor {
    char hosty[PINY_HOSTOV][PINY_DLINA_HOSTA];
    int hostov;
    uint8_t klyuchi[PINY_KLYUCHEY][32];
    int klyuchey;
    double do_sekund; // Unix-время конца срока набора
} PinyNabor;

// --- SHA-256 (FIPS 180-4) ----------------------------------------------------

static const uint32_t piny_k256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define PINY_ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void piny_sha256_blok(uint32_t h[8], const uint8_t b[64]) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)b[i * 4] << 24) | ((uint32_t)b[i * 4 + 1] << 16) | ((uint32_t)b[i * 4 + 2] << 8) | b[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = PINY_ROTR(w[i - 15], 7) ^ PINY_ROTR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = PINY_ROTR(w[i - 2], 17) ^ PINY_ROTR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = PINY_ROTR(e, 6) ^ PINY_ROTR(e, 11) ^ PINY_ROTR(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = hh + S1 + ch + piny_k256[i] + w[i];
        uint32_t S0 = PINY_ROTR(a, 2) ^ PINY_ROTR(a, 13) ^ PINY_ROTR(a, 22);
        uint32_t mj = (a & bb) ^ (a & c) ^ (bb & c);
        uint32_t t2 = S0 + mj;
        hh = g; g = f; f = e; e = d + t1; d = c; c = bb; bb = a; a = t1 + t2;
    }
    h[0] += a; h[1] += bb; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static void piny_sha256(const uint8_t* d, size_t n, uint8_t out[32]) {
    uint32_t h[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    size_t i = 0;
    for (; i + 64 <= n; i += 64) piny_sha256_blok(h, d + i);
    uint8_t hvost[128];
    size_t ost = n - i;
    for (size_t k = 0; k < ost; k++) hvost[k] = d[i + k];
    hvost[ost] = 0x80;
    size_t dlina = (ost + 1 + 8 <= 64) ? 64 : 128;
    for (size_t k = ost + 1; k < dlina - 8; k++) hvost[k] = 0;
    uint64_t bit = (uint64_t)n * 8;
    for (int k = 0; k < 8; k++) hvost[dlina - 1 - k] = (uint8_t)(bit >> (8 * k));
    piny_sha256_blok(h, hvost);
    if (dlina == 128) piny_sha256_blok(h, hvost + 64);
    for (int k = 0; k < 8; k++) {
        out[k * 4] = (uint8_t)(h[k] >> 24); out[k * 4 + 1] = (uint8_t)(h[k] >> 16);
        out[k * 4 + 2] = (uint8_t)(h[k] >> 8); out[k * 4 + 3] = (uint8_t)h[k];
    }
}

// --- base64 -----------------------------------------------------------------

static int piny_b64_znachenie(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

// Отпечаток из строки "sha256/<base64>" или "<base64>": ровно 32 байта.
// 1 — разобран, 0 — не отпечаток SHA-256.
static int piny_otpechatok(const char* s, uint8_t out[32]) {
    if (!s) return 0;
    const char* pref = "sha256/";
    int p = 0;
    while (pref[p] && s[p] == pref[p]) p++;
    if (!pref[p]) s += p;
    uint32_t nakopl = 0;
    int bitov = 0, n = 0, konec = 0;
    for (; *s; s++) {
        if (*s == '=') { konec = 1; continue; }
        if (konec) return 0;
        int v = piny_b64_znachenie(*s);
        if (v < 0) return 0;
        nakopl = (nakopl << 6) | (uint32_t)v;
        bitov += 6;
        if (bitov >= 8) {
            bitov -= 8;
            if (n >= 32) return 0;
            out[n++] = (uint8_t)(nakopl >> bitov);
        }
    }
    return n == 32;
}

// --- DER --------------------------------------------------------------------

// Заголовок элемента DER в p (n байт): тег, длина заголовка и длина
// содержимого. 1 — разобран и умещается в n, 0 — нет.
static int piny_der_element(const uint8_t* p, size_t n, uint8_t* teg, size_t* zag, size_t* dlina) {
    if (n < 2) return 0;
    *teg = p[0];
    if ((p[0] & 0x1f) == 0x1f) return 0; // многобайтных тегов в сертификате нет
    size_t d = p[1], z = 2;
    if (d & 0x80) {
        size_t baytov = d & 0x7f;
        if (baytov == 0 || baytov > 4 || n < 2 + baytov) return 0;
        d = 0;
        for (size_t i = 0; i < baytov; i++) d = (d << 8) | p[2 + i];
        z = 2 + baytov;
    }
    if (d > n - z) return 0;
    *zag = z;
    *dlina = d;
    return 1;
}

// SubjectPublicKeyInfo сертификата в DER — целиком, с тегом и длиной: от него
// и считается отпечаток (RFC 7469). Certificate ::= SEQUENCE { tbsCertificate
// SEQUENCE { [0] version OPTIONAL, serialNumber, signature, issuer, validity,
// subject, subjectPublicKeyInfo, ... }, ... }. 1 — найден.
static int piny_spki(const uint8_t* der, size_t n, const uint8_t** spki, size_t* spki_dlina) {
    uint8_t teg; size_t z, d;
    if (!piny_der_element(der, n, &teg, &z, &d) || teg != 0x30) return 0;
    const uint8_t* p = der + z; size_t ost = d;
    if (!piny_der_element(p, ost, &teg, &z, &d) || teg != 0x30) return 0; // tbsCertificate
    p += z; ost = d;
    if (!piny_der_element(p, ost, &teg, &z, &d)) return 0;
    if (teg == 0xa0) { p += z + d; ost -= z + d; } // version
    // serialNumber, signature, issuer, validity, subject — пропустить
    for (int i = 0; i < 5; i++) {
        if (!piny_der_element(p, ost, &teg, &z, &d)) return 0;
        p += z + d; ost -= z + d;
    }
    if (!piny_der_element(p, ost, &teg, &z, &d) || teg != 0x30) return 0;
    *spki = p;
    *spki_dlina = z + d;
    return 1;
}

// --- Набор ------------------------------------------------------------------

static int piny_bukva(char c) { return (c >= 'A' && c <= 'Z') ? c - 'A' + 'a' : c; }

// Хост под привязкой: набор задан, срок не вышел, хост — в списке (поимённо,
// без поддоменов; регистр не важен).
static int piny_host_pod_privyazkoy(const PinyNabor* p, const char* host, double seychas) {
    if (!p || !host || p->hostov <= 0 || p->klyuchey <= 0 || seychas >= p->do_sekund) return 0;
    for (int i = 0; i < p->hostov; i++) {
        const char* a = p->hosty[i];
        const char* b = host;
        while (*a && *b && piny_bukva(*a) == piny_bukva(*b)) { a++; b++; }
        if (!*a && !*b) return 1;
    }
    return 0;
}

// Ключ сертификата (DER) — из набора. 1 — да.
static int piny_klyuch_v_nabore(const PinyNabor* p, const uint8_t* der, size_t n) {
    const uint8_t* spki; size_t dlina;
    if (!piny_spki(der, n, &spki, &dlina)) return 0;
    uint8_t h[32];
    piny_sha256(spki, dlina, h);
    for (int i = 0; i < p->klyuchey; i++) {
        int ravny = 1;
        for (int k = 0; k < 32; k++) if (p->klyuchi[i][k] != h[k]) { ravny = 0; break; }
        if (ravny) return 1;
    }
    return 0;
}

#endif
