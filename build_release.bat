@echo off
rem ===========================================================================
rem  TankCraft - Windows Release EXE 一键构建
rem
rem  用法：
rem    build_release.bat                    构建 release 版单文件 exe
rem    build_release.bat --debug            构建 debug 版
rem    build_release.bat --out <路径>       指定输出 exe 路径
rem    build_release.bat --godot <路径>     指定 Godot 可执行文件
rem    build_release.bat --install-templates 下载并安装匹配版本的导出模板
rem    build_release.bat --help             显示帮助
rem
rem  退出码：0 成功 / 1 用法错误 / 2 找不到 Godot / 3 缺导出模板
rem          4 导出失败 / 5 产物缺失或为空 / 6 模板安装失败
rem
rem  为什么脚本不自动装模板：导出模板默认装到 %APPDATA%\Godot\export_templates，
rem  那是工程目录之外的位置。脚本默认只报告缺失并给出命令，改环境必须由人显式
rem  传 --install-templates 触发，避免构建步骤悄悄改动工作区外的机器状态。
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

rem 记录原始代码页，退出时恢复，避免污染用户的控制台。
for /f "tokens=2 delims=:" %%C in ('chcp') do for /f "tokens=1" %%D in ("%%C") do set "OLDCP=%%D"
if not defined OLDCP set "OLDCP=936"
chcp 65001 >nul 2>&1

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%" 2>nul
if errorlevel 1 (
    set "EXITCODE=%RC_USAGE%"
    echo [X] 无法进入脚本所在目录：%SCRIPT_DIR%
    goto :finish
)

rem --------------------------------------------------------------------------
rem  参数解析
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

echo [X] 未知参数：%ARG%
echo     运行 build_release.bat --help 查看用法。
set "EXITCODE=%RC_USAGE%"
goto :finish

:args_done

rem --------------------------------------------------------------------------
rem  工程自检
rem --------------------------------------------------------------------------
if not exist "project.godot" (
    echo [X] 当前目录不是 TankCraft 工程根目录：%CD%
    set "EXITCODE=%RC_USAGE%"
    goto :finish
)
if not exist "export_presets.cfg" (
    echo [X] 缺少 export_presets.cfg，无法导出。
    set "EXITCODE=%RC_USAGE%"
    goto :finish
)

rem --------------------------------------------------------------------------
rem  定位 Godot
rem  优先使用同目录下的 *_console.exe：godot.exe 是 Windows GUI 子系统程序，
rem  不会把 stdout/stderr 交回控制台，既看不到报错也拿不到真实退出码。
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
    echo [X] 在 PATH 与常见安装位置都找不到 godot。
    echo     请用 --godot "C:\path\to\Godot_v4.x-stable_win64_console.exe" 指定，
    echo     或设置环境变量 GODOT_EXE。
    set "EXITCODE=%RC_NO_GODOT%"
    goto :finish
)

for %%A in ("%GODOT_BIN%") do set "GDIR=%%~dpA"
for %%F in ("%GDIR%Godot_v*_console.exe") do if exist "%%~fF" set "GODOT_BIN=%%~fF"

rem --------------------------------------------------------------------------
rem  读取引擎版本 -> 推导导出模板目录名与发行标签
rem   "4.7.2.stable.official.ed1daf0bf"
rem      -> 模板目录 4.7.2.stable   （点分，与 %APPDATA% 下的目录同名）
rem      -> 发行标签 4.7.2-stable   （连字符，GitHub release tag 的写法）
rem --------------------------------------------------------------------------
if not exist "%GODOT_BIN%" (
    echo [X] 指定的 Godot 不存在："%GODOT_BIN%"
    echo     请用 --godot 指向 Godot 的 *_console.exe。
    set "EXITCODE=%RC_NO_GODOT%"
    goto :finish
)

set "VER="
for /f "usebackq delims=" %%V in (`"%GODOT_BIN%" --headless --version 2^>nul`) do (
    if not defined VER set "VER=%%V"
)
if not defined VER (
    echo [X] 无法从 "%GODOT_BIN%" 读取引擎版本。
    echo     请用 --godot 指向 Godot 的 *_console.exe。
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
echo   Godot : %GODOT_BIN%
echo   版本  : %VER%
echo   预设  : %PRESET%
echo   模式  : %MODE%
echo   输出  : %OUT_EXE%
echo   模板  : %TPL_FILE%
echo.

rem --------------------------------------------------------------------------
rem  导出模板检查（缺失时可显式请求安装）
rem --------------------------------------------------------------------------
if exist "%TPL_FILE%" goto :have_template

if "%DO_INSTALL_TPL%"=="1" goto :install_templates

echo [X] 缺少导出模板：%TPL_FILE%
echo.
echo     导出模板必须与引擎版本严格一致（%TPL_DIR%），不能用近似版本代替。
echo     模板缺失时无法生成任何 exe —— 这是环境问题，与工程代码无关。
echo.
echo     任选其一解决：
echo       1) 本脚本自动安装（约 1.3 GB，装到 %TPL_ROOT%）：
echo            build_release.bat --install-templates
echo       2) 图形界面：Godot 编辑器 -^> 编辑器 -^> 管理导出模板 -^> 下载并安装
echo       3) 手动下载并解压：
echo            https://github.com/godotengine/godot/releases/download/%REL_TAG%/Godot_v%REL_TAG%_export_templates.tpz
echo          解压后把里面的 templates 目录整体放到 %TPL_ROOT%\%TPL_DIR%
echo.
set "EXITCODE=%RC_NO_TEMPLATE%"
goto :finish

