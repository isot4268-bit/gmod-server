# Garry's Mod Server + Sync Backend

Windows Garry's Mod dedicated server helper files.

## Files

- `start-gmod-server.bat` starts the server on port `27015`.
- `update-gmod-server.bat` installs or updates the server with SteamCMD.
- `server/garrysmod/cfg/server.cfg` contains the basic server settings.
- `backend/` contains the Redis/Postgres sync API.
- `docker-compose.sync.yml` starts the sync backend, Redis, and Postgres.
- `server/garrysmod/lua/autorun/server/sync_backend.lua` sends GMod server/player state to the backend.

## Setup

Run:

```bat
update-gmod-server.bat
start-gmod-server.bat
```

Before exposing the server publicly, change `rcon_password` in `server/garrysmod/cfg/server.cfg`.

## Sync Backend

This backend is for running multiple GMod shards/VDS servers together:

- player presence and last known state
- near real-time movement snapshots for remote ghost players
- Redis cache and pub/sub
- Postgres persistence
- cross-server event log
- HTTP polling for GMod Lua servers
- WebSocket stream at `/ws` for external dashboards/tools

It does not remove the Source/Garry's Mod per-server player cap. Two VDS machines can be coordinated as two shards, but one single 256-player physics world is not created by this backend alone.

### Start Backend

Use the same launcher on each VDS:

```bat
start-gmod-server.bat
```

On `vds-13` it starts the sync backend first. On `vds-44` it starts the SSH
tunnel to `vds-13` first. Then it starts SRCDS.

Health check on the backend VDS:

```bat
curl http://127.0.0.1:8080/health
```

Memory mode is not persistent; it is for testing sync before Redis/Postgres are installed.

### Configure Each GMod Server

Copy this repo to each VDS, then set unique server IDs in the server console or config:

```cfg
sync_backend_url "http://BACKEND_VDS_IP:8080"
sync_backend_key "change-this-long-random-key"
sync_server_id "vds-13"
```

Use `sync_server_id "vds-44"` on the other VDS.

Movement sync defaults to 10 updates per second:

```cfg
sync_state_rate "0.10"
sync_ghost_rate "0.10"
```

Remote players are spawned as full opaque server-side proxy models. Their
position, movement, model, and eye direction are copied from the real player.
This is a shard visibility layer, not true Source-engine entity replication:
bullets, physics, collisions, prediction, voice, and vehicle control still
belong to the server the real player is connected to.

### Test Moving Peds

To watch sync from `vds-44` on `vds-13`, enable generated moving peds only on
`vds-44`:

```cfg
sync_test_peds "1"
sync_test_ped_count "4"
sync_test_ped_radius "260"
sync_test_ped_speed "1.4"
```

Join `vds-13` and the peds published by `vds-44` should appear as moving full
models around the first player position on `vds-44`. Disable with:

```cfg
sync_test_peds "0"
```
