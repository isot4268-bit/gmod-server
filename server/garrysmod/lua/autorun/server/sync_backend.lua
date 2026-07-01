if CLIENT then return end

AddCSLuaFile("autorun/client/sync_backend_ghosts.lua")

CreateConVar("sync_backend_url", "http://127.0.0.1:8080", FCVAR_ARCHIVE, "Sync backend base URL")
CreateConVar("sync_backend_key", "change-this-long-random-key", FCVAR_ARCHIVE, "Sync backend API key")
CreateConVar("sync_server_id", "vds-13", FCVAR_ARCHIVE, "Unique shard/server id")
CreateConVar("sync_state_rate", "0.10", FCVAR_ARCHIVE, "Seconds between movement sync updates")
CreateConVar("sync_ghost_rate", "0.10", FCVAR_ARCHIVE, "Seconds between remote ghost polls")
CreateConVar("sync_test_peds", "0", FCVAR_ARCHIVE, "Publish moving test peds for cross-server sync testing")
CreateConVar("sync_test_ped_count", "4", FCVAR_ARCHIVE, "Number of moving test peds to publish")
CreateConVar("sync_test_ped_radius", "260", FCVAR_ARCHIVE, "Movement radius for test peds")
CreateConVar("sync_test_ped_speed", "1.4", FCVAR_ARCHIVE, "Movement speed for test peds")
CreateConVar("sync_test_ped_spawn_entities", "1", FCVAR_ARCHIVE, "Spawn real moving test ped entities on this server")

util.AddNetworkString("SyncBackendGhostStates")

local lastEventId = 0
local testPeds = {}

local function applyConfigLine(line)
    local key, quoted = string.match(line, '^%s*([%w_]+)%s+"([^"]*)"%s*$')
    if not key then
        key, quoted = string.match(line, "^%s*([%w_]+)%s+([^%s]+)%s*$")
    end

    if key and quoted and string.StartWith(key, "sync_") and GetConVar(key) then
        RunConsoleCommand(key, quoted)
    end
end

local function loadSyncConfig()
    local cfg = file.Read("cfg/sync_backend.cfg", "GAME")
    if cfg then
        for _, line in ipairs(string.Explode("\n", cfg)) do
            applyConfigLine(line)
        end
    else
        print("[sync-backend] cfg/sync_backend.cfg not found")
    end

    timer.Simple(0.5, function()
        print("[sync-backend] config loaded: serverId=" .. GetConVar("sync_server_id"):GetString()
            .. " testPeds=" .. tostring(GetConVar("sync_test_peds"):GetBool())
            .. " backend=" .. GetConVar("sync_backend_url"):GetString())
    end)
end

timer.Simple(1, loadSyncConfig)
timer.Simple(5, loadSyncConfig)

local function backendUrl(path)
    return GetConVar("sync_backend_url"):GetString() .. path
end

local function headers()
    return {
        ["Content-Type"] = "application/json",
        ["X-Sync-Key"] = GetConVar("sync_backend_key"):GetString()
    }
end

local function postJson(path, data)
    HTTP({
        method = "POST",
        url = backendUrl(path),
        headers = headers(),
        body = util.TableToJSON(data),
        success = function() end,
        failed = function(err)
            print("[sync-backend] POST " .. path .. " failed: " .. tostring(err))
        end
    })
end

local function playerPayload(ply)
    return {
        steamId = ply:SteamID64() or ply:SteamID(),
        name = ply:Nick(),
        serverId = GetConVar("sync_server_id"):GetString()
    }
end

local function playerState(ply)
    local pos = ply:GetPos()
    local ang = ply:EyeAngles()
    local vel = ply:GetVelocity()
    local payload = playerPayload(ply)
    payload.state = {
        health = ply:Health(),
        armor = ply:Armor(),
        team = team.GetName(ply:Team()),
        model = ply:GetModel(),
        position = { x = pos.x, y = pos.y, z = pos.z },
        angle = { pitch = ang.p, yaw = ang.y, roll = ang.r },
        velocity = { x = vel.x, y = vel.y, z = vel.z },
        crouching = ply:Crouching(),
        onGround = ply:OnGround(),
        alive = ply:Alive()
    }
    return payload
end

local function removeTestPeds()
    for _, ped in pairs(testPeds) do
        if IsValid(ped) then
            ped:Remove()
        end
    end
    testPeds = {}
end

local function ensureTestPeds(count)
    if not GetConVar("sync_test_ped_spawn_entities"):GetBool() then return end

    for index = 1, count do
        if not IsValid(testPeds[index]) then
            local ped = ents.Create("prop_dynamic")
            if IsValid(ped) then
                ped:SetModel("models/player/kleiner.mdl")
                ped:SetSolid(SOLID_BBOX)
                ped:SetMoveType(MOVETYPE_NONE)
                ped:SetCollisionGroup(COLLISION_GROUP_PLAYER)
                ped:SetNWString("SyncBackendPedName", "Sync Ped " .. index)
                ped:Spawn()

                local sequence = ped:LookupSequence("walk_all")
                if sequence and sequence >= 0 then
                    ped:ResetSequence(sequence)
                    ped:SetPlaybackRate(1)
                end

                testPeds[index] = ped
            end
        end
    end

    for index, ped in pairs(testPeds) do
        if index > count and IsValid(ped) then
            ped:Remove()
            testPeds[index] = nil
        end
    end
end

