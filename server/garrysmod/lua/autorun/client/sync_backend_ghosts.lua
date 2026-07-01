if SERVER then return end

local ghosts = {}
local staleAfter = 2.5

local function vectorFromTable(value)
    value = value or {}
    return Vector(tonumber(value.x) or 0, tonumber(value.y) or 0, tonumber(value.z) or 0)
end

local function angleFromTable(value)
    value = value or {}
    return Angle(tonumber(value.pitch) or 0, tonumber(value.yaw) or 0, tonumber(value.roll) or 0)
end

local function ensureGhost(player)
    local steamId = player.steamId
    local state = player.state or {}
    local model = state.model or "models/player/kleiner.mdl"
    local ghost = ghosts[steamId]

    if not ghost or not IsValid(ghost.entity) or ghost.model ~= model then
        if ghost and IsValid(ghost.entity) then
            ghost.entity:Remove()
        end

        local entity = ClientsideModel(model, RENDERGROUP_OPAQUE)
        if not IsValid(entity) then return nil end

        entity:SetNoDraw(true)
        entity:SetRenderMode(RENDERMODE_NORMAL)

        ghost = {
            entity = entity,
            model = model,
            name = player.name or steamId,
            serverId = player.serverId or "remote",
            pos = vectorFromTable(state.position),
            targetPos = vectorFromTable(state.position),
            ang = angleFromTable(state.angle),
            targetAng = angleFromTable(state.angle),
            lastSeen = CurTime(),
            alive = state.alive ~= false
        }
        ghosts[steamId] = ghost
    end

    ghost.name = player.name or steamId
    ghost.serverId = player.serverId or "remote"
    ghost.targetPos = vectorFromTable(state.position)
    ghost.targetAng = angleFromTable(state.angle)
    ghost.lastSeen = CurTime()
    ghost.alive = state.alive ~= false

    return ghost
end

net.Receive("SyncBackendGhostStates", function()
    local payload = net.ReadString()
    local players = util.JSONToTable(payload or "")
    if not istable(players) then return end

    for _, player in ipairs(players) do
        if player.steamId and player.state then
            ensureGhost(player)
        end
    end
end)

hook.Add("Think", "SyncBackendGhostThink", function()
    local now = CurTime()
    local frame = math.min(FrameTime() * 16, 1)

    for steamId, ghost in pairs(ghosts) do
        if now - ghost.lastSeen > staleAfter or not ghost.alive then
            if IsValid(ghost.entity) then
                ghost.entity:Remove()
            end
            ghosts[steamId] = nil
        elseif IsValid(ghost.entity) then
            ghost.pos = LerpVector(frame, ghost.pos, ghost.targetPos)
            ghost.ang = LerpAngle(frame, ghost.ang, ghost.targetAng)

            ghost.entity:SetPos(ghost.pos)
            ghost.entity:SetAngles(Angle(0, ghost.ang.y, 0))
            ghost.entity:SetPoseParameter("head_pitch", math.Clamp(ghost.ang.p, -89, 89))
            ghost.entity:SetPoseParameter("aim_pitch", math.Clamp(ghost.ang.p, -89, 89))
            ghost.entity:FrameAdvance(FrameTime())
        end
    end
end)

hook.Add("PostDrawOpaqueRenderables", "SyncBackendGhostDraw", function()
    for _, ghost in pairs(ghosts) do
        if IsValid(ghost.entity) then
            ghost.entity:DrawModel()
        end
    end
end)

hook.Add("HUDPaint", "SyncBackendGhostNames", function()
    for _, ghost in pairs(ghosts) do
        if IsValid(ghost.entity) then
            local screen = (ghost.pos + Vector(0, 0, 82)):ToScreen()
            if screen.visible then
                draw.SimpleTextOutlined(
                    ghost.name .. " [" .. ghost.serverId .. "]",
                    "DermaDefault",
                    screen.x,
                    screen.y,
                    Color(120, 190, 255),
                    TEXT_ALIGN_CENTER,
                    TEXT_ALIGN_CENTER,
                    1,
                    Color(0, 0, 0, 220)
                )
            end
        end
    end
end)
