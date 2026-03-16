@echo off
setlocal

set OPTS=-Doptimize=ReleaseFast

echo building all platforms...
echo.
echo note: macOS builds require running on a Mac (Apple doesn't
echo       allow distributing their SDK frameworks for cross-compilation).
echo.

echo [1/3] x86_64-windows
zig build %OPTS% -Dtarget=x86_64-windows -p dist\windows-x64
if errorlevel 1 goto :fail

echo [2/3] aarch64-windows
zig build %OPTS% -Dtarget=aarch64-windows -p dist\windows-arm64
if errorlevel 1 goto :fail

echo [3/3] x86_64-linux
zig build %OPTS% -Dtarget=x86_64-linux -p dist\linux-x64
if errorlevel 1 goto :fail

echo.
echo done:
echo   dist\windows-x64\bin\clicktrack.exe
echo   dist\windows-arm64\bin\clicktrack.exe
echo   dist\linux-x64\bin\clicktrack
echo.
echo to build for macOS, run on a Mac:
echo   zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos -p dist/macos-x64
echo   zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos -p dist/macos-arm64
exit /b 0

:fail
echo.
echo build failed.
exit /b 1
