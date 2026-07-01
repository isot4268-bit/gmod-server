import Fastify from "fastify";
import cors from "@fastify/cors";
import websocket from "@fastify/websocket";
import Redis from "ioredis";
import pg from "pg";
import { z } from "zod";

const env = {
  port: Number(process.env.PORT ?? 8080),
  apiKey: process.env.SYNC_API_KEY ?? "change-me",
  redisUrl: process.env.REDIS_URL ?? "redis://127.0.0.1:6379",
  databaseUrl:
    process.env.DATABASE_URL ??
    "postgres://gmod:gmod@127.0.0.1:5432/gmod_sync",
  logLevel: process.env.LOG_LEVEL ?? "info",
  memoryMode: process.env.SYNC_MEMORY === "1",
};

const app = Fastify({
  logger: {
    level: env.logLevel,
    transport:
      process.env.NODE_ENV === "production"
        ? undefined
        : { target: "pino-pretty", options: { colorize: true } },
  },
});

const redis = env.memoryMode ? null : new Redis(env.redisUrl);
const pub = env.memoryMode ? null : new Redis(env.redisUrl);
const sub = env.memoryMode ? null : new Redis(env.redisUrl);
const pool = env.memoryMode ? null : new pg.Pool({ connectionString: env.databaseUrl });
const sockets = new Set();
const memory = {
  servers: new Map(),
  profiles: new Map(),
  presence: new Map(),
  states: new Map(),
  events: [],
  nextEventId: 1,
};

const serverSchema = z.object({
  serverId: z.string().min(1).max(64),
  name: z.string().min(1).max(128).optional(),
  map: z.string().min(1).max(128).optional(),
  gamemode: z.string().min(1).max(64).optional(),
  players: z.number().int().min(0).max(128).optional(),
  maxPlayers: z.number().int().min(1).max(128).optional(),
});

const playerSchema = z.object({
  steamId: z.string().min(3).max(64),
  name: z.string().min(1).max(128).optional(),
  serverId: z.string().min(1).max(64),
});

const stateSchema = playerSchema.extend({
  state: z.record(z.unknown()).default({}),
});

const stateBatchSchema = z.object({
  serverId: z.string().min(1).max(64),
  players: z.array(
    z.object({
      steamId: z.string().min(3).max(64),
      name: z.string().min(1).max(128).optional(),
      state: z.record(z.unknown()).default({}),
    }),
  ).max(128),
});

const eventSchema = z.object({
  serverId: z.string().min(1).max(64),
  type: z.string().min(1).max(64),
  steamId: z.string().min(3).max(64).optional(),
  payload: z.record(z.unknown()).default({}),
});

await app.register(cors, { origin: true });
await app.register(websocket);

app.addHook("preHandler", async (request, reply) => {
  if (request.url === "/health" || request.url.startsWith("/ws")) return;

  const apiKey = request.headers["x-sync-key"];
  if (apiKey !== env.apiKey) {
    return reply.code(401).send({ error: "invalid api key" });
  }
});

async function migrate() {
  if (env.memoryMode) return;

  await pool.query(`
    create table if not exists servers (
      server_id text primary key,
      name text,
      map text,
      gamemode text,
      players integer not null default 0,
      max_players integer not null default 128,
      last_seen timestamptz not null default now()
    );

    create table if not exists player_profiles (
      steam_id text primary key,
      name text,
      first_seen timestamptz not null default now(),
      last_seen timestamptz not null default now()
    );

    create table if not exists player_presence (
      steam_id text primary key references player_profiles(steam_id),
      server_id text not null,
      connected boolean not null default true,
      updated_at timestamptz not null default now()
    );

    create table if not exists player_state (
      steam_id text primary key references player_profiles(steam_id),
      server_id text not null,
      state jsonb not null default '{}'::jsonb,
      updated_at timestamptz not null default now()
    );

    create table if not exists event_log (
      id bigserial primary key,
      server_id text not null,
      type text not null,
      steam_id text,
      payload jsonb not null default '{}'::jsonb,
      created_at timestamptz not null default now()
    );
  `);
}

async function publish(type, payload) {
  const message = JSON.stringify({ type, payload, at: new Date().toISOString() });
  if (env.memoryMode) {
    for (const socket of sockets) {
      if (socket.readyState === 1) socket.send(message);
    }
    return;
  }
  await pub.publish("gmod.events", message);
}

