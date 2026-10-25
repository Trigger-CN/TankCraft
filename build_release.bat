@echo off
rem ===========================================================================
rem  TankCraft - Windows Release EXE build script
rem
rem  USAGE
rem    build_release.bat                      build release exe
rem    build_release.bat --debug              build debug exe
rem    build_release.bat --out <path>         custom output path (spaces OK)
rem    build_release.bat --godot <path>       explicit Godot executable
rem    build_release.bat --install-templates  download+install export templates
rem    build_release.bat --help
rem
rem  EXIT CODES
rem    0 success / 1 usage error / 2 Godot not found / 3 templates missing
rem    4 export failed / 5 artifact missing or empty / 6 template install failed
rem
rem  WHY THIS FILE IS ASCII-ONLY
rem    cmd.exe re-reads the .bat by byte offset while executing it. Calling
rem    `chcp 65001` mid-file changes how those offsets are decoded, so any
rem    multi-byte (Chinese) line after that point can be split in half and
rem    executed as garbage commands. Observed here: 'ild_release.bat' and
rem    '?' reported as "not recognized as an internal or external command".
rem    Chinese diagnostic text therefore lives in tools\install_templates.ps1
rem    (PowerShell handles UTF-8 correctly); this file stays ASCII.
rem
rem  WHY THE CONSOLE WRAPPER
rem    godot.exe is a Windows GUI-subsystem binary: it does not attach to the
rem    parent console, so stdout is lost and ERRORLEVEL does not reflect the
rem    result. The sibling *_console.exe does. Always prefer it.
rem ===========================================================================

setlocal EnableExtensions EnableDelayedExpansion

set "RC_OK=0"
set "RC_USAGE=1"
set "RC_NO_GODOT=2"
set "RC_NO_TEMPLATE=3"
set "RC_EXPORT_FAIL=4"
set "RC_NO_ARTIFACT=5"
set "RC_TPL_FAIL=6"

set "PRESET=Windows Desktop"
set "OUT_EXE=build\windows\TankCraft.exe"
set "MODE=release"
set "GODOT_BIN="
set "DO_INSTALL_TPL=0"
set "EXITCODE=%RC_OK%"

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%" 2>nul
if errorlevel 1 (
    set "EXITCODE=%RC_USAGE%"
    echo [X] Cannot enter script directory: %SCRIPT_DIR%
    goto :finish
)

rem --------------------------------------------------------------------------
rem  Argument parsing
rem --------------------------------------------------------------------------
:parse_args
if "%~1"=="" goto :args_done
set "ARG=%~1"

if /i "%ARG%"=="--help"    goto :usage
if /i "%ARG%"=="-h"        goto :usage
if /i "%ARG%"=="/?"        goto :usage

if /i "%ARG%"=="--debug" (
    set "MODE=debug"
    shift
    goto :parse_args
)

if /i "%ARG%"=="--install-templates" (
    set "DO_INSTALL_TPL=1"
    shift
    goto :parse_args
)

if /i "%ARG%"=="--out" (
    if "%~2"=="" goto :usage
    set "OUT_EXE=%~2"
    shift
    shift
    goto :parse_args
)

if /i "%ARG%"=="--godot" (
    if "%~2"=="" goto :usage
    set "GODOT_BIN=%~2"
    shift
    shift
    goto :parse_args
)

echo [X] Unknown argument: %ARG%
echo     Run build_release.bat --help
set "EXITCODE=%RC_USAGE%"
goto :finish

:args_done

rem --------------------------------------------------------------------------
rem  Project sanity check
rem --------------------------------------------------------------------------
if not exist "project.godot" (
    echo [X] Not a TankCraft project root: %CD%
    set "EXITCODE=%RC_USAGE%"
    goto :finish
)
if not exist "export_presets.cfg" (
    echo [X] Missing export_presets.cfg
    set "EXITCODE=%RC_USAGE%"
    goto :finish
)

rem --------------------------------------------------------------------------
rem  Locate Godot
rem --------------------------------------------------------------------------
if not defined GODOT_BIN if defined GODOT_EXE set "GODOT_BIN=%GODOT_EXE%"

