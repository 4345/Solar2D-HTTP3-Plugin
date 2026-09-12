#!/usr/bin/env python3
"""Пересборка архивов платформ плагина Solar2D HTTP/3.

Solar2D берёт при сборке ИМЕННО data.tgz, а не файлы рядом с ним, — и
рассинхрон между ними уже стоил рабочего HTTP/3: в архивах win32, win32-sim и
android не было Lua-обёртки plugin_http3.lua, приложение молча оставалось на
TCP.

Обёртка обязательна КАЖДОЙ платформе: модуль плагина называется plugin.http3,
и это именно она. Нативная библиотека объявляет plugin.http3.ntv (и
plugin.http3.native), а plugin.http3 не объявляет вовсе — одной её для require
мало. Скрипт подкладывает обёртку сам, из lua/plugin_http3.lua.

Apple-платформы (iphone, iphone-sim, macOS, mac-sim) здесь НЕ собираются:
нативную часть им даёт clang, а он есть только на macOS. Их архивы делает
Apple/build.sh, запускать его надо на маке. Здесь они только проверяются.

Android вдобавок несёт нативную библиотеку plugin-release.aar. Она собирается
из Java (android/plugin/src) через Gradle, и её тоже надо обновлять: правка в
Java, не дошедшая до архива, просто не попадёт на устройство. Скрипт сам
запускает сборку, если исходники новее архива.

Прежде этот скрипт был на PowerShell и жил только под Windows — ровно на той
машине, на которой Apple-часть и не собирается. Перенесён на Python: теперь
проверка состава архивов доступна и на маке, где эта часть как раз и делается.

Запуск (из любого каталога, нужен Python 3.8+):
    python3 tools/sobrat_arhivy.py
    python3 tools/sobrat_arhivy.py --proverit     # только проверить состав
    python3 tools/sobrat_arhivy.py --bez-gradle   # не трогать AAR
"""

import argparse
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

KOREN = Path(__file__).resolve().parent.parent
OBERTKA = KOREN / "lua" / "plugin_http3.lua"

# Платформы, чей архив собирается из файлов рядом. Apple — см. заголовок.
PLATFORMY = ("win32", "win32-sim", "android", "lua")

# Что обязано лежать в архиве Apple-платформы. Проверяем ПО СОСТАВУ, а не по
# одному файлу: прежде здесь искалась только Lua-обёртка, и проверка месяцами
# показывала зелёное на архивах iphone и iphone-sim, в которых нативной
# библиотеки не было вовсе. Обёртка есть — значит порядок. Плагин при этом
# молча работал по TCP.
APPLE_SOSTAV = {
    "iphone": "libplugin_http3_native.a",
    "iphone-sim": "libplugin_http3_native.a",
    "macOS": "plugin_http3.dylib",
    "mac-sim": "plugin_http3.dylib",
}

KRASNYY, ZELENYY, ZHELTYY, SBROS = "\033[31m", "\033[32m", "\033[33m", "\033[0m"


def pishem(tekst, cvet=None):
    if cvet and sys.stdout.isatty():
        print(f"{cvet}{tekst}{SBROS}")
    else:
        print(tekst)


class Schetchik:
    """Счётчик ошибок: он же код возврата."""

    def __init__(self):
        self.n = 0

    def oshibka(self, tekst):
        pishem(tekst, KRASNYY)
        self.n += 1


def sovpadayut(a: Path, b: Path) -> bool:
    return a.is_file() and b.is_file() and a.read_bytes() == b.read_bytes()


def otslezhivaemye(papka: Path):
    """Имена файлов платформы, которые знает git.

    ТОЛЬКО ОТСЛЕЖИВАЕМОЕ. Прежде паковалось всё подряд, и в win32-архив уехал
    msquic.dll, лежавший рядом от сборки стенда: в репозитории его нет, у
    другого человека архив собрался бы иным, а опубликованный отличался бы от
    исходников молча. Не репозиторий или git не ответил — возвращаем None,
    вызывающий откатится на прежнее поведение и СКАЖЕТ об этом.
    """
    try:
        gotovo = subprocess.run(
            ["git", "-C", str(papka), "ls-files"],
            capture_output=True, text=True, check=False,
        )
    except OSError:
        return None
    if gotovo.returncode != 0 or not gotovo.stdout.strip():
        return None
    # Имена приходят относительно papka; вложенные каталоги архиву не нужны —
    # он плоский.
    return [
        s for s in gotovo.stdout.splitlines()
        if s and "/" not in s and s != "data.tgz"
    ]


