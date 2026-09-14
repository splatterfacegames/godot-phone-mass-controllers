@echo off
rem Fake cloudflared for PMCTunnel tests (Windows). Mode comes from PMC_FAKE_CLOUDFLARED_MODE:
rem ok | slow | no_url | error_exit | exit_after_ready. Replays real-looking logs from logs\ to stderr.
setlocal
set "LOGS=%~dp0logs"
if /i "%~1"=="--version" (
  echo cloudflared version 2025.8.1 ^(built 2025-08-01-0000 UTC^)
  exit /b 0
)
if not "%~1"=="tunnel" goto badargs
if not "%~2"=="--no-autoupdate" goto badargs
if not "%~3"=="--url" goto badargs
echo %~4| findstr /b /c:"http://127.0.0.1:" >nul || goto badargs
set "MODE=%PMC_FAKE_CLOUDFLARED_MODE%"
if "%MODE%"=="" set "MODE=ok"
if "%MODE%"=="error_exit" (
  type "%LOGS%\error_429.log" 1>&2
  exit /b 1
)
if "%MODE%"=="no_url" (
  type "%LOGS%\no_url.log" 1>&2
  goto idle
)
if "%MODE%"=="slow" ping -n 4 127.0.0.1 >nul
type "%LOGS%\banner.log" 1>&2
if "%MODE%"=="slow" ping -n 2 127.0.0.1 >nul
type "%LOGS%\registered.log" 1>&2
if "%MODE%"=="exit_after_ready" (
  ping -n 2 127.0.0.1 >nul
  exit /b 0
)
:idle
for /l %%i in (1,1,120) do ping -n 2 127.0.0.1 >nul
exit /b 0
:badargs
echo ERR unexpected arguments: %* 1>&2
exit /b 2