if not defined GODOT_BIN (
    for /f "delims=" %%I in ('where godot 2^>nul') do (
        if not defined GODOT_BIN set "GODOT_BIN=%%I"
    )
)

if not defined GODOT_BIN (
    for %%D in (
        "%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe"
        "%ProgramFiles%\Godot"
        "%ProgramFiles%\Godot Engine"
        "%ProgramFiles(x86)%\Godot"
    ) do (
        if not defined GODOT_BIN if exist "%%~D\godot.exe" set "GODOT_BIN=%%~D\godot.exe"
    )
)

if not defined GODOT_BIN (
    echo [X] godot not found in PATH or common install locations.
    echo     Use --godot "C:\path\to\Godot_v4.x-stable_win64_console.exe"
    echo     or set the GODOT_EXE environment variable.
    set "EXITCODE=%RC_NO_GODOT%"
    goto :finish
)

if not exist "%GODOT_BIN%" (
    echo [X] Godot not found at: "%GODOT_BIN%"
    echo     Use --godot and point at the *_console.exe build.
    set "EXITCODE=%RC_NO_GODOT%"
    goto :finish
)

for %%A in ("%GODOT_BIN%") do set "GDIR=%%~dpA"
for %%F in ("%GDIR%Godot_v*_console.exe") do if exist "%%~fF" set "GODOT_BIN=%%~fF"

rem --------------------------------------------------------------------------
rem  Engine version -> template dir (dot form) and release tag (dash form)
rem    "4.7.2.stable.official.ed1daf0bf"
rem      -> template dir 4.7.2.stable   (matches %APPDATA% layout)
rem      -> release tag  4.7.2-stable   (matches the GitHub tag)
rem  These are DIFFERENT spellings of the same version. Mixing them 404s.
rem --------------------------------------------------------------------------
set "VER="
for /f "usebackq delims=" %%V in (`"%GODOT_BIN%" --headless --version 2^>nul`) do (
    if not defined VER set "VER=%%V"
)
if not defined VER (
    echo [X] Could not read engine version from "%GODOT_BIN%"
    echo     Use --godot and point at the *_console.exe build.
    set "EXITCODE=%RC_NO_GODOT%"
    goto :finish
)

set "VER_CORE="
set "VER_STAGE="
for /f "tokens=1,2,3,4 delims=." %%a in ("%VER%") do (
    set "VER_CORE=%%a.%%b.%%c"
    set "VER_STAGE=%%d"
)
if not defined VER_CORE (
    set "VER_CORE=%VER%"
    set "VER_STAGE=stable"
)
set "TPL_DIR=%VER_CORE%.%VER_STAGE%"
set "REL_TAG=%VER_CORE%-%VER_STAGE%"
set "TPL_ROOT=%APPDATA%\Godot\export_templates"
set "TPL_FILE=%TPL_ROOT%\%TPL_DIR%\windows_%MODE%_x86_64.exe"

echo.
echo   Godot    : %GODOT_BIN%
echo   Version  : %VER%
echo   Preset   : %PRESET%
echo   Mode     : %MODE%
echo   Output   : %OUT_EXE%
echo   Template : %TPL_FILE%
echo.

rem --------------------------------------------------------------------------
rem  Export template check (install only when explicitly requested)
rem --------------------------------------------------------------------------
if exist "%TPL_FILE%" goto :have_template

if "%DO_INSTALL_TPL%"=="1" goto :install_templates

echo [X] Missing export template: %TPL_FILE%
echo.
echo     The template must match the engine version exactly (%TPL_DIR%).
echo     No exe can be produced without it. This is an environment issue,
echo     not a project issue.
echo.
echo     Any one of these fixes it:
echo       1^) Let this script install it (about 1.2 GB, into %TPL_ROOT%):
echo            build_release.bat --install-templates
echo       2^) Godot editor: Editor -^> Manage Export Templates -^> Download and Install
echo       3^) Manual: download and unpack
echo            https://github.com/godotengine/godot/releases/download/%REL_TAG%/Godot_v%REL_TAG%_export_templates.tpz
echo          then copy its templates folder to %TPL_ROOT%\%TPL_DIR%
echo.
set "EXITCODE=%RC_NO_TEMPLATE%"
goto :finish