local function appendTestPeds(players)
    if not GetConVar("sync_test_peds"):GetBool() then
        removeTestPeds()
        return
    end

    local serverId = GetConVar("sync_server_id"):GetString()
    local count = math.Clamp(GetConVar("sync_test_ped_count"):GetInt(), 1, 32)
    local radius = math.Clamp(GetConVar("sync_test_ped_radius"):GetFloat(), 64, 2048)
    local speed = math.Clamp(GetConVar("sync_test_ped_speed"):GetFloat(), 0.1, 8)
    local base = Vector(0, 0, 64)
    local humans = player.GetHumans()

    if humans[1] and IsValid(humans[1]) then
        base = humans[1]:GetPos()
    end

    for index = 1, count do
        local phase = CurTime() * speed + (index / count) * math.pi * 2
        local pos = base + Vector(math.cos(phase) * radius, math.sin(phase) * radius, 0)
        local nextPos = base + Vector(math.cos(phase + 0.1) * radius, math.sin(phase + 0.1) * radius, 0)
        local vel = (nextPos - pos) * 10
        local yaw = vel:Angle().y
        local model = "models/player/kleiner.mdl"
        local alive = true

        if GetConVar("sync_test_ped_spawn_entities"):GetBool() then
            pcall(function()
                ensureTestPeds(count)

                if IsValid(testPeds[index]) then
                    local ped = testPeds[index]
                    ped:SetPos(pos)
                    ped:SetAngles(Angle(0, yaw, 0))
                    model = ped:GetModel()
                end
            end)
        end

        table.insert(players, {
            steamId = "ped:" .. serverId .. ":" .. index,
            name = "Sync Ped " .. index,
            state = {
                health = 100,
                armor = 0,
                team = "sync-test",
                model = model,
                position = { x = pos.x, y = pos.y, z = pos.z },
                angle = { pitch = 0, yaw = yaw, roll = 0 },
                velocity = { x = vel.x, y = vel.y, z = vel.z },
                crouching = false,
                onGround = true,
                alive = alive,
                synthetic = false
            }
        })
    end
end

hook.Add("ShutDown", "SyncBackendRemoveTestPeds", removeTestPeds)

hook.Add("PlayerInitialSpawn", "SyncBackendConnect", function(ply)
    timer.Simple(2, function()
        if IsValid(ply) then
            postJson("/players/connect", playerPayload(ply))
        end
    end)
end)

hook.Add("PlayerDisconnected", "SyncBackendDisconnect", function(ply)
    postJson("/players/disconnect", playerPayload(ply))
end)

hook.Add("PlayerSay", "SyncBackendChat", function(ply, text, teamOnly)
    local payload = playerPayload(ply)
    payload.type = "chat"
    payload.payload = {
        text = text,
        teamOnly = teamOnly == true
    }
    postJson("/events", payload)
end)

timer.Create("SyncBackendHeartbeat", 10, 0, function()
    postJson("/servers/" .. GetConVar("sync_server_id"):GetString() .. "/heartbeat", {
        name = GetHostName(),
        map = game.GetMap(),
        gamemode = engine.ActiveGamemode(),
        players = player.GetCount(),
        maxPlayers = game.MaxPlayers()
    })
end)

timer.Create("SyncBackendPlayerState", 0.10, 0, function()
    local interval = math.Clamp(GetConVar("sync_state_rate"):GetFloat(), 0.05, 1)
    timer.Adjust("SyncBackendPlayerState", interval, 0)

    local players = {}
    for _, ply in ipairs(player.GetHumans()) do
        local payload = playerState(ply)
        table.insert(players, {
            steamId = payload.steamId,
            name = payload.name,
            state = payload.state
        })
    end

    appendTestPeds(players)

    postJson("/players/states", {
        serverId = GetConVar("sync_server_id"):GetString(),
        players = players
    })
end)

timer.Create("SyncBackendGhostPoll", 0.10, 0, function()
    local interval = math.Clamp(GetConVar("sync_ghost_rate"):GetFloat(), 0.05, 1)
    timer.Adjust("SyncBackendGhostPoll", interval, 0)

    local url = backendUrl("/players/states?seconds=2&serverId=" .. GetConVar("sync_server_id"):GetString())
    HTTP({
        method = "GET",
        url = url,
        headers = headers(),
        success = function(_, body)
            local decoded = util.JSONToTable(body or "")
            if not decoded or not decoded.players then return end

            local encoded = util.TableToJSON(decoded.players)
            if not encoded or #encoded > 60000 then return end

            net.Start("SyncBackendGhostStates")
            net.WriteString(encoded)
            net.Broadcast()
        end,
        failed = function(err)
            print("[sync-backend] ghost poll failed: " .. tostring(err))
        end
    })
end)

timer.Create("SyncBackendEventPoll", 3, 0, function()
    local url = backendUrl("/events?serverId=" .. GetConVar("sync_server_id"):GetString() .. "&since=" .. lastEventId)
    HTTP({
        method = "GET",
        url = url,
        headers = headers(),
        success = function(_, body)
            local decoded = util.JSONToTable(body or "")
            if not decoded or not decoded.events then return end

            for _, event in ipairs(decoded.events) do
                lastEventId = math.max(lastEventId, tonumber(event.id) or lastEventId)
                hook.Run("SyncBackendEvent", event)
            end
        end,
        failed = function(err)
            print("[sync-backend] event poll failed: " .. tostring(err))
        end
    })
end)
