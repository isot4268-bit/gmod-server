@echo off
cd /d "%~dp0server"
srcds.exe -console -game garrysmod +gamemode sandbox +map gm_construct +maxplayers 16 -port 27015
