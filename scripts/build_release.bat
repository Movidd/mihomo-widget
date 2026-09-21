@echo off
rem ============================================================
rem  mihomo-widget  -  release bundle (admin build) + zip
rem
rem  Layout in release\mihomo-widget-<version>-<arch>\:
rem    mihomo-widget.exe  mihomo-widget.conf          <- the widget + its conf (root
rem                                                     stays readable: exe, conf, log)
rem    mihomo\  mihomo.exe  config.yaml.example       <- the core and everything it reads:
rem             GeoIP.dat  GeoSite.dat  direct.yaml      -d = this folder, so the relative
rem    (config.yaml  cache.db  meta-backup  mihomo-widget.runtime.yaml appear here at runtime)
rem    (ships the sanitized template under its .example name: users must copy
rem     it to mihomo\config.yaml with real nodes before first start, so the widget
rem     can never run on placeholder proxies)
rem  Upgrade note: an existing flat install (config.yaml beside the exe) still works -
rem  findYaml keeps the old candidates - but the whitelist/geodata then have to stay
rem  beside that config too; moving config.yaml + direct.yaml into mihomo\ adopts the
rem  new layout.
rem
rem  Bundle dir + zip carry the version (newest "## vX.Y.Z" heading of
rem  docs\CHANGELOG.md - bumped per change; it names the *upcoming* release, so it
rem  must stay ahead of the newest git tag, which is only cut at milestones) and
rem  the arch tag, so builds of different versions never overwrite each other.
rem ============================================================
setlocal
cd /d "%~dp0.."

set "ZIG=.tools\zig\zig-x86_64-windows-0.16.0\zig.exe"

if not exist "%ZIG%" (
    echo [ERROR] zig toolchain not found: %ZIG%
    exit /b 1
)

rem ---- version / arch -> bundle + zip name ----
rem version comes from the newest "## vX.Y.Z" heading in docs\CHANGELOG.md
rem (never hardcode it here: one bump in the changelog renames the bundle).
set "VER="
for /f "usebackq tokens=2" %%v in (`findstr /b /c:"## v" docs\CHANGELOG.md`) do if not defined VER set "VER=%%v"
if not defined VER (
    echo [ERROR] no "## vX.Y.Z" heading found in docs\CHANGELOG.md.
    exit /b 1
)
rem toolchain is pinned to x86_64 (see %ZIG%); keep the tag in the artifact name
set "ARCH=x86_64"
set "PKG=mihomo-widget-%VER%-%ARCH%"

rem guard: the newest tag is the newest *released* version. If the changelog
rem heading still carries that same version while commits exist past the tag, the
rem heading was not bumped - the bundle would be named like the released one.
rem (no 2>nul redirect here: caret-escaping a redirect inside for /f is unreliable)
set "TAG="
for /f "delims=- tokens=1" %%t in ('git describe --tags') do set "TAG=%%t"
if /I "%TAG%"=="%VER%" (
    for /f %%c in ('git rev-list --count "%TAG%..HEAD"') do if not "%%c"=="0" echo [WARN] changelog version %VER% already equals tag %TAG% but %%c commit^(s^) came after it - bump the newest "## v" heading.
)

rem docs gate: docs/API-REFERENCE.md must match app/src (symbols / endpoints / conf keys).
rem Both sides live in app\tools\docsgen.zig (facts from std.zig.Ast + the markdown work),
rem so the gate is that tool: `zig build docs-check` exits non-zero on drift, and
rem `zig build docs-gen` rewrites the mechanical cells and appends rows for new public
rem symbols (with an empty description, which the checker then demands be filled in).
pushd app
call ..\%ZIG% build docs-check
if errorlevel 1 (
    popd
    echo.
    echo [ERROR] docs out of sync with source ^(run: cd app ^&^& zig build docs-gen, then fill what it names^)
    exit /b 1
)
popd

echo [1/2] Building admin release (requireAdministrator - TUN capable)...
pushd app
call ..\%ZIG% build --release=small -Dadmin
if errorlevel 1 (
    popd
    echo.
    echo [ERROR] build failed.
    exit /b 1
)
popd

echo [2/2] Assembling release bundle...
rem regenerate the whitelist-derived rule provider (users only edit whitelist)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0convert_whitelist.ps1"
if errorlevel 1 (
    echo [ERROR] whitelist convert failed.
    exit /b 1
)
set "OUT=release\%PKG%"
echo       bundle: %PKG%

rem rebuild the output dir so stale leftovers (cache.db / runtime state) never ship
if exist "%OUT%" rd /s /q "%OUT%" >nul
mkdir "%OUT%"
mkdir "%OUT%\mihomo"

rem root: the widget + the conf template (log lands here at runtime too)
copy /Y app\zig-out\bin\mihomo-widget.exe "%OUT%\" >nul
rem the shipped conf is the clean template: per-machine runtime state (window_x/y,
rem sysproxy, tun, nic_ifindex) belongs to whoever runs it, not to the bundle.
copy /Y app\cfg\mihomo-widget.conf      "%OUT%\" >nul

rem mihomo\: the core and everything it resolves relative to -d (= the folder its
rem config sits in) - geodata, rule provider, and later cache.db / meta-backup /
rem mihomo-widget.runtime.yaml.
copy /Y .tools\mihomo\mihomo.exe        "%OUT%\mihomo\" >nul
copy /Y .tools\mihomo\GeoIP.dat         "%OUT%\mihomo\" >nul
copy /Y .tools\mihomo\GeoSite.dat       "%OUT%\mihomo\" >nul
copy /Y .tools\mihomo\direct.yaml       "%OUT%\mihomo\" >nul
rem NEVER ship app\cfg\config.yaml: it holds real node servers/credentials.
rem Ship the sanitized template under its .example name (no live config.yaml:
rem forces users to copy+fill their own nodes instead of booting on placeholders).
rem Users replace the placeholder proxies before first start and keep it as
rem mihomo\config.yaml.
copy /Y app\cfg\config.yaml.example     "%OUT%\mihomo\" >nul
if errorlevel 1 (
    echo [ERROR] missing app\cfg\config.yaml.example - refusing to build a leaky bundle.
    exit /b 1
)

rem zip it up (archive the dir itself: extracting yields the versioned folder,
rem so two versions can coexist in the same download dir)
set "ZIP=release\%PKG%.zip"
if exist "%ZIP%" del /Q "%ZIP%" >nul
powershell -NoProfile -Command "Compress-Archive -Path '%CD%\%OUT%' -DestinationPath '%CD%\%ZIP%' -Force"
if errorlevel 1 (
    echo [ERROR] zip step failed.
    exit /b 1
)

echo.
echo Bundle ready:
dir /b "%OUT%"
echo   [mihomo\]
dir /b "%OUT%\mihomo"
echo.
echo zip: %CD%\%ZIP%

endlocal