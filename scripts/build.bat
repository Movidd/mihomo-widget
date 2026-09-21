@echo off
rem ============================================================
rem  mihomo-widget  -  dev build (no admin manifest, quick)
rem
rem  Usage:
rem    build.bat            build only
rem    build.bat run        build, then launch the widget
rem ============================================================
setlocal
cd /d "%~dp0.."

set "ZIG=.tools\zig\zig-x86_64-windows-0.16.0\zig.exe"

if not exist "%ZIG%" (
    echo [ERROR] zig toolchain not found: %ZIG%
    exit /b 1
)

echo [1/1] Building dev (ReleaseSmall, no admin manifest)...
pushd app
call ..\%ZIG% build
if errorlevel 1 (
    popd
    echo.
    echo [ERROR] build failed.
    exit /b 1
)
popd

rem place the conf template next to the exe so the widget can read it and
rem remember its window position
if exist "app\cfg\mihomo-widget.conf" (
    copy /Y "app\cfg\mihomo-widget.conf" "app\zig-out\bin\mihomo-widget.conf" >nul
) else (
    echo [WARN] app\cfg\mihomo-widget.conf template missing - not copied
)

rem ---- dev runtime home (app\cfg) ----
rem The widget starts the core with -d = config file dir, i.e. app\cfg in dev, so the
rem rule-provider file and the geodata must exist there. direct.yaml is derived from
rem scripts\whitelist (convert_whitelist.ps1 -> .tools\mihomo\direct.yaml); geodata is
rem copied only when missing so geo-auto-update in app\cfg is not reverted.
if exist ".tools\mihomo\direct.yaml" copy /Y ".tools\mihomo\direct.yaml" "app\cfg\direct.yaml" >nul
if not exist "app\cfg\GeoIP.dat"   if exist ".tools\mihomo\GeoIP.dat"   copy /Y ".tools\mihomo\GeoIP.dat"   "app\cfg\GeoIP.dat" >nul
if not exist "app\cfg\GeoSite.dat" if exist ".tools\mihomo\GeoSite.dat" copy /Y ".tools\mihomo\GeoSite.dat" "app\cfg\GeoSite.dat" >nul

if not exist "app\cfg\config.yaml" (
    echo [WARN] app\cfg\config.yaml missing - the widget will fall back to mihomo_client.yaml
)

echo.
echo OK: app\zig-out\bin\mihomo-widget.exe (+ mihomo-widget.conf)

if /I "%~1"=="run" (
    echo Launching...
    start "" "app\zig-out\bin\mihomo-widget.exe"
)

endlocal