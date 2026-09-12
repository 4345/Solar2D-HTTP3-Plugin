-- metadata.lua
-- Метаданные плагина Solar2D для сборки под поддерживаемые платформы.
--
-- КЛЮЧ staticLibs ОБЯЗАТЕЛЕН. Сборщик iOS (libtemplate/Builder.lua внутри
-- Solar2D) читает metadata.plugin.staticLibs и передаёт каждый элемент
-- компоновщику как -l<элемент>, а каталог плагина добавляет в пути поиска.
-- Здесь стоял ОДИН staticLibraryName — ключ, которого сборщик не знает вовсе:
-- библиотека не попадала в команду компоновки, символа luaopen_plugin_http3_ntv
-- в приложении не оказывалось, и require молча откатывался на network.request.
-- То же и с frameworks: сборщик читает их с верхнего уровня, а не из таблиц
-- iphoneos / iphonesimulator.
--
-- Имя библиотеки в архиве платформы: lib<элемент staticLibs>.a, то есть
-- libplugin_http3_native.a.
return {
    plugin = {
        format = 'staticLibrary',

        -- Читает сборщик iOS/tvOS.
        staticLibs = { 'plugin_http3_native' },
        frameworks = { "Foundation", "Network" },
        frameworksOptional = {},

        -- Прежнее имя ключа. Оставлено: его понимают сторонние скрипты
        -- выкладки, сборщику Solar2D оно безразлично.
        staticLibraryName = 'plugin_http3_native',

        iphoneos = {
            frameworks = { "Foundation", "Network" },
            minOSVersion = "12.0",
        },
        iphonesimulator = {
            frameworks = { "Foundation", "Network" },
            minOSVersion = "12.0",
        },
        macosx = {
            frameworks = { "Foundation", "Network" },
            minOSVersion = "10.14",
        },
        win32 = {
            minOSVersion = "6.1",
        }
    }
}
