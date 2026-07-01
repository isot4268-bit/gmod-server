@echo off
cd /d "%~dp0backend"
set SYNC_MEMORY=1
if "%SYNC_API_KEY%"=="" set SYNC_API_KEY=change-this-long-random-key
npm install
npm start
