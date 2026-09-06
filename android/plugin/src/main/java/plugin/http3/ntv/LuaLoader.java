// LuaLoader.java
// Загрузчик плагина plugin.http3.ntv на Android, вызываемый Solar2D.
// Делегирует выполнение внутренней реализации plugin.http3.native_stub.LuaLoaderInternal.
//
// ПОЧЕМУ ПАКЕТ НАЗЫВАЕТСЯ ntv, А НЕ native.
// Solar2D ищет загрузчик по имени требуемого модуля: require("a.b.c") ->
// класс a.b.c.LuaLoader. Раньше модуль звался plugin.http3.native, и пакет с
// сегментом native javac собрать не может — native является ключевым словом
// Java. Ради обхода этого класс писали на Kotlin, а весь kotlin-stdlib
// подмешивали в AAR. Расплата пришла на сборке приложения, где Kotlin уже
// есть: Duplicate class kotlin.ArrayIntrinsicsKt found in modules
// kotlin-stdlib-2.1.0.jar and plugin-release.aar.
//
// Сегмент ntv ключевым словом не является, поэтому загрузчик пишется на Java,
// а Kotlin из плагина убран целиком — вместе с kotlin-android, задачами сборки
// "толстого" AAR и зависимостью kotlin-stdlib.

package plugin.http3.ntv;

import com.naef.jnlua.JavaFunction;
import com.naef.jnlua.LuaState;

import plugin.http3.native_stub.LuaLoaderInternal;

public class LuaLoader implements JavaFunction {
    private final LuaLoaderInternal delegate = new LuaLoaderInternal();

    @Override
    public int invoke(LuaState L) {
        return delegate.invoke(L);
    }
}