:install_templates
echo [i] 正在下载并安装 %TPL_DIR% 导出模板（约 1.3 GB，可能需要几分钟）...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $u='https://github.com/godotengine/godot/releases/download/%REL_TAG%/Godot_v%REL_TAG%_export_templates.tpz'; $tpz=Join-Path $env:TEMP 'godot_tpl.tpz'; $dir=Join-Path $env:TEMP 'godot_tpl'; Write-Host ('  下载 ' + $u); Invoke-WebRequest -Uri $u -OutFile $tpz; if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }; Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory($tpz, $dir); $src=Join-Path $dir 'templates'; if (-not (Test-Path $src)) { throw '压缩包内没有 templates 目录' }; $dst=Join-Path $env:APPDATA 'Godot\export_templates\%TPL_DIR%'; New-Item -ItemType Directory -Force -Path $dst | Out-Null; Copy-Item (Join-Path $src '*') $dst -Recurse -Force; Remove-Item $tpz -Force -ErrorAction SilentlyContinue; Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host ('  已安装到 ' + $dst)"
if errorlevel 1 (
    echo [X] 导出模板安装失败。请改用图形界面安装，然后重新运行本脚本。
    set "EXITCODE=%RC_TPL_FAIL%"
    goto :finish
)
if not exist "%TPL_FILE%" (
    echo [X] 安装命令返回成功，但仍找不到 %TPL_FILE%
    echo     请检查安装目录是否与引擎版本一致：%TPL_DIR%
    set "EXITCODE=%RC_TPL_FAIL%"
    goto :finish
)
echo [i] 导出模板安装完成。

:have_template

rem --------------------------------------------------------------------------
rem  清理旧产物 + 准备输出目录
rem  必须先删旧 exe：否则导出失败时残留的旧文件会被误判成"构建成功"。
rem --------------------------------------------------------------------------
for %%A in ("%OUT_EXE%") do set "OUT_DIR=%%~dpA"
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%" >nul 2>&1
if exist "%OUT_EXE%" del /q "%OUT_EXE%" >nul 2>&1

set "BUILD_LOG=%OUT_DIR%build_release.log"

echo [i] 开始导出...
"%GODOT_BIN%" --headless --path "." --export-%MODE% "%PRESET%" "%OUT_EXE%" > "%BUILD_LOG%" 2>&1
set "EXPORT_RC=%ERRORLEVEL%"

if not "%EXPORT_RC%"=="0" goto :export_failed
if not exist "%OUT_EXE%" goto :no_artifact
for %%A in ("%OUT_EXE%") do set "SIZE=%%~zA"
if "%SIZE%"=="0" goto :no_artifact

echo.
echo ===========================================================================
echo   [OK] 构建成功
echo     产物 : %OUT_EXE%
echo     大小 : %SIZE% 字节
echo     日志 : %BUILD_LOG%
echo ===========================================================================
certutil -hashfile "%OUT_EXE%" SHA256 2>nul
set "EXITCODE=%RC_OK%"
goto :finish

:export_failed
echo.
echo [X] 导出失败，退出码 %EXPORT_RC%
echo     ---- Godot 输出 ----
type "%BUILD_LOG%"
echo     ----------------------
findstr /c:"Invalid export preset name" "%BUILD_LOG%" >nul 2>&1
if not errorlevel 1 echo [i] 提示：export_presets.cfg 里没有名为 "%PRESET%" 的预设。
findstr /c:"configuration errors" "%BUILD_LOG%" >nul 2>&1
if not errorlevel 1 echo [i] 提示：Godot 判定预设配置不完整，最常见原因仍是导出模板缺失或版本不匹配。
set "EXITCODE=%RC_EXPORT_FAIL%"
goto :finish

:no_artifact
echo.
echo [X] 导出命令返回 0，但没有产出可用文件：%OUT_EXE%
echo     请检查 "%BUILD_LOG%"。
set "EXITCODE=%RC_NO_ARTIFACT%"
goto :finish

:usage
echo.
echo   TankCraft Windows Release 构建脚本
echo.
echo     build_release.bat                     构建 release 版单文件 exe
echo     build_release.bat --debug             构建 debug 版
echo     build_release.bat --out ^<路径^>        指定输出路径（默认 build\windows\TankCraft.exe）
echo     build_release.bat --godot ^<路径^>      指定 Godot（建议 *_console.exe）
echo     build_release.bat --install-templates 下载并安装匹配版本的导出模板
echo     build_release.bat --help              显示本帮助
echo.
echo   退出码：0 成功 / 1 用法错误 / 2 找不到 Godot / 3 缺导出模板
echo           4 导出失败 / 5 产物缺失或为空 / 6 模板安装失败
echo.
echo   说明：导出模板必须与引擎版本一致；默认不会自动下载，需显式 --install-templates。
echo.
set "EXITCODE=%RC_OK%"
goto :finish

:finish
popd 2>nul
chcp %OLDCP% >nul 2>&1
endlocal & exit /b %EXITCODE%
