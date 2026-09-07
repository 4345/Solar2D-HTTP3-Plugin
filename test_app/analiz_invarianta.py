# -*- coding: utf-8 -*-
# Проверка инварианта пула по журналу: соединение, выданное запросу, не должно
# выдаваться второму, пока первый не вернул его в пул.
import io, re
import os
# Путь берём из окружения: журнал плагин пишет во временный каталог.
put = os.path.join(os.environ.get("TEMP", "."), "plugin_http3.log")
vzyat  = re.compile(r"^(\d+) \[(\d+)\] Пул: НАЙДЕНО тёплое соединение = (\d+)")
vernut = re.compile(r"^(\d+) \[(\d+)\] Пул: соединение (?:СОХРАНЕНО|ОСВОБОЖДЕНО) = (\d+)")
zakryt = re.compile(r"^(\d+) \[(\d+)\] Пул: закрываю соединение")

zanyato = {}
narusheniya = []
vzyatiy = vozvratov = 0
uderzhaniya = []

for stroka in io.open(put, encoding="utf-8", errors="replace"):
    m = vzyat.match(stroka)
    if m:
        t, potok, adres = int(m.group(1)), m.group(2), m.group(3)
        vzyatiy += 1
        if adres in zanyato:
            narusheniya.append((adres, zanyato[adres], (t, potok)))
        zanyato[adres] = (t, potok)
        continue
    m = vernut.match(stroka)
    if m:
        t, adres = int(m.group(1)), m.group(3)
        vozvratov += 1
        if adres in zanyato:
            uderzhaniya.append(t - zanyato[adres][0])
            del zanyato[adres]

print("взятий из пула: %d, возвратов: %d" % (vzyatiy, vozvratov))
if uderzhaniya:
    uderzhaniya.sort()
    print("соединение было занято: медиана %d мс, максимум %d мс, дольше 2 с: %d раз" %
          (uderzhaniya[len(uderzhaniya)//2], uderzhaniya[-1],
           sum(1 for u in uderzhaniya if u > 2000)))
print("НАРУШЕНИЙ ИНВАРИАНТА (занятое соединение выдали второму запросу): %d" % len(narusheniya))
for n in narusheniya[:5]:
    print("   адрес %s: держал поток %s с %d, выдали потоку %s в %d" %
          (n[0], n[1][1], n[1][0], n[2][1], n[2][0]))

# Вторая проверка: закрывалось ли соединение, пока оно занято запросом.
zanyato2 = {}
zakryto_zanyatym = []
zakrytiy = 0
for stroka in io.open(put, encoding="utf-8", errors="replace"):
    m = vzyat.match(stroka)
    if m:
        zanyato2[m.group(3)] = (int(m.group(1)), m.group(2)); continue
    m = vernut.match(stroka)
    if m:
        zanyato2.pop(m.group(3), None); continue
    m = re.match(r"^(\d+) \[(\d+)\] Пул: закрываю соединение = (\d+)", stroka)
    if m:
        zakrytiy += 1
        if m.group(3) in zanyato2:
            zakryto_zanyatym.append((m.group(3), int(m.group(1))))
print("")
print("закрытий соединений: %d" % zakrytiy)
print("ЗАКРЫТО ЗАНЯТОЕ СОЕДИНЕНИЕ: %d" % len(zakryto_zanyatym))
for z in zakryto_zanyatym[:5]:
    print("   адрес %s в %d" % z)