async function logEvent({ serverId, type, steamId = null, payload = {} }) {
  if (env.memoryMode) {
    const event = {
      id: memory.nextEventId++,
      serverId,
      type,
      steamId,
      payload,
      createdAt: new Date().toISOString(),
    };
    memory.events.push(event);
    if (memory.events.length > 2000) memory.events.shift();
    await publish("event", event);
    return event;
  }

  const result = await pool.query(
    `insert into event_log (server_id, type, steam_id, payload)
     values ($1, $2, $3, $4)
     returning id, created_at`,
    [serverId, type, steamId, payload],
  );

  const event = {
    id: result.rows[0].id,
    serverId,
    type,
    steamId,
    payload,
    createdAt: result.rows[0].created_at,
  };
  await publish("event", event);
  return event;
}

app.get("/health", async () => {
  if (!env.memoryMode) {
    await pool.query("select 1");
    await redis.ping();
  }
  return { ok: true, memoryMode: env.memoryMode };
});

app.post("/servers/:serverId/heartbeat", async (request) => {
  const body = serverSchema.parse({
    ...request.body,
    serverId: request.params.serverId,
  });

  if (env.memoryMode) {
    memory.servers.set(body.serverId, {
      ...body,
      name: body.name ?? body.serverId,
      players: body.players ?? 0,
      maxPlayers: body.maxPlayers ?? 128,
      lastSeen: new Date().toISOString(),
    });
    return { ok: true };
  }

  await pool.query(
    `insert into servers (server_id, name, map, gamemode, players, max_players, last_seen)
     values ($1, $2, $3, $4, $5, $6, now())
     on conflict (server_id) do update set
       name = excluded.name,
       map = excluded.map,
       gamemode = excluded.gamemode,
       players = excluded.players,
       max_players = excluded.max_players,
       last_seen = now()`,
    [
      body.serverId,
      body.name ?? body.serverId,
      body.map ?? null,
      body.gamemode ?? null,
      body.players ?? 0,
      body.maxPlayers ?? 128,
    ],
  );

  await redis.setex(`server:${body.serverId}`, 30, JSON.stringify(body));
  return { ok: true };
});

app.get("/servers", async () => {
  if (env.memoryMode) {
    return { servers: [...memory.servers.values()] };
  }

  const result = await pool.query(
    `select server_id as "serverId", name, map, gamemode, players,
            max_players as "maxPlayers", last_seen as "lastSeen"
     from servers
     order by server_id`,
  );
  return { servers: result.rows };
});

app.post("/players/connect", async (request) => {
  const body = playerSchema.parse(request.body);

  if (env.memoryMode) {
    memory.profiles.set(body.steamId, {
      steamId: body.steamId,
      name: body.name ?? null,
      firstSeen: memory.profiles.get(body.steamId)?.firstSeen ?? new Date().toISOString(),
      lastSeen: new Date().toISOString(),
    });
    memory.presence.set(body.steamId, {
      steamId: body.steamId,
      serverId: body.serverId,
      connected: true,
      updatedAt: new Date().toISOString(),
    });
    return logEvent({ serverId: body.serverId, type: "player.connect", steamId: body.steamId, payload: body });
  }

  await pool.query(
    `insert into player_profiles (steam_id, name, first_seen, last_seen)
     values ($1, $2, now(), now())
     on conflict (steam_id) do update set name = excluded.name, last_seen = now()`,
    [body.steamId, body.name ?? null],
  );
  await pool.query(
    `insert into player_presence (steam_id, server_id, connected, updated_at)
     values ($1, $2, true, now())
     on conflict (steam_id) do update set
       server_id = excluded.server_id,
       connected = true,
       updated_at = now()`,
    [body.steamId, body.serverId],
  );

  await redis.set(`presence:${body.steamId}`, JSON.stringify({ ...body, connected: true }));
  return logEvent({ serverId: body.serverId, type: "player.connect", steamId: body.steamId, payload: body });
});