:install_templates
set "TPL_PS1=%~dp0tools\install_templates.ps1"
if not exist "%TPL_PS1%" (
    echo [X] Missing template installer: %TPL_PS1%
    echo     tools\install_templates.ps1 must be checked out next to this script.
    set "EXITCODE=%RC_TPL_FAIL%"
    goto :finish
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TPL_PS1%" -Version "%TPL_DIR%" -Destination "%TPL_ROOT%\%TPL_DIR%"
if errorlevel 1 (
    echo [X] Export template installation failed.
    echo     Install it from the Godot editor instead, then rerun this script.
    set "EXITCODE=%RC_TPL_FAIL%"
    goto :finish
)
if not exist "%TPL_FILE%" (
    echo [X] Installer reported success but %TPL_FILE% is still missing.
    echo     Check that the install directory matches the engine version: %TPL_DIR%
    set "EXITCODE=%RC_TPL_FAIL%"
    goto :finish
)
echo [i] Export templates installed.

:have_template

rem --------------------------------------------------------------------------
rem  Remove the old artifact BEFORE exporting.
rem  If we do not, a failed export leaves last build's exe in place and the
rem  "exists and non-empty" check below happily reports success.
rem --------------------------------------------------------------------------
for %%A in ("%OUT_EXE%") do set "OUT_DIR=%%~dpA"
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%" >nul 2>&1
if exist "%OUT_EXE%" del /q "%OUT_EXE%" >nul 2>&1

set "BUILD_LOG=%OUT_DIR%build_release.log"

echo [i] Exporting...
"%GODOT_BIN%" --headless --path "." --export-%MODE% "%PRESET%" "%OUT_EXE%" > "%BUILD_LOG%" 2>&1
set "EXPORT_RC=%ERRORLEVEL%"

if not "%EXPORT_RC%"=="0" goto :export_failed
if not exist "%OUT_EXE%" goto :no_artifact
for %%A in ("%OUT_EXE%") do set "SIZE=%%~zA"
if "%SIZE%"=="0" goto :no_artifact

echo.
echo ===========================================================================
echo   [OK] Build succeeded
echo     Artifact : %OUT_EXE%
echo     Size     : %SIZE% bytes
echo     Log      : %BUILD_LOG%
echo ===========================================================================
certutil -hashfile "%OUT_EXE%" SHA256 2>nul
set "EXITCODE=%RC_OK%"
goto :finish

:export_failed
echo.
echo [X] Export failed, exit code %EXPORT_RC%
echo     ---- Godot output ----
type "%BUILD_LOG%"
echo     ----------------------
findstr /c:"Invalid export preset name" "%BUILD_LOG%" >nul 2>&1
if not errorlevel 1 echo [i] Hint: export_presets.cfg has no preset named "%PRESET%".
findstr /c:"configuration errors" "%BUILD_LOG%" >nul 2>&1
if not errorlevel 1 echo [i] Hint: Godot rejected the preset config; the usual cause is a missing or mismatched export template.
set "EXITCODE=%RC_EXPORT_FAIL%"
goto :finish

:no_artifact
echo.
echo [X] Export returned 0 but produced no usable file: %OUT_EXE%
echo     Check "%BUILD_LOG%".
set "EXITCODE=%RC_NO_ARTIFACT%"
goto :finish

:usage
echo.
echo   TankCraft Windows Release build script
echo.
echo     build_release.bat                      build release exe
echo     build_release.bat --debug              build debug exe
echo     build_release.bat --out ^<path^>        custom output path (default build\windows\TankCraft.exe)
echo     build_release.bat --godot ^<path^>      explicit Godot (prefer *_console.exe)
echo     build_release.bat --install-templates  download+install matching export templates
echo     build_release.bat --help               show this help
echo.
echo   Exit codes: 0 ok / 1 usage / 2 no Godot / 3 no templates
echo               4 export failed / 5 no artifact / 6 template install failed
echo.
echo   Templates must match the engine version exactly.
echo   Nothing is downloaded unless you pass --install-templates.
echo.
set "EXITCODE=%RC_OK%"
goto :finish

:finish
popd 2>nul
endlocal & exit /b %EXITCODE%
