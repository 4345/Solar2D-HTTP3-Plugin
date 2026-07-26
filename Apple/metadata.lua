-- 3/metadata.lua
-- Метаданные плагина Solar2D для сборки под платформы
return {
    plugin = {
        format = 'staticLibrary',
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