app.post("/players/disconnect", async (request) => {
  const body = playerSchema.parse(request.body);

  if (env.memoryMode) {
    const current = memory.presence.get(body.steamId) ?? {};
    memory.presence.set(body.steamId, {
      ...current,
      steamId: body.steamId,
      serverId: body.serverId,
      connected: false,
      updatedAt: new Date().toISOString(),
    });
    return logEvent({ serverId: body.serverId, type: "player.disconnect", steamId: body.steamId, payload: body });
  }

  await pool.query(
    `update player_presence
     set connected = false, updated_at = now()
     where steam_id = $1`,
    [body.steamId],
  );
  await redis.set(`presence:${body.steamId}`, JSON.stringify({ ...body, connected: false }));
  return logEvent({ serverId: body.serverId, type: "player.disconnect", steamId: body.steamId, payload: body });
});

app.post("/players/state", async (request) => {
  const body = stateSchema.parse(request.body);

  if (env.memoryMode) {
    memory.profiles.set(body.steamId, {
      steamId: body.steamId,
      name: body.name ?? memory.profiles.get(body.steamId)?.name ?? null,
      firstSeen: memory.profiles.get(body.steamId)?.firstSeen ?? new Date().toISOString(),
      lastSeen: new Date().toISOString(),
    });
    memory.states.set(body.steamId, {
      steamId: body.steamId,
      name: body.name ?? null,
      serverId: body.serverId,
      state: body.state,
      updatedAt: new Date().toISOString(),
    });
    await publish("player.state", body);
    return { ok: true };
  }

  await pool.query(
    `insert into player_profiles (steam_id, name, first_seen, last_seen)
     values ($1, $2, now(), now())
     on conflict (steam_id) do update set name = coalesce(excluded.name, player_profiles.name), last_seen = now()`,
    [body.steamId, body.name ?? null],
  );
  await pool.query(
    `insert into player_state (steam_id, server_id, state, updated_at)
     values ($1, $2, $3, now())
     on conflict (steam_id) do update set
       server_id = excluded.server_id,
       state = excluded.state,
       updated_at = now()`,
    [body.steamId, body.serverId, body.state],
  );

  await redis.set(`state:${body.steamId}`, JSON.stringify(body));
  await publish("player.state", body);
  return { ok: true };
});

app.post("/players/states", async (request) => {
  const body = stateBatchSchema.parse(request.body);

  if (env.memoryMode) {
    const updatedAt = new Date().toISOString();
    for (const player of body.players) {
      memory.profiles.set(player.steamId, {
        steamId: player.steamId,
        name: player.name ?? memory.profiles.get(player.steamId)?.name ?? null,
        firstSeen: memory.profiles.get(player.steamId)?.firstSeen ?? updatedAt,
        lastSeen: updatedAt,
      });
      memory.presence.set(player.steamId, {
        steamId: player.steamId,
        serverId: body.serverId,
        connected: true,
        updatedAt,
      });
      memory.states.set(player.steamId, {
        steamId: player.steamId,
        name: player.name ?? null,
        serverId: body.serverId,
        state: player.state,
        updatedAt,
      });
    }
    if (body.players.length > 0) await publish("players.states", body);
    return { ok: true, count: body.players.length };
  }

  const client = await pool.connect();

  try {
    await client.query("begin");

    for (const player of body.players) {
      await client.query(
        `insert into player_profiles (steam_id, name, first_seen, last_seen)
         values ($1, $2, now(), now())
         on conflict (steam_id) do update set
           name = coalesce(excluded.name, player_profiles.name),
           last_seen = now()`,
        [player.steamId, player.name ?? null],
      );
      await client.query(
        `insert into player_presence (steam_id, server_id, connected, updated_at)
         values ($1, $2, true, now())
         on conflict (steam_id) do update set
           server_id = excluded.server_id,
           connected = true,
           updated_at = now()`,
        [player.steamId, body.serverId],
      );
      await client.query(
        `insert into player_state (steam_id, server_id, state, updated_at)
         values ($1, $2, $3, now())
         on conflict (steam_id) do update set
           server_id = excluded.server_id,
           state = excluded.state,
           updated_at = now()`,
        [player.steamId, body.serverId, player.state],
      );
    }

    await client.query("commit");
  } catch (error) {
    await client.query("rollback");
    throw error;
  } finally {
    client.release();
  }

  if (body.players.length > 0) {
    await redis.setex(`states:${body.serverId}`, 2, JSON.stringify(body));
    await publish("players.states", body);
  }

  return { ok: true, count: body.players.length };
});

