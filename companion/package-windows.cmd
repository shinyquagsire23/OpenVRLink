@echo off
rem Builds the single-file Windows release (`openvrlink-companion-windows-x86_64.exe`) with
rem `driver_openvrlink.dll` embedded as a Win32 resource.
rem   package-windows.cmd [VERSION]     embeds VERSION into the binary (defaults to Release.sourceVersion)
setlocal
cd /d "%~dp0"
swift build -c release --static-swift-stdlib || exit /b 1
for /f "delims=" %%p in ('swift build -c release --static-swift-stdlib --show-bin-path') do set bin=%%p
set out=%~dp0.build\package
if not exist "%out%" mkdir "%out%"
set stamp=
if not "%~1"=="" set stamp=--version %~1
"%bin%\openvrlink-companion.exe" pack "%out%\openvrlink-companion-windows-x86_64.exe" --driver "%bin%\driver_openvrlink.dll" %stamp%
