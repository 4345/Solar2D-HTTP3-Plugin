@echo off
rem Сборка ТОЛЬКО для стенда test_app. Кэши симулятора и Solar2DPlugins
rem не трогаются: в игре должна оставаться боевая сборка из ветки main.
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars32.bat" >nul
if not exist "%~dp0Stend" mkdir "%~dp0Stend"
pushd "%~dp0Stend"
cl /nologo /O2 /MD /LD /I"%~dp0..\shared" /I"C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\shared\include\Corona" /I"C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\shared\include\lua" "%~dp0..\shared\SimulatorPluginLibrary.cpp" "C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\win\lib\lua.lib" winhttp.lib kernel32.lib user32.lib /Fe"%~dp0Stend\plugin_http3_native.dll"
popd
if errorlevel 1 (
    echo === СБОРКА НЕ УДАЛАСЬ ===
    exit /b 1
)
copy /Y "%~dp0Stend\plugin_http3_native.dll" "%~dp0..\test_app\" >nul
copy /Y "%~dp0..\lua\plugin_http3.lua" "%~dp0..\test_app\" >nul
echo === Стенд собран: test_app обновлён, кэши игры не тронуты ===
