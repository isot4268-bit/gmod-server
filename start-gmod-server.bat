@echo off
setlocal

set "ROOT=%~dp0"
set "ROLE=%~1"
set "SYNC_API_KEY=gmod-sync-local-2026"
set "BACKEND_HOST=13.221.195.238"
set "SYNC_SSH_KEY=C:\Users\Administrator\.ssh\id_rsa_ai"

if "%ROLE%"=="" (
  for /f %%H in ('hostname') do set "HOSTNAME_VALUE=%%H"
  if /i "%HOSTNAME_VALUE%"=="EC2AMAZ-1NE3844" set "ROLE=vds-13"
  if /i "%HOSTNAME_VALUE%"=="EC2AMAZ-DAGEKQS" set "ROLE=vds-44"
)

if "%ROLE%"=="" set "ROLE=gmod"

if /i "%ROLE%"=="backend" (
  call :start_backend
  exit /b 0
)
if /i "%ROLE%"=="tunnel" (
  call :start_tunnel
  exit /b 0
)
if /i "%ROLE%"=="vds-13" call :start_backend
if /i "%ROLE%"=="vds-44" call :start_tunnel

cd /d "%ROOT%server"
srcds.exe -console -game garrysmod -allowlocalhttp +exec server.cfg +gamemode sandbox +map gm_construct +maxplayers 128 -port 27015
exit /b %ERRORLEVEL%

:start_backend
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:8080/health; if ($r.StatusCode -eq 200) { exit 0 }; exit 1 } catch { exit 1 }" >nul 2>nul
if not errorlevel 1 (
  echo Sync backend already running.
  exit /b 0
)
echo Starting sync backend...
start "GMod Sync Backend" /min cmd /c cd /d "%ROOT%backend" ^&^& set "SYNC_MEMORY=1" ^&^& set "SYNC_API_KEY=%SYNC_API_KEY%" ^&^& npm start
timeout /t 5 /nobreak >nul
exit /b 0

:start_tunnel
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:8080/health; if ($r.StatusCode -eq 200) { exit 0 }; exit 1 } catch { exit 1 }" >nul 2>nul
if not errorlevel 1 (
  echo Sync tunnel already running.
  exit /b 0
)
echo Starting sync tunnel...
start "GMod Sync Tunnel" /min C:\Windows\System32\OpenSSH\ssh.exe -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -i "%SYNC_SSH_KEY%" -L 127.0.0.1:8080:127.0.0.1:8080 Administrator@%BACKEND_HOST%
timeout /t 5 /nobreak >nul
exit /b 0
