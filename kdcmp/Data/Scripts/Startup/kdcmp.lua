-- KCD2 Multiplayer - Mod Init Script
System.LogAlways("[KCD2-MP] === MOD INIT ===")

KCD2MP = {}
KCD2MP.running = false
KCD2MP.interpRunning = false
KCD2MP.tickCount = 0
KCD2MP.ghosts = {}
KCD2MP.workingClass = "NPC"

-- ===== Math Helpers =====

local function lerpVal(a, b, t)
    return a + (b - a) * t
end

-- Shortest-path angle lerp (radians), handles -pi/pi wrap
local function lerpAngle(a, b, t)
    local diff = b - a
    local twopi = math.pi * 2
    diff = diff - math.floor((diff + math.pi) / twopi) * twopi
    return a + diff * t
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- ===== Player Position =====

function KCD2MP_GetPos()
    if player then
        local pos = player:GetWorldPos()
        if pos then
            System.LogAlways(string.format("[KCD2-MP] pos: x=%.1f y=%.1f z=%.1f", pos.x, pos.y, pos.z))
            return pos
        end
    else
        System.LogAlways("[KCD2-MP] player is nil")
    end
    return nil
end

function KCD2MP_WritePos()
    if not player then return false end
    local pos = player:GetWorldPos()
    if not pos then return false end

    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    local rotZ = ang and ang.z or 0

    System.LogAlways(string.format("[KCD2-MP-DATA] %.2f,%.2f,%.2f,%.2f", pos.x, pos.y, pos.z, rotZ))
    return true
end

-- ===== Ghost NPC Spawn =====

function KCD2MP_SpawnGhost(id, x, y, z, rotZ)
    if KCD2MP.ghosts[id] then
        KCD2MP_RemoveGhost(id)
    end

    local pos = {x=x, y=y, z=z}
    local name = "kcd2mp_" .. id

    System.LogAlways(string.format("[KCD2-MP] Spawning ghost '%s' at %.1f,%.1f,%.1f", id, x, y, z))

    local ok, entity = pcall(System.SpawnEntity, {
        class = KCD2MP.workingClass,
        position = pos,
        name = name,
    })

    if not ok or not entity then
        System.LogAlways("[KCD2-MP] SpawnEntity failed: " .. tostring(entity))
        return nil
    end

    System.LogAlways("[KCD2-MP] Spawned entityId=" .. tostring(entity.id))

    local r = rotZ or 0

    -- Interpolation state: buffer with prev packet (A) and target packet (B)
    -- alpha: 0 = at A, 1 = at B, >1 = dead reckoning beyond B
    -- alphaStep: how much alpha advances per 50ms tick (= 50ms / packetInterval)
    --   default assumes 200ms server tick -> step = 0.25 (reaches B in 4 ticks)
    local istate = {
        -- Previous packet (lerp source)
        px = x, py = y, pz = z, pr = r,
        -- Target packet (lerp destination)
        tx = x, ty = y, tz = z, tr = r,
        -- Current rendered position
        cx = x, cy = y, cz = z, cr = r,
        -- Interpolation progress
        alpha = 1.0,
        alphaStep = 0.25,
        -- Dead reckoning velocity (units/sec), computed from last two packets
        vx = 0, vy = 0, vz = 0,
        -- Ticks since last server packet (for dead reckoning timeout)
        ticksSincePacket = 0,
        -- Packet arrival count (for logging)
        packetCount = 0,
    }

    local hasChar = false
    pcall(function() hasChar = entity:IsSlotCharacter(0) end)
    if not hasChar then
        pcall(function()
            entity:LoadLight(0, {
                radius = 3,
                diffuse_color = {x=0, y=1, z=0},
                diffuse_multiplier = 10,
                cast_shadow = 0,
            })
        end)
    end

    KCD2MP.ghosts[id] = {
        entity = entity,
        entityId = entity.id,
        istate = istate,
    }

    -- Auto-start interp loop as soon as we have a ghost to move
    KCD2MP_StartInterp()

    return entity
