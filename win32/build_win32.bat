@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars32.bat"
if not exist "%~dp0Release" mkdir "%~dp0Release"
cl /O2 /MD /LD /I"%~dp0..\shared" /I"C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\shared\include\Corona" /I"C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\shared\include\lua" "%~dp0..\shared\SimulatorPluginLibrary.cpp" "C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\win\lib\lua.lib" winhttp.lib kernel32.lib user32.lib /Fe"%~dp0Release\plugin_http3_native.dll"

echo === Updating Corona Simulator Cache ===
xcopy "%~dp0Release\plugin_http3_native.dll" "%APPDATA%\Corona Labs\Corona Simulator\Plugins\" /Y /I /E
xcopy "%~dp0..\lua\plugin_http3.lua" "%APPDATA%\Corona Labs\Corona Simulator\Plugins\" /Y /I /E

echo === Updating Solar2DPlugins Cache (ovh.azi) ===
if exist "%APPDATA%\Solar2DPlugins\ovh.azi\plugin.http3\win32-sim" (
    pushd "%~dp0Release"
    tar -czf "%APPDATA%\Solar2DPlugins\ovh.azi\plugin.http3\win32-sim\data.tgz" plugin_http3_native.dll
    popd
)

if exist "%APPDATA%\Solar2DPlugins\ovh.azi\plugin.http3\lua" (
    pushd "%~dp0..\lua"
    tar -czf "%APPDATA%\Solar2DPlugins\ovh.azi\plugin.http3\lua\data.tgz" plugin_http3.lua
    popd
)

echo === Build and Cache Deployment Complete ===
