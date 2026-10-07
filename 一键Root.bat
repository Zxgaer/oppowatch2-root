@echo off
rem ============================================================================
rem  OPPO Watch 2 (OW20W1) - ONE-CLICK permanent root (v7 boot auto-flashed)
rem
rem  Double-click this file. It runs auto_root.sh which:
rem    [0] shows the safety notes and asks y/n
rem    [1] checks adb and the device connection
rem    [1b] STOPS if the watch is already uid=0 (no re-flash, no re-grind)
rem    [2] prepares everything (carrier app / v7 target / guard files / magiskpolicy)
rem    [3] runs the grind in the background
rem    [4] prints live status + watch logs every 30s, and loudly reports
rem        UID0 / FLASH START / FLASH DONE
rem
rem  NOTE: this .bat is intentionally ASCII-only (cmd.exe mis-parses UTF-8
rem  batch files after "chcp"). All Chinese messages are printed by
rem  auto_root.sh instead.
rem
rem  Exit codes: 0=uid0 achieved  2=no hit this run  3=env/prep error
rem              4=device missing 5=declined at safety gate
rem              6=device already uid=0 (pre-flash gate stopped it) 130=Ctrl+C
rem ============================================================================
chcp 65001 >nul 2>&1
title OPPO Watch 2 - one-click permanent root
cd /d "%~dp0"
setlocal

set "BASH="
if exist "C:\Program Files\Git\bin\bash.exe" set "BASH=C:\Program Files\Git\bin\bash.exe"
if not defined BASH if exist "C:\Program Files (x86)\Git\bin\bash.exe" set "BASH=C:\Program Files (x86)\Git\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined BASH if exist "C:\Program Files\Git\usr\bin\bash.exe" set "BASH=C:\Program Files\Git\usr\bin\bash.exe"
if not defined BASH for /f "delims=" %%i in ('where bash 2^>nul') do if not defined BASH set "BASH=%%i"

echo.
echo ============================================================
echo   OPPO Watch 2 (OW20W1) - one-click permanent root
echo ------------------------------------------------------------
echo   The script will show the safety notes first (y/n gate),
echo   then check adb + device, then grind (~35-45 min average).
echo   Please do NOT close this window while it runs.
echo ============================================================
echo.

if not defined BASH goto nobash
if not exist "auto_root.sh" goto noscript
if not exist "rc17_hunt_v2.sh" goto nohunt

"%BASH%" auto_root.sh %*
set RC=%ERRORLEVEL%

echo.
echo ------------------------------------------------------------
if "%RC%"=="0" goto ok
if "%RC%"=="2" goto nohit
if "%RC%"=="3" goto enverr
if "%RC%"=="4" goto nodev
if "%RC%"=="5" goto declined
if "%RC%"=="6" goto alreadyroot
if "%RC%"=="130" goto interrupted
echo   [END] script exit code = %RC% (unexpected). Log: auto_root_hunt.log
goto end

:ok
echo   [OK] uid0 achieved - permanent root (v7) is flashed and running.
echo   Evidence files are in this folder. Full log: auto_root_hunt.log
goto end

:nohit
echo   [NO HIT] This run ended without a window. Everything stays prepared -
echo   just run this file again to continue (average: 1 hit / 35-45 min).
goto end

:enverr
echo   [ENV ERROR] adb missing or prep failed - see the [x] lines above.
echo   Unzip the WHOLE package folder before running (do not copy single files).
goto end

:nodev
echo   [NO DEVICE] The watch was not seen over adb - cable / authorization /
echo   driver. The script retried for 3 minutes before giving up.
goto end

:declined
echo   [DECLINED] You answered N at the safety gate. Nothing was changed.
goto end

:alreadyroot
echo   [ALREADY ROOT] The watch is already uid=0 - nothing was written.
echo   No need to grind again. To swap the TWRP image, use the maintenance
echo   channel instead: adb reboot recovery, then dd the new image to recovery.
echo   See README (maintenance channel).
goto end

:interrupted
echo   [INTERRUPTED] Ctrl+C - the background grinder was stopped. Progress
echo   is kept on the watch; just run this file again to resume.
goto end

:nobash
echo   [ERROR] Git Bash (bash.exe) not found.
echo   Fix: install Git for Windows (https://git-scm.com/download/win),
echo        or add its bin folder to PATH, then run this file again.
goto end

:noscript
echo   [ERROR] auto_root.sh not found next to this .bat.
goto end

:nohunt
echo   [ERROR] rc17_hunt_v2.sh not found next to this .bat.
goto end

:end
echo ------------------------------------------------------------
echo   (This window is kept open on purpose so you can read the log.)
echo.
pause
exit /b %RC%