end

-- ===== Ghost Update (called by server each packet) =====

-- SERVER_INTERVAL: expected time between server packets in seconds.
-- Used to compute alphaStep so interpolation reaches target in ~1 packet interval.
local SERVER_INTERVAL = 0.2  -- 200ms

function KCD2MP_UpdateGhost(id, x, y, z, rotZ)
    local ghost = KCD2MP.ghosts[id]

    -- Spawn if doesn't exist yet
    if not ghost or not ghost.entity then
        KCD2MP_SpawnGhost(id, x, y, z, rotZ)
        return
    end

    local istate = ghost.istate
    if not istate then
        -- Shouldn't happen, but recover
        KCD2MP_SpawnGhost(id, x, y, z, rotZ)
        return
    end

    local r = rotZ or istate.tr

    -- Compute dead reckoning velocity from delta between last two targets
    -- velocity = (newTarget - oldTarget) / serverInterval
    istate.vx = (x - istate.tx) / SERVER_INTERVAL
    istate.vy = (y - istate.ty) / SERVER_INTERVAL
    istate.vz = (z - istate.tz) / SERVER_INTERVAL

    -- Adjust alphaStep based on measured packet interval
    -- ticksSincePacket * 50ms = measured interval
    if istate.ticksSincePacket > 0 then
        local measuredInterval = istate.ticksSincePacket * 0.05
        -- alphaStep = 50ms / measured_interval, clamped to [0.1, 1.0]
        istate.alphaStep = clamp(0.05 / measuredInterval, 0.1, 1.0)
    end

    -- New prev = where ghost is RIGHT NOW (current lerped pos)
    istate.px = istate.cx
    istate.py = istate.cy
    istate.pz = istate.cz
    istate.pr = istate.cr

    -- New target
    istate.tx = x
    istate.ty = y
    istate.tz = z
    istate.tr = r

    -- Reset interpolation to start from current pos toward new target
    istate.alpha = 0.0
    istate.ticksSincePacket = 0
    istate.packetCount = istate.packetCount + 1

    if istate.packetCount % 20 == 1 then
        System.LogAlways(string.format("[KCD2-MP] ghost '%s' packet#%d target=%.1f,%.1f,%.1f step=%.3f",
            id, istate.packetCount, x, y, z, istate.alphaStep))
    end
end

-- Auto-start interp tick (safe to call multiple times)
function KCD2MP_StartInterp()
    if KCD2MP.interpRunning then return end
    KCD2MP.interpRunning = true
    System.LogAlways("[KCD2-MP] Interp tick started (50ms)")
    Script.SetTimer(50, KCD2MP_InterpTick)
end

-- ===== Interpolation Tick (50ms) =====

-- How many 50ms ticks beyond alpha=1 before we start dead reckoning
-- 6 ticks = 300ms (1.5x default packet interval)
local DR_START_TICKS = 6
-- Max extrapolation time in seconds (cap dead reckoning)
local DR_MAX_SECS = 1.0

