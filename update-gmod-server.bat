@echo off
"%~dp0steamcmd\steamcmd.exe" +force_install_dir "%~dp0server" +login anonymous +app_update 4020 validate +quit
