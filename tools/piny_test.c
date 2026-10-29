// Проверка shared/piny.h — привязки открытых ключей: SHA-256, base64, разбор
// DER до SubjectPublicKeyInfo и решение по набору. Без сети и платформы.
//
//   Windows (MSVC):  cl /nologo /W3 tools\piny_test.c /Fe:%TEMP%\piny_test.exe && %TEMP%\piny_test.exe
//   macOS / Linux:   cc -Wall -o /tmp/piny_test tools/piny_test.c && /tmp/piny_test
//
// Обратная проверка — в самом тесте: искажённый сертификат и чужой отпечаток
// обязаны НЕ проходить, иначе проверка ничего не стоит.
#define _CRT_SECURE_NO_WARNINGS
#include <stdio.h>
#include <string.h>

#include "../shared/piny.h"
#include "piny_test_dannye.h"

static int provalov = 0;

static void proverit(const char* imya, int uslovie) {
    printf("%s  %s\n", uslovie ? "PASS" : "FAIL", imya);
    if (!uslovie) provalov++;
}

static void hex(const uint8_t* h, char* out) {
    for (int i = 0; i < 32; i++) sprintf(out + i * 2, "%02x", h[i]);
}

int main(void) {
    uint8_t h[32];
    char s[65];

    // SHA-256 — векторы FIPS 180-4 и граничные длины блока.
    piny_sha256((const uint8_t*)"abc", 3, h); hex(h, s);
    proverit("SHA-256 \"abc\"", strcmp(s, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") == 0);
    piny_sha256((const uint8_t*)"", 0, h); hex(h, s);
    proverit("SHA-256 пустой строки", strcmp(s, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") == 0);
    const char* v56 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    piny_sha256((const uint8_t*)v56, strlen(v56), h); hex(h, s);
    proverit("SHA-256 56 байт (дополнение во второй блок)", strcmp(s, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1") == 0);
    static uint8_t tysyacha[1000];
    memset(tysyacha, 'a', sizeof(tysyacha));
    piny_sha256(tysyacha, sizeof(tysyacha), h); hex(h, s);
    proverit("SHA-256 1000 байт", strcmp(s, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3") == 0);

    // Отпечатки ключей настоящих сертификатов — как у OpenSSL.
    PinyNabor nabor;
    memset(&nabor, 0, sizeof(nabor));
    for (size_t i = 0; i < sizeof(piny_obrazcy) / sizeof(piny_obrazcy[0]); i++) {
        const PinyObrazec* o = &piny_obrazcy[i];
        uint8_t ozhid[32];
        int razobran = piny_otpechatok(o->otpechatok, ozhid);
        const uint8_t* spki; size_t dlina;
        int est = piny_spki(o->der, o->dlina, &spki, &dlina);
        uint8_t fakt[32];
        if (est) piny_sha256(spki, dlina, fakt);
        char imya[128];
        snprintf(imya, sizeof(imya), "отпечаток ключа %s совпадает с OpenSSL", o->imya);
        proverit(imya, razobran && est && memcmp(ozhid, fakt, 32) == 0);
    }

    // Префикс "sha256/" и неверные строки.
    uint8_t a[32], b[32];
    proverit("отпечаток с префиксом sha256/ — тот же",
             piny_otpechatok("sha256/C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=", a)
             && piny_otpechatok("C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=", b) && memcmp(a, b, 32) == 0);
    proverit("короткий отпечаток не принят", !piny_otpechatok("C5+lpZ7tcVwmwQIM", a));
    proverit("мусор не принят", !piny_otpechatok("не base64", a));

    // Набор: Root YE и X2 (без X1).
    nabor.hostov = 2;
    strcpy(nabor.hosty[0], "a.example.com");
    strcpy(nabor.hosty[1], "b.example.com");
    nabor.klyuchey = 2;
    piny_otpechatok(piny_obrazcy[1].otpechatok, nabor.klyuchi[0]);
    piny_otpechatok(piny_obrazcy[2].otpechatok, nabor.klyuchi[1]);
    nabor.do_sekund = 2000000000.0;
    proverit("хост из списка — под привязкой", piny_host_pod_privyazkoy(&nabor, "a.example.com", 1800000000.0));
    proverit("регистр не важен", piny_host_pod_privyazkoy(&nabor, "B.Example.COM", 1800000000.0));
    proverit("поддомен — не под привязкой", !piny_host_pod_privyazkoy(&nabor, "x.a.example.com", 1800000000.0));
    proverit("похожий хост — не под привязкой", !piny_host_pod_privyazkoy(&nabor, "a.example.co", 1800000000.0));
    proverit("срок вышел — не под привязкой", !piny_host_pod_privyazkoy(&nabor, "a.example.com", 2000000000.0));
    proverit("Root YE — в наборе", piny_klyuch_v_nabore(&nabor, piny_obrazcy[1].der, piny_obrazcy[1].dlina));
    proverit("ISRG Root X2 — в наборе", piny_klyuch_v_nabore(&nabor, piny_obrazcy[2].der, piny_obrazcy[2].dlina));
    // Обратные: ключа нет в наборе, сертификат искажён.
    proverit("ISRG Root X1 вне набора — не принят", !piny_klyuch_v_nabore(&nabor, piny_obrazcy[3].der, piny_obrazcy[3].dlina));
    proverit("промежуточный YE1 вне набора — не принят", !piny_klyuch_v_nabore(&nabor, piny_obrazcy[0].der, piny_obrazcy[0].dlina));
    static uint8_t isporchen[4096];
    memcpy(isporchen, piny_obrazcy[1].der, piny_obrazcy[1].dlina);
    const uint8_t* spki; size_t dlina;
    piny_spki(isporchen, piny_obrazcy[1].dlina, &spki, &dlina);
    isporchen[(spki - isporchen) + dlina - 1] ^= 1; // последний байт ключа
    proverit("ключ искажён на бит — не принят", !piny_klyuch_v_nabore(&nabor, isporchen, piny_obrazcy[1].dlina));
    proverit("обрезанный DER не разбирается", !piny_spki(piny_obrazcy[1].der, 100, &spki, &dlina));

    printf("\nПРОВАЛОВ: %d\n", provalov);
    return provalov ? 1 : 0;
}