function KCD2MP_InterpTick()
    if not KCD2MP.interpRunning then return end

    for id, ghost in pairs(KCD2MP.ghosts) do
        local istate = ghost.istate
        if istate and ghost.entity then
            istate.ticksSincePacket = istate.ticksSincePacket + 1
            istate.alpha = istate.alpha + istate.alphaStep

            local x, y, z, r

            if istate.alpha <= 1.0 then
                -- === Normal interpolation: lerp prev -> target ===
                x = lerpVal(istate.px, istate.tx, istate.alpha)
                y = lerpVal(istate.py, istate.ty, istate.alpha)
                z = lerpVal(istate.pz, istate.tz, istate.alpha)
                r = lerpAngle(istate.pr, istate.tr, istate.alpha)

            elseif istate.ticksSincePacket <= DR_START_TICKS then
                -- === Holding at target, waiting for next packet ===
                x = istate.tx
                y = istate.ty
                z = istate.tz
                r = istate.tr

            else
                -- === Dead reckoning: extrapolate beyond target ===
                -- Extra ticks beyond DR_START_TICKS, converted to seconds
                local extraSecs = (istate.ticksSincePacket - DR_START_TICKS) * 0.05
                extraSecs = math.min(extraSecs, DR_MAX_SECS)
                x = istate.tx + istate.vx * extraSecs
                y = istate.ty + istate.vy * extraSecs
                z = istate.tz + istate.vz * extraSecs
                r = istate.tr
            end

            -- Save current rendered position (used as prev-source on next packet)
            istate.cx = x
            istate.cy = y
            istate.cz = z
            istate.cr = r

            -- Apply to entity
            local ok, err = pcall(function()
                ghost.entity:SetWorldPos({x=x, y=y, z=z})
                ghost.entity:SetWorldAngles({x=0, y=0, z=r})
            end)
            if not ok then
                System.LogAlways("[KCD2-MP] InterpTick err on '" .. id .. "': " .. tostring(err))
                ghost.entity = nil
            end
        end
    end

    Script.SetTimer(50, KCD2MP_InterpTick)
end

-- ===== Main Tick (500ms) - position reporting =====

function KCD2MP_Tick()
    KCD2MP.tickCount = KCD2MP.tickCount + 1
    local ok, err = pcall(function()
        KCD2MP_WritePos()

        if KCD2MP.tickCount % 20 == 0 then
            local ghostCount = 0
            for _ in pairs(KCD2MP.ghosts) do ghostCount = ghostCount + 1 end
            System.LogAlways(string.format("[KCD2-MP] tick=%d ghosts=%d",
                KCD2MP.tickCount, ghostCount))
        end
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] Tick error: " .. tostring(err))
    end
    if KCD2MP.running then
        Script.SetTimer(500, KCD2MP_Tick)
    end
end

-- ===== Ghost Remove =====

function KCD2MP_RemoveGhost(id)
    local ghost = KCD2MP.ghosts[id]
    if not ghost then return end
    if ghost.entityId then
        pcall(function() System.RemoveEntity(ghost.entityId) end)
    end
    KCD2MP.ghosts[id] = nil
    System.LogAlways("[KCD2-MP] Removed ghost: " .. id)
end

function KCD2MP_RemoveAllGhosts()
    local count = 0
    for id, _ in pairs(KCD2MP.ghosts) do
        KCD2MP_RemoveGhost(id)
        count = count + 1
    end
    System.LogAlways("[KCD2-MP] Removed " .. count .. " ghosts")
end

-- ===== Start / Stop =====

function KCD2MP_Start()
    if KCD2MP.running then
        System.LogAlways("[KCD2-MP] Already running")
        return
    end
    KCD2MP.running = true
    KCD2MP.tickCount = 0
    System.LogAlways("[KCD2-MP] Starting (pos tick=500ms, interp tick=50ms)")
    Script.SetTimer(500, KCD2MP_Tick)
    KCD2MP_StartInterp()
end

function KCD2MP_Stop()
    KCD2MP.running = false
    KCD2MP.interpRunning = false
    KCD2MP_RemoveAllGhosts()
    System.LogAlways("[KCD2-MP] Stopped")
end

-- ===== Test / Inspect =====

function KCD2MP_SpawnTest()
    if not player then return end
    local pos = player:GetWorldPos()
    if not pos then return end

    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    local ox, oy = 3, 0
    if ang then
        ox = math.sin(ang.z) * 3
        oy = math.cos(ang.z) * 3
    end

    KCD2MP_SpawnGhost("test_ghost", pos.x + ox, pos.y + oy, pos.z, ang and ang.z or 0)
end