def sobrat_arhiv(papka: Path, imena):
    """Плоский data.tgz: Solar2D распаковывает его как есть.

    tarfile вместо внешнего tar — ради одинакового поведения на Windows и
    macOS. Заодно снимает две старые занозы: ._-спутники ресурсных вилок,
    которые tar на маке кладёт рядом с настоящими файлами, и мусор из
    окружения, который внешний tar получал из PowerShell-массива.
    """
    arhiv = papka / "data.tgz"
    vremennyy = papka / "data.tgz.tmp"
    try:
        with tarfile.open(vremennyy, "w:gz") as t:
            for imya in sorted(imena):
                t.add(papka / imya, arcname=imya)
        vremennyy.replace(arhiv)
    finally:
        vremennyy.unlink(missing_ok=True)


def sostav(arhiv: Path):
    with tarfile.open(arhiv, "r:gz") as t:
        return t.getnames()


def nayti_gradle():
    """Обёртка Gradle и JDK к ней.

    JAVA_HOME у Android Studio лежит в jbr; своего JDK в системе может не быть
    вовсе, и без подсказки Gradle не стартует.
    """
    android = KOREN / "android"
    obertka = android / ("gradlew.bat" if os.name == "nt" else "gradlew")
    if not obertka.exists():
        return None, None

    java_home = os.environ.get("JAVA_HOME")
    if not java_home:
        kandidaty = [
            r"C:\Program Files\Android\Android Studio\jbr",
            r"C:\Program Files\Android\Android Studio\jre",
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
            "/Applications/Android Studio.app/Contents/jre/Contents/Home",
        ]
        for k in kandidaty:
            if Path(k).is_dir():
                java_home = k
                break
    return obertka, java_home


def obnovit_aar(schet: Schetchik):
    """Пересобирает AAR, если Java новее архива.

    Не находим JDK или Gradle падает — ГРОМКО пишем и идём дальше: у
    стороннего человека с публичным репозиторием может не быть
    Android-окружения вовсе, а Lua-часть собрать он всё равно должен.
    """
    ishodniki = KOREN / "android" / "plugin" / "src"
    gotovyy = KOREN / "plugins" / "android" / "plugin-release.aar"
    if not ishodniki.is_dir():
        return

    svezhest = max(
        (f.stat().st_mtime for f in ishodniki.rglob("*") if f.is_file()),
        default=0,
    )
    # ДОПУСК В ДВЕ СЕКУНДЫ. Свежесть меряется временем правки файла, а git
    # ставит его по МОМЕНТУ ВЫКЛАДКИ: после клона у Java-исходников и у AAR
    # оно одно и то же с точностью до долей секунды, и кто окажется «новее» —
    # дело случая. Прежняя проверка сравнивала строго и на свежем клоне
    # требовала Gradle на ровном месте: без JDK скрипт падал с ошибкой, ничего
    # на деле не устарело. Настоящая правка в Java отстоит от сборки на минуты,
    # в допуск она не попадает.
    if gotovyy.exists() and svezhest <= gotovyy.stat().st_mtime + 2:
        pishem("[android] AAR свежий, Gradle не нужен")
        return

    obertka, java_home = nayti_gradle()
    if obertka is None:
        schet.oshibka("[android] нет android/gradlew — AAR остаётся прежним, правки в Java НЕ доедут")
        return
    if not java_home:
        schet.oshibka("[android] JDK не найден — AAR остаётся прежним, правки в Java НЕ доедут")
        return

    okruzhenie = dict(os.environ, JAVA_HOME=java_home)
    gotovo = subprocess.run(
        [str(obertka), ":plugin:assembleRelease", "--console=plain", "-q"],
        cwd=KOREN / "android", env=okruzhenie, check=False,
    )
    if gotovo.returncode != 0:
        schet.oshibka(f"[android] Gradle вернул {gotovo.returncode} — AAR остаётся прежним")
        return

    sobrannyy = KOREN / "android" / "plugin" / "build" / "outputs" / "aar" / "plugin-release.aar"
    if not sobrannyy.exists():
        schet.oshibka(f"[android] Gradle отработал, но AAR не найден: {sobrannyy}")
        return

    shutil.copy2(sobrannyy, gotovyy)
    pishem("[android] AAR пересобран из Java")


