@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars32.bat"
if not exist "%~dp0Release" mkdir "%~dp0Release"
cl /O2 /MD /LD /I"%~dp0..\shared" /I"C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\shared\include\Corona" /I"C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\shared\include\lua" "%~dp0..\shared\SimulatorPluginLibrary.cpp" "C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\win\lib\lua.lib" winhttp.lib kernel32.lib user32.lib /Fe"%~dp0Release\plugin_http3_native.dll"

if errorlevel 1 (
    echo === BUILD FAILED ===
    exit /b 1
)

echo === 1. Updating Corona Simulator Plugins Cache ===
if not exist "%APPDATA%\Corona Labs\Corona Simulator\Plugins" mkdir "%APPDATA%\Corona Labs\Corona Simulator\Plugins"
xcopy "%~dp0Release\plugin_http3_native.dll" "%APPDATA%\Corona Labs\Corona Simulator\Plugins\" /Y /I
xcopy "%~dp0..\lua\plugin_http3.lua" "%APPDATA%\Corona Labs\Corona Simulator\Plugins\" /Y /I

echo === 2. Updating Local Repository Plugins Folders ===
if exist "%~dp0..\plugins\win32-sim" (
    xcopy "%~dp0Release\plugin_http3_native.dll" "%~dp0..\plugins\win32-sim\" /Y /I
    pushd "%~dp0Release"
    tar -czf "%~dp0..\plugins\win32-sim\data.tgz" plugin_http3_native.dll
    popd
)

if exist "%~dp0..\plugins\win32" (
    xcopy "%~dp0Release\plugin_http3_native.dll" "%~dp0..\plugins\win32\" /Y /I
    pushd "%~dp0Release"
    tar -czf "%~dp0..\plugins\win32\data.tgz" plugin_http3_native.dll
    popd
)

if exist "%~dp0..\plugins\lua" (
    xcopy "%~dp0..\lua\plugin_http3.lua" "%~dp0..\plugins\lua\" /Y /I
    pushd "%~dp0..\lua"
    tar -czf "%~dp0..\plugins\lua\data.tgz" plugin_http3.lua
    popd
)

echo === 3. Updating Solar2DPlugins APPDATA Caches ===
for /d %%D in ("%APPDATA%\Solar2DPlugins\*") do (
    if exist "%%D\plugin.http3\win32-sim" (
        xcopy "%~dp0Release\plugin_http3_native.dll" "%%D\plugin.http3\win32-sim\" /Y /I
        pushd "%~dp0Release"
        tar -czf "%%D\plugin.http3\win32-sim\data.tgz" plugin_http3_native.dll
        popd
    )
    if exist "%%D\plugin.http3\win32" (
        xcopy "%~dp0Release\plugin_http3_native.dll" "%%D\plugin.http3\win32\" /Y /I
        pushd "%~dp0Release"
        tar -czf "%%D\plugin.http3\win32\data.tgz" plugin_http3_native.dll
        popd
    )
    if exist "%%D\plugin.http3\lua" (
        xcopy "%~dp0..\lua\plugin_http3.lua" "%%D\plugin.http3\lua\" /Y /I
        pushd "%~dp0..\lua"
        tar -czf "%%D\plugin.http3\lua\data.tgz" plugin_http3.lua
        popd
    )
)

echo === 4. Updating Test App Directory ===
if exist "%~dp0..\test_app" (
    xcopy "%~dp0Release\plugin_http3_native.dll" "%~dp0..\test_app\" /Y /I
    xcopy "%~dp0..\lua\plugin_http3.lua" "%~dp0..\test_app\" /Y /I
)

echo === Build and All 4 Cache Deployments Complete ===