app.get("/players/states", async (request) => {
  const serverId = request.query.serverId;
  const seconds = Math.min(Math.max(Number(request.query.seconds ?? 2), 1), 10);

  if (env.memoryMode) {
    const cutoff = Date.now() - seconds * 1000;
    const players = [...memory.states.values()].filter((player) => {
      const presence = memory.presence.get(player.steamId);
      return (
        presence?.connected === true &&
        new Date(player.updatedAt).getTime() > cutoff &&
        (!serverId || player.serverId !== serverId)
      );
    });
    return { players };
  }

  const args = [seconds];
  let where = "pr.connected = true and ps.updated_at > now() - ($1 * interval '1 second')";

  if (serverId) {
    args.push(serverId);
    where += " and ps.server_id <> $2";
  }

  const result = await pool.query(
    `select p.steam_id as "steamId", p.name, ps.server_id as "serverId",
            ps.state, ps.updated_at as "updatedAt"
     from player_state ps
     join player_profiles p on p.steam_id = ps.steam_id
     left join player_presence pr on pr.steam_id = ps.steam_id
     where ${where}
     order by ps.updated_at desc
     limit 256`,
    args,
  );

  return { players: result.rows };
});

app.get("/players", async () => {
  if (env.memoryMode) {
    const players = [...memory.profiles.values()].map((profile) => ({
      steamId: profile.steamId,
      name: profile.name,
      serverId: memory.presence.get(profile.steamId)?.serverId ?? null,
      connected: memory.presence.get(profile.steamId)?.connected ?? false,
      presenceUpdatedAt: memory.presence.get(profile.steamId)?.updatedAt ?? null,
      state: memory.states.get(profile.steamId)?.state ?? null,
      stateUpdatedAt: memory.states.get(profile.steamId)?.updatedAt ?? null,
    }));
    return { players };
  }

  const result = await pool.query(
    `select p.steam_id as "steamId", p.name, pr.server_id as "serverId",
            pr.connected, pr.updated_at as "presenceUpdatedAt",
            ps.state, ps.updated_at as "stateUpdatedAt"
     from player_profiles p
     left join player_presence pr on pr.steam_id = p.steam_id
     left join player_state ps on ps.steam_id = p.steam_id
     order by p.last_seen desc
     limit 512`,
  );
  return { players: result.rows };
});

app.get("/players/:steamId", async (request, reply) => {
  if (env.memoryMode) {
    const profile = memory.profiles.get(request.params.steamId);
    if (!profile) return reply.code(404).send({ error: "not found" });
    return {
      steamId: profile.steamId,
      name: profile.name,
      serverId: memory.presence.get(profile.steamId)?.serverId ?? null,
      connected: memory.presence.get(profile.steamId)?.connected ?? false,
      state: memory.states.get(profile.steamId)?.state ?? null,
    };
  }

  const result = await pool.query(
    `select p.steam_id as "steamId", p.name, pr.server_id as "serverId",
            pr.connected, ps.state
     from player_profiles p
     left join player_presence pr on pr.steam_id = p.steam_id
     left join player_state ps on ps.steam_id = p.steam_id
     where p.steam_id = $1`,
    [request.params.steamId],
  );

  if (result.rowCount === 0) return reply.code(404).send({ error: "not found" });
  return result.rows[0];
});

app.post("/events", async (request) => {
  return logEvent(eventSchema.parse(request.body));
});

app.get("/events", async (request) => {
  const since = Number(request.query.since ?? 0);
  const serverId = request.query.serverId;

  if (env.memoryMode) {
    const events = memory.events
      .filter((event) => event.id > since && (!serverId || event.serverId !== serverId))
      .slice(0, 200);
    return { events };
  }

  const args = [since];
  let where = "id > $1";

  if (serverId) {
    args.push(serverId);
    where += " and server_id <> $2";
  }

  const result = await pool.query(
    `select id, server_id as "serverId", type, steam_id as "steamId", payload,
            created_at as "createdAt"
     from event_log
     where ${where}
     order by id asc
     limit 200`,
    args,
  );

  return { events: result.rows };
});

app.get("/ws", { websocket: true }, (socket) => {
  sockets.add(socket);
  socket.on("close", () => sockets.delete(socket));
});

if (!env.memoryMode) {
  sub.subscribe("gmod.events");
  sub.on("message", (_channel, message) => {
    for (const socket of sockets) {
      if (socket.readyState === 1) socket.send(message);
    }
  });
}

await migrate();
await app.listen({ host: "0.0.0.0", port: env.port });