function KCD2MP_InspectGhost()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] No ghost. Run mp_spawn_test first.")
        return
    end

    local ent = ghost.entity
    local istate = ghost.istate
    System.LogAlways("[KCD2-MP] === GHOST INSPECT ===")
    pcall(function() System.LogAlways("[KCD2-MP] name=" .. tostring(ent:GetName())) end)
    pcall(function() System.LogAlways("[KCD2-MP] class=" .. tostring(ent.class)) end)
    if istate then
        System.LogAlways(string.format("[KCD2-MP] interp: alpha=%.3f step=%.3f ticksSince=%d packets=%d",
            istate.alpha, istate.alphaStep, istate.ticksSincePacket, istate.packetCount))
        System.LogAlways(string.format("[KCD2-MP] prev=%.1f,%.1f,%.1f  target=%.1f,%.1f,%.1f  cur=%.1f,%.1f,%.1f",
            istate.px, istate.py, istate.pz,
            istate.tx, istate.ty, istate.tz,
            istate.cx, istate.cy, istate.cz))
        System.LogAlways(string.format("[KCD2-MP] velocity=%.2f,%.2f,%.2f u/s",
            istate.vx, istate.vy, istate.vz))
    end
    pcall(function()
        local pos = ent:GetWorldPos()
        System.LogAlways(string.format("[KCD2-MP] entity pos=%.2f,%.2f,%.2f", pos.x, pos.y, pos.z))
    end)
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Discovery helpers (unchanged) =====

function KCD2MP_FindNPCs()
    System.LogAlways("[KCD2-MP] === FINDING HUMAN NPCs ===")
    if not player then return end

    local ppos = player:GetWorldPos()

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 100)
        if not ents then return end

        local npcCount = 0
        for _, ent in ipairs(ents) do
            local hasChar = false
            pcall(function() hasChar = ent:IsSlotCharacter(0) end)

            if hasChar then
                local isHuman = false
                pcall(function()
                    if ent.soul or ent.human or ent.actor then isHuman = true end
                end)

                if isHuman then
                    local name = "?"
                    local eclass = "?"
                    pcall(function() name = ent:GetName() end)
                    pcall(function() eclass = ent.class or "?" end)

                    npcCount = npcCount + 1
                    System.LogAlways(string.format("[KCD2-MP] NPC: name=%s class=%s",
                        tostring(name), tostring(eclass)))

                    if npcCount >= 10 then
                        System.LogAlways("[KCD2-MP] ... (first 10 only)")
                        break
                    end
                end
            end
        end

        System.LogAlways("[KCD2-MP] Found " .. npcCount .. " human NPCs within 100m")
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] FindNPCs error: " .. tostring(err))
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Register Console Commands =====

local ok, err = pcall(function()
    System.AddCCommand("mp_pos",         "KCD2MP_GetPos()",         "Get player position")
    System.AddCCommand("mp_start",       "KCD2MP_Start()",          "Start MP sync")
    System.AddCCommand("mp_stop",        "KCD2MP_Stop()",           "Stop MP sync")
    System.AddCCommand("mp_spawn_test",  "KCD2MP_SpawnTest()",      "Spawn test ghost")
    System.AddCCommand("mp_remove_all",  "KCD2MP_RemoveAllGhosts()","Remove all ghosts")
    System.AddCCommand("mp_inspect",     "KCD2MP_InspectGhost()",   "Inspect ghost interp state")
    System.AddCCommand("mp_find_npcs",   "KCD2MP_FindNPCs()",       "Find nearby human NPCs")
    System.LogAlways("[KCD2-MP] Commands OK")
end)
if not ok then
    System.LogAlways("[KCD2-MP] Command error: " .. tostring(err))
end

-- ===== Player hook =====

local ok2, err2 = pcall(function()
    if Player and Player.Client then
        local origOnInit = Player.Client.OnInit
        Player.Client.OnInit = function(self)
            if origOnInit then origOnInit(self) end
            System.LogAlways("[KCD2-MP] Player loaded!")
            KCD2MP_GetPos()
        end
        System.LogAlways("[KCD2-MP] Player hook OK")
    end
end)
if not ok2 then
    System.LogAlways("[KCD2-MP] Hook error: " .. tostring(err2))
end
