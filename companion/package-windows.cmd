@echo off
rem Builds the single-file Windows release (`openvrlink-companion-windows-x86_64.exe`) with
rem `driver_openvrlink.dll`, the application icon, and Win32 version info embedded as resources.
rem   package-windows.cmd [VERSION]     embeds VERSION into the binary (defaults to <version>-<build>
rem                                     from version.json at the repository root)
setlocal
cd /d "%~dp0"
swift build -c release --static-swift-stdlib || exit /b 1
for /f "delims=" %%p in ('swift build -c release --static-swift-stdlib --show-bin-path') do set bin=%%p
set out=%~dp0.build\package
if not exist "%out%" mkdir "%out%"
set version=%~1
if "%version%"=="" if exist "%~dp0..\version.json" (
  for /f "delims=" %%v in ('powershell -NoProfile -Command "$v = Get-Content -Raw '%~dp0..\version.json' | ConvertFrom-Json; '{0}-{1}' -f $v.version, $v.build"') do set version=%%v
)
set stamp=
if not "%version%"=="" set stamp=--version %version%
"%bin%\openvrlink-companion.exe" pack "%out%\openvrlink-companion-windows-x86_64.exe" --driver "%bin%\driver_openvrlink.dll" --icon "%~dp0Resources\openvrlink-companion.ico" %stamp%
