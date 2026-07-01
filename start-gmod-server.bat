@echo off
cd /d "%~dp0server"
srcds.exe -console -game garrysmod -allowlocalhttp +exec server.cfg +gamemode sandbox +map gm_construct +maxplayers 128 -port 27015
