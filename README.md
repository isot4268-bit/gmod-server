# Garry's Mod Server

Windows Garry's Mod dedicated server helper files.

## Files

- `start-gmod-server.bat` starts the server on port `27015`.
- `update-gmod-server.bat` installs or updates the server with SteamCMD.
- `server/garrysmod/cfg/server.cfg` contains the basic server settings.

## Setup

Run:

```bat
update-gmod-server.bat
start-gmod-server.bat
```

Before exposing the server publicly, change `rcon_password` in `server/garrysmod/cfg/server.cfg`.
