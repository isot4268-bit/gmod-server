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
CreateConVar("sync_spawn_remote_entities", "1", FCVAR_ARCHIVE, "Spawn server-side entities for remote synced players")

util.AddNetworkString("SyncBackendGhostStates")

local lastEventId = 0
local testPeds = {}
local testPedBrain = {}
local remoteEntities = {}
local remoteEntityStaleAfter = 2.5
local ghostPollSerial = 0
local lastGhostPollApplied = 0

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
    local bodyAng = ply:GetAngles()
    local vel = ply:GetVelocity()
    local payload = playerPayload(ply)
    payload.state = {
        health = ply:Health(),
        armor = ply:Armor(),
        team = team.GetName(ply:Team()),
        model = ply:GetModel(),
        color = { x = ply:GetPlayerColor().x, y = ply:GetPlayerColor().y, z = ply:GetPlayerColor().z },
        position = { x = pos.x, y = pos.y, z = pos.z },
        angle = { pitch = ang.p, yaw = ang.y, roll = ang.r },
        bodyAngle = { pitch = bodyAng.p, yaw = bodyAng.y, roll = bodyAng.r },
        velocity = { x = vel.x, y = vel.y, z = vel.z },
        sequence = ply:GetSequence(),
        cycle = ply:GetCycle(),
        playbackRate = ply:GetPlaybackRate(),
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
    testPedBrain = {}
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
                ped.AutomaticFrameAdvance = true

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

local function groundPosition(pos)
    local trace = util.TraceLine({
        start = pos + Vector(0, 0, 256),
        endpos = pos - Vector(0, 0, 4096),
        mask = MASK_SOLID_BRUSHONLY
    })

    if trace.Hit then
        return trace.HitPos + Vector(0, 0, 2)
    end

    return pos
end

local function randomWalkTarget(origin, radius)
    local angle = math.Rand(0, math.pi * 2)
    local distance = math.Rand(radius * 0.25, radius)
    return groundPosition(origin + Vector(math.cos(angle) * distance, math.sin(angle) * distance, 0))
end

local function pedWalkState(index, origin, radius, speed)
    local now = CurTime()
    local brain = testPedBrain[index]

    if not brain then
        brain = {
            pos = randomWalkTarget(origin, radius * 0.5),
            target = randomWalkTarget(origin, radius),
            yaw = 0,
            waitUntil = 0
        }
        testPedBrain[index] = brain
    end

    if now < brain.waitUntil then
        return brain.pos, Angle(0, brain.yaw, 0), Vector(0, 0, 0)
    end

    local delta = brain.target - brain.pos
    delta.z = 0
    local distance = delta:Length()

    if distance < 24 then
        brain.target = randomWalkTarget(origin, radius)
        brain.waitUntil = now + math.Rand(0.2, 1.2)
        return brain.pos, Angle(0, brain.yaw, 0), Vector(0, 0, 0)
    end

    local walkSpeed = math.Clamp(95 * speed, 40, 220)
    local frame = math.max(FrameTime(), 0.05)
    local direction = delta:GetNormalized()
    local step = math.min(walkSpeed * frame, distance)
    local nextPos = groundPosition(brain.pos + direction * step)
    local velocity = (nextPos - brain.pos) / frame

    brain.pos = nextPos
    brain.yaw = direction:Angle().y

    return brain.pos, Angle(0, brain.yaw, 0), velocity
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
        local pos, ang, vel = pedWalkState(index, base, radius, speed)
        local yaw = ang.y
        local model = "models/player/kleiner.mdl"
        local alive = true

        if GetConVar("sync_test_ped_spawn_entities"):GetBool() then
            pcall(function()
                ensureTestPeds(count)

                if IsValid(testPeds[index]) then
                    local ped = testPeds[index]
                    ped:SetPos(pos)
                    ped:SetAngles(ang)
                    ped:FrameAdvance(FrameTime())
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

local function vectorFromTable(value)
    value = value or {}
    return Vector(tonumber(value.x) or 0, tonumber(value.y) or 0, tonumber(value.z) or 0)
end

local function angleFromTable(value)
    value = value or {}
    return Angle(tonumber(value.pitch) or 0, tonumber(value.yaw) or 0, tonumber(value.roll) or 0)
end

local function selectProxySequence(entity, moving, crouching)
    local acts = {}
    local function addAct(act)
        if act then table.insert(acts, act) end
    end

    if moving then
        if crouching then
            addAct(ACT_HL2MP_WALK_CROUCH)
            addAct(ACT_WALK_CROUCH)
        end
        addAct(ACT_HL2MP_WALK)
        addAct(ACT_WALK)
        addAct(ACT_HL2MP_RUN)
        addAct(ACT_RUN)
    else
        if crouching then
            addAct(ACT_HL2MP_IDLE_CROUCH)
            addAct(ACT_COVER_LOW)
        end
        addAct(ACT_HL2MP_IDLE)
        addAct(ACT_IDLE)
    end

    for _, act in ipairs(acts) do
        if act then
            local sequence = entity:SelectWeightedSequence(act)
            if sequence and sequence >= 0 then return sequence end
        end
    end

    local names = moving and {
        "walk_all",
        "walk_smg1_all",
        "walk_pistol_all",
        "walk_passive",
        "run_all"
    } or {
        "idle_all_01",
        "idle_smg1",
        "idle_pistol",
        "idle_passive",
        "idle"
    }

    for _, name in ipairs(names) do
        local sequence = entity:LookupSequence(name)
        if sequence and sequence >= 0 then return sequence end
    end

    return 0
end

local function applyModelPose(entity, state, forceCycle)
    local eyeAng = angleFromTable(state.angle)
    local bodyAng = angleFromTable(state.bodyAngle or state.angle)
    local velocity = vectorFromTable(state.velocity)
    local moveSpeed = velocity:Length2D()
    local moving = moveSpeed > 8

    entity:SetAngles(Angle(0, eyeAng.y, 0))
    entity:SetPoseParameter("head_pitch", math.Clamp(eyeAng.p, -89, 89))
    entity:SetPoseParameter("head_yaw", math.Clamp(math.AngleDifference(eyeAng.y, bodyAng.y), -90, 90))
    entity:SetPoseParameter("aim_pitch", math.Clamp(eyeAng.p, -89, 89))
    entity:SetPoseParameter("aim_yaw", math.Clamp(math.AngleDifference(eyeAng.y, bodyAng.y), -90, 90))
    entity:SetPoseParameter("move_yaw", 0)

    local sequence = tonumber(state.sequence)
    if not sequence or sequence < 0 then
        sequence = selectProxySequence(entity, moving, state.crouching == true)
    end

    if sequence and sequence >= 0 and entity:GetSequence() ~= sequence then
        entity:ResetSequence(sequence)
    end

    if forceCycle and state.cycle then
        entity:SetCycle(math.Clamp(tonumber(state.cycle) or 0, 0, 1))
    end

    local playbackRate = tonumber(state.playbackRate)
    if not playbackRate or playbackRate <= 0 then
        playbackRate = moving and math.Clamp(moveSpeed / 120, 0.65, 2.2) or 1
    end
    entity:SetPlaybackRate(playbackRate)
end

local function removeRemoteEntities()
    for _, remote in pairs(remoteEntities) do
        if IsValid(remote.entity) then
            remote.entity:Remove()
        end
    end
    remoteEntities = {}
end

local function updateRemoteEntity(player)
    if not GetConVar("sync_spawn_remote_entities"):GetBool() then
        removeRemoteEntities()
        return
    end

    local steamId = player.steamId
    local state = player.state or {}
    if not steamId or state.alive == false then return end

    local model = state.model or "models/player/kleiner.mdl"
    local targetPos = vectorFromTable(state.position)
    local targetAng = angleFromTable(state.angle)
    local remote = remoteEntities[steamId]

    if not remote or not IsValid(remote.entity) or remote.model ~= model then
        if remote and IsValid(remote.entity) then
            remote.entity:Remove()
        end

        local entity = ents.Create("prop_dynamic")
        if not IsValid(entity) then return end

        entity:SetModel(model)
        entity:SetSolid(SOLID_NONE)
        entity:SetMoveType(MOVETYPE_NONE)
        entity:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
        entity:SetNWString("SyncBackendRemoteName", player.name or steamId)
        entity:SetNWString("SyncBackendRemoteServer", player.serverId or "remote")
        entity:Spawn()
        entity.AutomaticFrameAdvance = true

        remote = {
            entity = entity,
            model = model,
            pos = targetPos,
            targetPos = targetPos,
            targetAng = targetAng,
            state = state,
            lastSeen = CurTime()
        }
        remoteEntities[steamId] = remote
    end

    remote.lastSeen = CurTime()
    remote.targetPos = targetPos
    remote.targetAng = targetAng
    remote.state = state
    remote.forceCycle = true
    remote.entity:SetNWString("SyncBackendRemoteName", player.name or steamId)
    remote.entity:SetNWString("SyncBackendRemoteServer", player.serverId or "remote")
end

hook.Add("Think", "SyncBackendRemoteEntityThink", function()
    local now = CurTime()
    local frame = FrameTime()
    local lerpAmount = math.Clamp(frame * 14, 0, 1)

    for steamId, remote in pairs(remoteEntities) do
        if not IsValid(remote.entity) or now - remote.lastSeen > remoteEntityStaleAfter then
            if IsValid(remote.entity) then
                remote.entity:Remove()
            end
            remoteEntities[steamId] = nil
        else
            local distance = remote.pos:Distance(remote.targetPos)
            if distance > 512 then
                remote.pos = remote.targetPos
            else
                remote.pos = LerpVector(lerpAmount, remote.pos, remote.targetPos)
            end

            remote.entity:SetPos(remote.pos)
            applyModelPose(remote.entity, remote.state or {}, remote.forceCycle == true)
            remote.forceCycle = false
            remote.entity:FrameAdvance(frame)
        end
    end
end)

hook.Add("ShutDown", "SyncBackendRemoveRemoteEntities", removeRemoteEntities)

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

    ghostPollSerial = ghostPollSerial + 1
    local requestSerial = ghostPollSerial
    local url = backendUrl("/players/states?seconds=2&serverId=" .. GetConVar("sync_server_id"):GetString())
    HTTP({
        method = "GET",
        url = url,
        headers = headers(),
        success = function(_, body)
            if requestSerial < lastGhostPollApplied then return end
            lastGhostPollApplied = requestSerial

            local decoded = util.JSONToTable(body or "")
            if not decoded or not decoded.players then return end

            for _, player in ipairs(decoded.players) do
                updateRemoteEntity(player)
            end

            if GetConVar("sync_spawn_remote_entities"):GetBool() then return end

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
