@echo off
rem Runs `driver_openvrlink.dll` against a mock `driver_vrlink.dll` on Windows.
rem Requires the Swift toolchain (`clang` compiles the C test files). Set
rem `VRLINK_FXO` to `driver_vrlink`'s `resources\shaders\d3d11` folder to also
rem exercise DXBC shader patching.
setlocal
set here=%~dp0
set out=%TEMP%\ovrl-driver-harness
if not exist "%out%\shaders" mkdir "%out%\shaders"
pushd "%here%..\.."
swift build -c release --static-swift-stdlib --product driver_openvrlink || exit /b 1
copy /y .build\release\driver_openvrlink.dll "%out%" >nul
popd
clang -O2 -w -shared -o "%out%\driver_vrlink.dll" "%here%fake_vrlink.c" -ld3dcompiler || exit /b 1
clang -O2 -w -o "%out%\harness.exe" "%here%harness.c" || exit /b 1
del /q "%out%\shaders\*.fxo" 2>nul
if defined VRLINK_FXO copy /y "%VRLINK_FXO%\*.fxo" "%out%\shaders" >nul
cd /d "%out%"
harness.exe
