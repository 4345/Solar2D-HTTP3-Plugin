// LuaLoader.kt
// Kotlin-загрузчик для плагина plugin.http3.native на Android.
// Использует Kotlin для обхода ограничений Java на имя пакета с ключевым словом "native".
// Делегирует выполнение Java-классу LuaLoaderInternal.

package plugin.http3.native

import com.naef.jnlua.LuaState
import com.naef.jnlua.JavaFunction
import plugin.http3.native_stub.LuaLoaderInternal

// Класс-загрузчик плагина, вызываемый Solar2D
class LuaLoader : JavaFunction {
    private val delegate = LuaLoaderInternal()

    override fun invoke(L: LuaState): Int {
        // Перенаправляем вызов во внутреннюю Java-реализацию
        return delegate.invoke(L)
    }
}
