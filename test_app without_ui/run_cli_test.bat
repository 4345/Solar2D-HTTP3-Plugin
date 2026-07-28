@echo off
"C:\Program Files (x86)\Corona Labs\Corona\Native\Corona\win\bin\lua.exe" test_direct.lua > test_out.txt 2>&1
type test_out.txt