def sobrat_platformu(p: str, schet: Schetchik, tolko_proverit: bool):
    papka = KOREN / "plugins" / p
    if not papka.is_dir():
        pishem(f"[{p}] каталога нет — пропуск", ZHELTYY)
        return
    arhiv = papka / "data.tgz"

    if not tolko_proverit:
        # Обёртка должна лежать рядом — тогда она попадёт и в архив.
        svoya = papka / "plugin_http3.lua"
        if not sovpadayut(svoya, OBERTKA):
            shutil.copy2(OBERTKA, svoya)
            pishem(f"[{p}] обёртка обновлена из lua/plugin_http3.lua")

        fayly = otslezhivaemye(papka)
        if fayly is None:
            pishem(f"[{p}] git не ответил — пакую всё, что лежит рядом", ZHELTYY)
            fayly = [f.name for f in papka.iterdir() if f.is_file() and f.name != "data.tgz"]
        if not fayly:
            pishem(f"[{p}] рядом с архивом нет файлов — пропуск", ZHELTYY)
            return
        sobrat_arhiv(papka, fayly)

    if not arhiv.exists():
        schet.oshibka(f"[{p}] архива нет: {arhiv}")
        return

    # Проверка состава — и после сборки, и в режиме --proverit.
    imena = sostav(arhiv)
    est_obertka = "plugin_http3.lua" in imena
    znak = "OK " if est_obertka else "НЕТ"
    pishem(f"[{p}] {znak} обёртка; в архиве: {', '.join(imena)}",
           ZELENYY if est_obertka else KRASNYY)
    if not est_obertka:
        schet.n += 1


def proverit_apple(schet: Schetchik):
    for p, nativnaya in APPLE_SOSTAV.items():
        arhiv = KOREN / "plugins" / p / "data.tgz"
        if not arhiv.exists():
            continue
        imena = sostav(arhiv)
        nuzhno = ["plugin_http3.lua", "metadata.lua", nativnaya]
        net = [n for n in nuzhno if n not in imena]
        if not net:
            pishem(f"[{p}] OK  {', '.join(imena)} (архив собирает Apple/build.sh)", ZELENYY)
        else:
            schet.oshibka(
                f"[{p}] НЕТ в архиве: {', '.join(net)} — пересоберите на маке: Apple/build.sh"
            )


def main():
    razbor = argparse.ArgumentParser(
        description="Пересборка data.tgz платформ плагина Solar2D HTTP/3",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    razbor.add_argument("--proverit", action="store_true",
                        help="только проверить состав, ничего не пересобирая")
    razbor.add_argument("--bez-gradle", action="store_true",
                        help="не трогать AAR, взять какой лежит")
    dovody = razbor.parse_args()

    if not OBERTKA.is_file():
        pishem(f"[ОШИБКА] нет {OBERTKA} — собирать не из чего", KRASNYY)
        return 1

    schet = Schetchik()

    if not dovody.proverit and not dovody.bez_gradle:
        obnovit_aar(schet)

    for p in PLATFORMY:
        sobrat_platformu(p, schet, dovody.proverit)

    # Apple-архивы только проверяем: собираются они отдельно, на маке.
    proverit_apple(schet)

    if schet.n:
        pishem(f"Платформ с ошибками: {schet.n}", KRASNYY)
        return 1
    pishem("Все архивы на месте и несут Lua-обёртку.", ZELENYY)
    return 0


if __name__ == "__main__":
    sys.exit(main())
