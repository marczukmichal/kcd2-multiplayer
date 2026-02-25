-- KCD2 Multiplayer - Mod Init Script
System.LogAlways("[KCD2-MP] === MOD INIT ===")

KCD2MP = {}
KCD2MP.running = false
KCD2MP.interpRunning = false
KCD2MP.tickCount = 0
KCD2MP.ghosts = {}
KCD2MP.workingClass = "AnimObject"
KCD2MP.playerSneaking = false   -- set by OnAction hook when sneak key pressed
KCD2MP.logActions = true        -- log all action names on first use (find sneak action name)

-- ===== Debug Logger =====
-- Messages are queued in KCD2MP.debugLog (max 50).
-- Server polls KCD2MP_PopLog() via evalLua and prints to its console.
KCD2MP.debugLog = {}
local MP_LOG_MAX = 50

local function mp_log(msg)
    local entry = string.format("[%.2f] %s", os.clock(), msg)
    table.insert(KCD2MP.debugLog, entry)
    if #KCD2MP.debugLog > MP_LOG_MAX then
        table.remove(KCD2MP.debugLog, 1)
    end
end

-- Server calls this via evalLua to dequeue one message at a time
function KCD2MP_PopLog()
    if #KCD2MP.debugLog > 0 then
        return table.remove(KCD2MP.debugLog, 1)
    end
    return ""
end

mp_log("MOD INIT")

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

    -- Load armor character model (AnimObject has no Mannequin ADB = no crash)
    local cdfPath = "Objects/characters/humans/male/skeleton/preview/male_preview_armor.cdf"
    pcall(function()
        local charOk = entity:LoadCharacter(0, cdfPath)
        System.LogAlways("[KCD2-MP] LoadCharacter: " .. tostring(charOk))
    end)

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
        -- Last ACTUAL packet position (separate from tx/ty which DR extends)
        lastPacketX = x, lastPacketY = y,
        -- Ticks since last server packet (for dead reckoning timeout)
        ticksSincePacket = 0,
        -- Packet arrival count (for logging)
        packetCount = 0,
        -- Animation state
        animTag = "idle",     -- "idle"/"walk"/"run" - current animation state
        smoothedSpeed = 0,
        prevCx = x, prevCy = y,
        speedDropTicks = 0,   -- consecutive ticks with low speed after high speed
    }

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
local SERVER_INTERVAL = 0.05  -- 50ms (exchange-based server tick)

function KCD2MP_UpdateGhost(id, x, y, z, rotZ, stance)
    local ghost = KCD2MP.ghosts[id]

    -- Spawn if doesn't exist yet
    if not ghost or not ghost.entity then
        KCD2MP_SpawnGhost(id, x, y, z, rotZ)
        return
    end

    local istate = ghost.istate
    if not istate then
        KCD2MP_SpawnGhost(id, x, y, z, rotZ)
        return
    end

    local r = rotZ or istate.tr

    -- Velocity from actual packet positions (for dead reckoning).
    -- Use lastPacketX/Y (real previous packet pos), NOT tx/ty which dead reckoning extends.
    local ddx = x - (istate.lastPacketX or x)
    local ddy = y - (istate.lastPacketY or y)
    local raw_vx = ddx / SERVER_INTERVAL
    local raw_vy = ddy / SERVER_INTERVAL
    istate.vx = lerpVal(istate.vx or 0, raw_vx, 0.5)
    istate.vy = lerpVal(istate.vy or 0, raw_vy, 0.5)
    istate.lastPacketX = x
    istate.lastPacketY = y

    -- Log large target jumps; reset velocity on teleport/fast-travel
    local jumpDist = math.sqrt(ddx*ddx + ddy*ddy + (z - (istate.tz or z))*(z - (istate.tz or z)))
    if jumpDist > 5.0 then
        istate.vx = 0
        istate.vy = 0
        mp_log(string.format("JUMP id=%s dist=%.2f vx/vy reset", id, jumpDist))
    elseif jumpDist > 2.0 then
        mp_log(string.format("JUMP id=%s dist=%.2f", id, jumpDist))
    end

    istate.tx = x
    istate.ty = y
    istate.tz = z
    istate.tr = r
    istate.stance = stance or "s"
    istate.ticksSincePacket = 0
    istate.packetCount = istate.packetCount + 1

    if istate.packetCount % 40 == 1 then
        local spd = math.sqrt(raw_vx*raw_vx + raw_vy*raw_vy)
        mp_log(string.format("pkt#%d id=%s pos=%.1f,%.1f,%.1f spd=%.1f",
            istate.packetCount, id, x, y, z, spd))
    end
end

-- ===== Exchange: read local player state + apply ghost from other player =====
-- Returns CSV "x,y,z,rotZ,stance"  (stance: "s"=stand, "c"=crouch/sneak)
-- gstance: other player's stance to apply to ghost
function KCD2MP_Exchange(ghost_id, gx, gy, gz, gr, gstance)
    -- Apply incoming ghost state
    if ghost_id and gx then
        KCD2MP_UpdateGhost(ghost_id, gx, gy, gz, gr, gstance)
    end
    -- Read and return local player state
    if not player then return "" end
    local pos = player:GetWorldPos()
    if not pos then return "" end
    local rot = 0
    pcall(function()
        local ang = player:GetWorldAngles()
        if ang then rot = ang.z or 0 end
    end)
    -- Stance: use OnAction-tracked flag (most reliable in KCD2)
    -- Fallback to engine API in case action hook missed something
    local stance = "s"
    if KCD2MP.playerSneaking then
        stance = "c"
    else
        pcall(function()
            local s = player:GetStance()
            if s == 2 or s == 3 then stance = "c" end
        end)
        if stance == "s" then
            pcall(function()
                if player.actor and player.actor.bSneaking then stance = "c" end
            end)
        end
    end
    return string.format("%.3f,%.3f,%.3f,%.4f,%s", pos.x, pos.y, pos.z, rot, stance)
end

-- Auto-start interp tick (safe to call multiple times)
function KCD2MP_StartInterp()
    if KCD2MP.interpRunning then return end
    KCD2MP.interpRunning = true
    System.LogAlways("[KCD2-MP] Interp tick started (20ms)")
    Script.SetTimer(20, KCD2MP_InterpTick)
end

-- ===== Animation Update =====

-- Sneak animation candidates (probed on first use, result cached).
local SNEAK_WALK_ANIMS = {
    "3d_sneak_walk_turn_strafe",
    "3d_sneaking_walk_turn_strafe",
    "3d_stealth_walk_turn_strafe",
    "3d_crouch_walk_turn_strafe",
}
local SNEAK_IDLE_ANIMS = {
    "sneak_idle_both",
    "sneaking_idle_both",
    "stealth_idle_both",
    "crouch_idle_both",
}
KCD2MP._sneakWalkAnim = nil
KCD2MP._sneakIdleAnim = nil

local function findAnim(entity, candidates)
    for _, name in ipairs(candidates) do
        local len = 0
        pcall(function() len = entity:GetAnimationLength(0, name) or 0 end)
        if len > 0 then return name end
    end
    return nil
end

-- Hysteresis thresholds (m/s).
-- Different enter/exit speeds prevent oscillation when speed hovers at a boundary.
-- Enter: must EXCEED this speed to switch INTO this state.
-- Exit:  must DROP BELOW this speed to switch OUT of this state (go lower).
local ANIM_UP   = { walk=1.5, run=4.5, sprint=6.5 }
local ANIM_DOWN = { walk=0.7, run=3.5, sprint=5.5 }

local function calcAnimTag(speed, cur, stance)
    if stance == "c" then
        return speed > 0.3 and "sneak_walk" or "sneak_idle"
    end
    -- Start from current tag and check if we cross hysteresis bands.
    local t = cur or "idle"
    if t == "sprint" then
        if speed < ANIM_DOWN.sprint then t = "run"   else return "sprint" end
    end
    if t == "run" then
        if     speed >= ANIM_UP.sprint  then return "sprint"
        elseif speed <  ANIM_DOWN.run   then t = "walk"  else return "run" end
    end
    if t == "walk" then
        if     speed >= ANIM_UP.sprint  then return "sprint"
        elseif speed >= ANIM_UP.run     then return "run"
        elseif speed <  ANIM_DOWN.walk  then return "idle" else return "walk" end
    end
    -- idle / sneak states
    if     speed >= ANIM_UP.sprint then return "sprint"
    elseif speed >= ANIM_UP.run    then return "run"
    elseif speed >= ANIM_UP.walk   then return "walk"
    else                                 return "idle" end
end

function KCD2MP_UpdateAnimation(id, ghost)
    local istate = ghost.istate
    local speed = istate.smoothedSpeed or 0
    local stance = istate.stance or "s"

    -- Sanity: can't be sneaking at running speeds (auto-clears bad toggle state)
    if stance == "c" and speed > 4.0 then stance = "s" end
    local wantTag = calcAnimTag(speed, istate.animTag, stance)

    if istate.animTag == wantTag then return end
    local prevTag = istate.animTag or "?"
    istate.animTag = wantTag

    local animName
    if wantTag == "sneak_walk" then
        if not KCD2MP._sneakWalkAnim then
            KCD2MP._sneakWalkAnim = findAnim(ghost.entity, SNEAK_WALK_ANIMS)
                                    or "3d_relaxed_walk_turn_strafe"
            mp_log("SneakWalkAnim: " .. KCD2MP._sneakWalkAnim)
        end
        animName = KCD2MP._sneakWalkAnim
    elseif wantTag == "sneak_idle" then
        if not KCD2MP._sneakIdleAnim then
            KCD2MP._sneakIdleAnim = findAnim(ghost.entity, SNEAK_IDLE_ANIMS)
                                    or "relaxed_idle_both"
            mp_log("SneakIdleAnim: " .. KCD2MP._sneakIdleAnim)
        end
        animName = KCD2MP._sneakIdleAnim
    else
        local anims = {
            sprint = "3d_relaxed_sprint_turn_strafe",
            run    = "3d_relaxed_run_turn_strafe",
            walk   = "3d_relaxed_walk_turn_strafe",
            idle   = "relaxed_idle_both",
        }
        animName = anims[wantTag]
    end

    -- Don't restart if the same animation is already playing (avoids mid-stride reset)
    local alreadyPlaying = false
    pcall(function() alreadyPlaying = ghost.entity:IsAnimationRunning(0, animName) end)
    if not alreadyPlaying then
        -- blend=0.4s: long enough to smoothly cross-fade without feeling sluggish
        pcall(function() ghost.entity:StartAnimation(0, animName, 0, 0.4, 1.0, true) end)
    end
    mp_log(string.format("Anim: %s %s->%s spd=%.1f sta=%s [%s]%s",
        id, prevTag, wantTag, speed, stance, animName,
        alreadyPlaying and " (skip-restart)" or ""))
end

-- ===== Interpolation Tick (20ms) =====

-- Floor detection: physics raycast hits real geometry (roads, rocks, bridges).
-- Falls back to terrain elevation if raycast unavailable.
local function getFloorZ(x, y, curZ)
    local floorZ = nil
    local reliable = false

    -- Physics raycast: origin 2m above ghost, ray goes 12m DOWN.
    -- Direction vector magnitude = ray length in CryEngine: {z=-12} = 12m downward.
    -- This covers range [curZ+2 .. curZ-10] - hits bridges, stairs, terrain.
    -- Flags 15 = ent_terrain(1)|ent_static(2)|ent_rigid(4)|ent_sleeping_rigid(8)
    pcall(function()
        local hits = Physics.RayWorldIntersection(
            {x=x, y=y, z=curZ + 2.0},
            {x=0,  y=0, z=-12},
            15,
            1
        )
        if hits and hits[1] then
            local h = hits[1]

            -- Log raycast field layout once (helps identify correct field name)
            if not KCD2MP._rayFmtLogged then
                KCD2MP._rayFmtLogged = true
                local parts = {}
                for k, v in pairs(h) do
                    if type(v) == "number" then
                        parts[#parts+1] = k .. "=" .. string.format("%.2f", v)
                    elseif type(v) == "table" then
                        parts[#parts+1] = k .. "={z=" .. tostring(v.z) .. "}"
                    end
                end
                mp_log("RAY_FORMAT: " .. table.concat(parts, " "))
            end

            -- CryEngine may return hit point as h.pt, h.pos, or h.point
            local hz = nil
            if     h.pt    then hz = h.pt.z
            elseif h.pos   then hz = h.pos.z
            elseif h.point then hz = h.point.z
            end
            -- Accept hits within 10m below current position
            if hz and hz > curZ - 10.0 then
                floorZ   = hz
                reliable = true
            end
        end
    end)

    -- Fallback to terrain mesh (underestimates height on bridges/platforms)
    if not floorZ then
        pcall(function()
            local gz = Terrain.GetElevation(x, y)
            if gz then floorZ = gz end
        end)
    end

    return floorZ, reliable
end

function KCD2MP_InterpTick()
    if not KCD2MP.interpRunning then return end

    for id, ghost in pairs(KCD2MP.ghosts) do
        local istate = ghost.istate
        if istate and ghost.entity then
            istate.ticksSincePacket = istate.ticksSincePacket + 1

            -- If ghost drifted very far from target (>5m), teleport directly.
            -- Prevents STEP_CAP from locking ghost hundreds of meters away.
            local distSq = (istate.tx-istate.cx)*(istate.tx-istate.cx)
                         + (istate.ty-istate.cy)*(istate.ty-istate.cy)
                         + (istate.tz-istate.cz)*(istate.tz-istate.cz)
            if distSq > 25.0 then
                mp_log(string.format("TELEPORT id=%s dist=%.1f", id, math.sqrt(distSq)))
                istate.cx = istate.tx
                istate.cy = istate.ty
                istate.cz = istate.tz
                istate.cr = istate.tr
            end

            -- Non-destructive DR: project render target forward WITHOUT touching istate.tx/ty.
            -- istate.tx/ty stays = last received packet. When next packet arrives it's
            -- simply overwritten - no snap-back rubber-band.
            -- DR just makes the ghost look ahead of the last-known position while waiting
            -- for the next packet, keeping movement smooth at sprint speeds.
            local renderX = istate.tx or istate.cx
            local renderY = istate.ty or istate.cy
            local DR_MAX = 3  -- 3 * 20ms = 60ms lookahead (covers 50ms packet gap)
            local ticks = istate.ticksSincePacket or 0
            if ticks >= 1 and ticks <= DR_MAX then
                local vx = istate.vx or 0
                local vy = istate.vy or 0
                if math.sqrt(vx*vx + vy*vy) > 0.5 then
                    renderX = renderX + vx * (ticks * 0.020)
                    renderY = renderY + vy * (ticks * 0.020)
                end
            end

            -- Smooth ghost toward render target (DR-extended, never snaps back)
            local factor = 0.5
            local nx = lerpVal(istate.cx, renderX, factor)
            local ny = lerpVal(istate.cy, renderY, factor)
            local nz = lerpVal(istate.cz, istate.tz or istate.cz, factor)

            istate.cx = nx
            istate.cy = ny
            istate.cz = nz
            istate.cr = lerpAngle(istate.cr, istate.tr, factor)

            local x = istate.cx
            local y = istate.cy
            local z = istate.cz
            local r = istate.cr

            -- Floor snap: correct ghost Z against raycast floor.
            -- Snap-UP: underground up to 10m (handles slopes, slight embedding).
            -- Snap-DOWN: hovering up to 2m (hover fix; >2m cap prevents snapping off bridges).
            local sz = z
            local floorZ, reliable = getFloorZ(x, y, z)
            if floorZ then
                local diff = sz - floorZ
                if diff < -0.05 and diff > -10.0 then
                    -- Underground up to 10m: snap up to floor
                    sz = floorZ
                    istate.cz = floorZ
                elseif diff > 0.05 and diff < 2.0 then
                    -- Hovering up to 2m above floor: snap down
                    sz = floorZ
                end
            end

            -- Apply position + rotation
            local ok, err = pcall(function()
                ghost.entity:SetWorldPos({x=x, y=y, z=sz})
                ghost.entity:SetWorldAngles({x=0, y=0, z=r})
            end)
            if not ok then
                System.LogAlways("[KCD2-MP] InterpTick err '" .. id .. "': " .. tostring(err))
                ghost.entity = nil
            else
                -- === Animation speed from PACKET velocity, NOT rendered position ===
                -- istate.vx/vy = velocity from actual packet positions (smoothed EMA 0.5).
                -- Using rendered position delta caused STEP_CAP artifacts: ghost slowed
                -- by cap then surged to catch up → speed oscillated 3→7→3 m/s per tick.
                local pvx = istate.vx or 0
                local pvy = istate.vy or 0
                local packetSpeed = math.sqrt(pvx*pvx + pvy*pvy)
                -- Light EMA so speed follows packet changes without being too jumpy.
                istate.smoothedSpeed = lerpVal(istate.smoothedSpeed or 0, packetSpeed, 0.25)

                KCD2MP_UpdateAnimation(id, ghost)
            end
        end
    end

    Script.SetTimer(20, KCD2MP_InterpTick)
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

-- ===== Animation Discovery =====

-- Probe animation names - only GetAnimationLength > 0 is reliable
function KCD2MP_ProbeAnims()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] ProbeAnims: no ghost.")
        return
    end
    local ent = ghost.entity

    -- Full CryEngine path variants (no extension) + short names
    local candidates = {
        -- Short names
        "idle", "run", "walk", "sprint", "jog",
        "Idle", "Run", "Walk", "Sprint",
        -- Full path guesses (KCD2 convention)
        "animations/humans/male/locomotion/run_loop",
        "animations/humans/male/locomotion/walk_loop",
        "animations/humans/male/locomotion/idle_loop",
        "animations/humans/male/locomotion/run_fwd",
        "animations/humans/male/locomotion/walk_fwd",
        "animations/humans/male/locomotion/sprint_loop",
        "animations/humans/male/locomotion/run",
        "animations/humans/male/locomotion/walk",
        "animations/humans/male/locomotion/idle",
        -- KCD1-style paths
        "animations/characters/humans/male/locomotion/run_loop",
        "animations/characters/humans/male/locomotion/walk_loop",
        "animations/characters/humans/male/locomotion/idle_loop",
        -- Assets subfolder
        "animations/assets/humans/locomotion/run_loop",
        "animations/assets/humans/locomotion/walk_loop",
        -- Mannequin fragment names
        "MotionIdle", "MotionRun", "MotionWalk",
        "LocomotionIdle", "LocomotionRun", "LocomotionWalk",
        "Locomotion", "locomotion",
    }

    System.LogAlways("[KCD2-MP] === PROBING ANIMS ON GHOST ===")
    for _, name in ipairs(candidates) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        if len > 0 then
            System.LogAlways(string.format("[KCD2-MP] HIT: '%s' len=%.3f", name, len))
        end
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Find nearby HUMAN NPC and get their character model path, then copy to ghost
function KCD2MP_CopyNPCModel()
    if not player then return end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === FIND HUMAN NPC + COPY MODEL ===")

    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] No ghost entity! Run server first.")
        return
    end

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 50)
        if not ents then return end

        local humanCount = 0
        for _, ent in ipairs(ents) do
            if ent ~= player then
                -- Must have soul or human (real human NPC, not horse/door/chest)
                local isHuman = false
                pcall(function()
                    isHuman = (ent.soul ~= nil) or (ent.human ~= nil)
                end)
                if not isHuman then
                    -- Also accept NPCs with actor table
                    pcall(function()
                        if ent.actor and ent.actor.__this then isHuman = true end
                    end)
                end

                if isHuman then
                    local ename = "?"
                    pcall(function() ename = ent:GetName() end)
                    local eclass = "?"
                    pcall(function() eclass = ent.class or "?" end)
                    System.LogAlways(string.format("[KCD2-MP] HUMAN NPC: %s (class=%s)", ename, eclass))
                    humanCount = humanCount + 1

                    -- Try to get character filename
                    local cdfPath = nil
                    pcall(function()
                        local ch = ent:GetCharacter(0)
                        if ch then
                            cdfPath = ch:GetFilePath()
                            System.LogAlways("[KCD2-MP]   GetCharacter(0):GetFilePath() = " .. tostring(cdfPath))
                        end
                    end)
                    pcall(function()
                        local fn = ent:GetCharacterFileName(0)
                        System.LogAlways("[KCD2-MP]   GetCharacterFileName(0) = " .. tostring(fn))
                        if fn and not cdfPath then cdfPath = fn end
                    end)
                    -- Check Properties for model path
                    pcall(function()
                        if ent.Properties then
                            for k, v in pairs(ent.Properties) do
                                if type(v) == "string" and #v > 3 then
                                    if k:lower():find("model") or k:lower():find("cdf") or
                                       k:lower():find("file") or k:lower():find("char") then
                                        System.LogAlways("[KCD2-MP]   Props." .. k .. " = " .. v)
                                        if not cdfPath then cdfPath = v end
                                    end
                                end
                            end
                        end
                    end)

                    -- Probe animations on this NPC
                    local animCandidates = {
                        "idle", "run", "walk", "sprint", "jog",
                        "Idle", "Run", "Walk", "Sprint",
                        "run_loop", "walk_loop", "idle_loop", "sprint_loop",
                        "run_fwd", "walk_fwd", "run01", "walk01", "idle01",
                        "mm_run_fwd", "mm_walk_fwd", "mm_idle",
                        "loco_run", "loco_walk", "loco_idle",
                        "act_run", "act_walk", "act_idle",
                    }
                    for _, aname in ipairs(animCandidates) do
                        local len = 0
                        pcall(function() len = ent:GetAnimationLength(0, aname) or 0 end)
                        if len > 0 then
                            System.LogAlways(string.format("[KCD2-MP]   ANIM HIT '%s' len=%.3f", aname, len))
                        end
                    end

                    -- If we found a CDF, try loading it onto ghost
                    if cdfPath and cdfPath ~= "" then
                        System.LogAlways("[KCD2-MP]   Loading CDF onto ghost: " .. cdfPath)
                        local loadOk, loadErr = pcall(function()
                            ghost.entity:LoadCharacter(0, cdfPath)
                        end)
                        System.LogAlways("[KCD2-MP]   LoadCharacter result: " .. tostring(loadOk) .. " " .. tostring(loadErr))

                        if loadOk then
                            -- Now probe ghost again
                            System.LogAlways("[KCD2-MP]   Re-probing ghost after CDF load:")
                            for _, aname in ipairs(animCandidates) do
                                local len = 0
                                pcall(function() len = ghost.entity:GetAnimationLength(0, aname) or 0 end)
                                if len > 0 then
                                    System.LogAlways(string.format("[KCD2-MP]   GHOST HIT '%s' len=%.3f", aname, len))
                                end
                            end
                        end
                    end

                    if humanCount >= 3 then break end
                end
            end
        end
        System.LogAlways("[KCD2-MP] Found " .. humanCount .. " human NPCs")
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] Error: " .. tostring(err))
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Test AI.SetForcedNavigation on ghost (try to drive locomotion animation via AI)
function KCD2MP_TestAINav()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost then
        System.LogAlways("[KCD2-MP] TestAINav: no ghost")
        return
    end
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] TestAINav: sending velocity {1,0,0} to entityId=" .. tostring(eid))

    -- Try passing velocity vector (tell AI it's moving forward)
    local ok1, e1 = pcall(function() AI.SetForcedNavigation(eid, {x=3, y=0, z=0}) end)
    System.LogAlways("[KCD2-MP]   SetForcedNavigation: " .. tostring(ok1) .. " " .. tostring(e1))

    local ok2, e2 = pcall(function() AI.SetSpeed(eid, 3) end)
    System.LogAlways("[KCD2-MP]   SetSpeed(3): " .. tostring(ok2) .. " " .. tostring(e2))

    local ok3, e3 = pcall(function() AI.Signal(0, 1, "OnMoveForward", eid) end)
    System.LogAlways("[KCD2-MP]   Signal OnMoveForward: " .. tostring(ok3) .. " " .. tostring(e3))
end

-- Deep scan: recursively list up to 3 levels, log files with .caf/.adb
function KCD2MP_ScanAnims()
    System.LogAlways("[KCD2-MP] === DEEP ANIM SCAN ===")

    local function scanDir(path, depth)
        local entries = nil
        pcall(function() entries = System.ScanDirectory(path) end)
        if not entries then return end
        for _, name in ipairs(entries) do
            local full = path .. "/" .. name
            -- Log CAF/ADB files immediately
            if name:find("%.caf$") or name:find("%.CAF$") then
                System.LogAlways("[KCD2-MP] CAF: " .. full)
            elseif name:find("%.adb$") or name:find("%.ADB$") then
                System.LogAlways("[KCD2-MP] ADB: " .. full)
            elseif depth < 3 then
                -- Recurse into subdirectory
                scanDir(full, depth + 1)
            end
        end
    end

    -- Scan humans animation tree
    scanDir("Animations/humans", 1)
    scanDir("Animations/assets", 1)
    scanDir("Animations/Mannequin/adb", 1)

    System.LogAlways("[KCD2-MP] === END DEEP SCAN ===")
end

-- Try AI.SetForcedNavigation to drive locomotion animation
-- dirX, dirY = movement direction (unit vector), speed = 0 to stop
function KCD2MP_SetGhostMovement(id, dirX, dirY, speed)
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then return end

    local eid = ghost.entityId
    if speed > 0 then
        -- Tell AI the entity is moving in this direction at this speed
        pcall(function() AI.SetSpeed(eid, speed) end)
        pcall(function()
            AI.SetForcedNavigation(eid, {x=dirX, y=dirY, z=0})
        end)
    else
        pcall(function() AI.SetForcedNavigation(eid, {x=0, y=0, z=0}) end)
        pcall(function() AI.SetSpeed(eid, 0) end)
    end
end

-- Read Mannequin ADB via CryEngine XML loader (reads from PAK)
function KCD2MP_ReadADB()
    System.LogAlways("[KCD2-MP] === READ ADB ===")

    local adbPaths = {
        "Animations/Mannequin/ADB/kcd_male_database.adb",
        "Animations/Mannequin/adb/kcd_male_database.adb",
        "animations/mannequin/adb/kcd_male_database.adb",
    }

    -- Try CryEngine XML loader (reads files from PAK virtual filesystem)
    for _, path in ipairs(adbPaths) do
        local node = nil
        local ok, err = pcall(function()
            node = System.LoadXMLFile(path)
        end)
        System.LogAlways("[KCD2-MP] LoadXMLFile(" .. path .. "): ok=" .. tostring(ok) .. " node=" .. tostring(node) .. " err=" .. tostring(err))
        if ok and node then
            System.LogAlways("[KCD2-MP] XML loaded! Walking nodes...")
            -- Walk XML tree looking for Fragment names
            local function walkNode(n, depth)
                if depth > 4 then return end
                local tag = ""
                local name = ""
                pcall(function() tag = n:getTag() end)
                pcall(function() name = n:getAttr("name") end)
                if name and name ~= "" then
                    System.LogAlways("[KCD2-MP] " .. string.rep("  ", depth) .. tag .. " name='" .. name .. "'")
                end
                local count = 0
                pcall(function() count = n:getChildCount() end)
                for i = 0, count - 1 do
                    local child = nil
                    pcall(function() child = n:getChild(i) end)
                    if child then walkNode(child, depth + 1) end
                end
            end
            walkNode(node, 0)
            System.LogAlways("[KCD2-MP] === END ===")
            return
        end
    end

    -- Fallback: ScanDirectory
    System.LogAlways("[KCD2-MP] LoadXMLFile failed for all paths. Scanning directories...")
    local dirs = {
        "Animations/Mannequin/ADB",
        "Animations/Mannequin/adb",
        "Animations/Mannequin/adb/adb",
    }
    for _, d in ipairs(dirs) do
        local entries = nil
        pcall(function() entries = System.ScanDirectory(d) end)
        if entries and #entries > 0 then
            System.LogAlways("[KCD2-MP] " .. d .. " -> " .. #entries .. " entries:")
            for i, e in ipairs(entries) do
                System.LogAlways("[KCD2-MP]   " .. e)
                if i > 30 then break end
            end
        else
            System.LogAlways("[KCD2-MP] " .. d .. " -> empty/nil")
        end
    end

    System.LogAlways("[KCD2-MP] === END ===")
end

-- Probe Mannequin animation tags on ghost via AI.SetAnimationTag
-- Tags drive which Mannequin fragments play (including locomotion)
function KCD2MP_ProbeAnimTags()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost then
        System.LogAlways("[KCD2-MP] ProbeAnimTags: no ghost")
        return
    end
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] === PROBE ANIM TAGS ===")
    System.LogAlways("[KCD2-MP] entityId=" .. tostring(eid))

    -- Common Mannequin tag names for locomotion
    local tags = {
        "Moving", "moving", "Run", "run", "Walk", "walk",
        "Sprint", "sprint", "Locomotion", "locomotion",
        "Alert", "alert", "Relaxed", "relaxed",
        "InCombat", "Combat", "Idle", "idle",
        "Forward", "forward", "MoveForward",
        "Jogging", "Running", "Walking",
    }

    System.LogAlways("[KCD2-MP] Trying AI.SetAnimationTag:")
    for _, tag in ipairs(tags) do
        local ok, err = pcall(function()
            AI.SetAnimationTag(eid, tag)
        end)
        -- Log only errors or interesting results
        if not ok then
            System.LogAlways("[KCD2-MP]   tag='" .. tag .. "' ERROR: " .. tostring(err))
        else
            System.LogAlways("[KCD2-MP]   tag='" .. tag .. "' OK")
        end
    end

    -- Also try clearing tags
    pcall(function() AI.SetAnimationTag(eid, "") end)

    System.LogAlways("[KCD2-MP] === END ===")
end

-- Test the real animation names from ADB analysis
function KCD2MP_TestRunAnim()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] TestRunAnim: no ghost")
        return
    end
    local ent = ghost.entity
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] === TEST REAL ANIM NAMES ===")

    local names = {
        "3d_relaxed_run_turn_strafe",
        "3d_relaxed_walk_turn_strafe",
        "relaxed_idle_both",
        "3d_armored_walk_turn_strafe",
        "3d_wounded_run_turn_strafe",
    }
    for _, name in ipairs(names) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        local started = false
        pcall(function() started = ent:StartAnimation(0, name) end)
        System.LogAlways(string.format("[KCD2-MP] '%s': len=%.3f started=%s",
            name, len, tostring(started)))
    end

    -- Also try AI tag "run"
    System.LogAlways("[KCD2-MP] Setting AI tag 'run'...")
    pcall(function() AI.SetAnimationTag(eid, "run") end)
    pcall(function() AI.SetSpeed(eid, 4) end)

    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Terrain Debug =====

function KCD2MP_TerrainCheck()
    if not player then System.LogAlways("[KCD2-MP] TerrainCheck: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    local ok, gz = pcall(function() return Terrain.GetElevation(pos.x, pos.y) end)
    System.LogAlways(string.format("[KCD2-MP] TerrainCheck: player pos=%.2f,%.2f,%.2f | Terrain.GetElevation=ok=%s gz=%s",
        pos.x, pos.y, pos.z, tostring(ok), tostring(gz)))

    -- Check ghost position vs terrain
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            local gpos = nil
            pcall(function() gpos = ghost.entity:GetWorldPos() end)
            local tgz = nil
            if gpos then
                pcall(function() tgz = Terrain.GetElevation(gpos.x, gpos.y) end)
                System.LogAlways(string.format("[KCD2-MP] Ghost '%s': entity z=%.2f | terrain z=%s | diff=%s",
                    id, gpos.z, tostring(tgz), tgz and string.format("%.2f", gpos.z - tgz) or "?"))
            end
        end
    end
end

-- ===== Stance Probe =====

function KCD2MP_ProbeStance()
    if not player then System.LogAlways("[KCD2-MP] ProbeStance: no player"); return end
    System.LogAlways("[KCD2-MP] === STANCE PROBE ===")
    local s1, s2, s3 = nil, nil, nil
    local ok1 = pcall(function() s1 = player:GetStance() end)
    System.LogAlways("[KCD2-MP] GetStance() ok=" .. tostring(ok1) .. " val=" .. tostring(s1))
    local ok2 = pcall(function()
        if player.actor then
            s2 = player.actor.bSneaking
            System.LogAlways("[KCD2-MP] actor.bSneaking=" .. tostring(s2))
        else
            System.LogAlways("[KCD2-MP] actor=nil")
        end
    end)
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
    System.AddCCommand("mp_probe_anims",   "KCD2MP_ProbeAnims()",    "Probe anim names on ghost (GetAnimationLength)")
    System.AddCCommand("mp_copy_npc",     "KCD2MP_CopyNPCModel()",  "Find human NPC, copy CDF to ghost, probe anims")
    System.AddCCommand("mp_scan_anims",   "KCD2MP_ScanAnims()",     "Scan animation directories")
    System.AddCCommand("mp_test_ai_nav",  "KCD2MP_TestAINav()",     "Test AI.SetForcedNavigation on ghost")
    System.AddCCommand("mp_read_adb",     "KCD2MP_ReadADB()",       "Read kcd_male_database.adb via CryEngine XML loader")
    System.AddCCommand("mp_probe_tags",   "KCD2MP_ProbeAnimTags()", "Probe Mannequin animation tags on ghost")
    System.AddCCommand("mp_test_run",     "KCD2MP_TestRunAnim()",   "Test 3d_relaxed_run_turn_strafe on ghost")
    System.AddCCommand("mp_terrain",      "KCD2MP_TerrainCheck()",  "Check player/ghost vs terrain height")
    System.AddCCommand("mp_probe_stance", "KCD2MP_ProbeStance()",   "Log player stance value (for crouch detection calibration)")
    System.AddCCommand("mp_sneak_on",     "KCD2MP.playerSneaking=true;System.LogAlways('[KCD2-MP] SNEAK ON (manual)')",  "Force ghost into sneak mode")
    System.AddCCommand("mp_sneak_off",    "KCD2MP.playerSneaking=false;System.LogAlways('[KCD2-MP] SNEAK OFF (manual)')", "Force ghost out of sneak mode")
    System.LogAlways("[KCD2-MP] Commands OK")
end)
if not ok then
    System.LogAlways("[KCD2-MP] Command error: " .. tostring(err))
end

-- ===== Sneak action handler (shared, installed by both hook paths) =====

-- KCD2 sneak key = C, fires "chat_init_with_focus" as TOGGLE (press=toggle on/off).
-- Activations come as STRINGS "press"/"release"/"hold" (not integers).
local SNEAK_TOGGLE_ACTIONS = {
    -- Confirmed KCD2: C key triggers these
    chat_init_with_focus = true,
    -- Fallback: other common names in case C is rebound
    sneak_toggle=true, toggle_sneak=true,
}
-- Hold-style sneak: pressed=on, released=off (other games/bindings)
local SNEAK_HOLD_ACTIONS = {
    sneak=true, stealth=true, crouch=true,
    wh_sneak=true, wh_stealth=true,
    action_sneak=true, action_stealth=true,
    sneaking=true, stealth_mode=true,
}

-- Analog axis actions - ignore completely, they flood the log
local AXIS_ACTIONS = {
    combat_zone_mouse_x=true, combat_zone_mouse_y=true,
    mouse_x=true, mouse_y=true, look_lx=true, look_ly=true,
    move_lx=true, move_ly=true,
}

local function handleAction(action, activation, value)
    if AXIS_ACTIONS[action] then return end
    if KCD2MP.logActions then
        mp_log(string.format("ACT '%s' a=%s", tostring(action), tostring(activation)))
    end

    -- Toggle-style: each press of C flips sneak on/off
    if SNEAK_TOGGLE_ACTIONS[action] and activation == "press" then
        KCD2MP.playerSneaking = not KCD2MP.playerSneaking
        mp_log("SNEAK=" .. tostring(KCD2MP.playerSneaking) .. " toggle via '" .. action .. "'")
        return
    end

    -- Hold-style: press = on, release = off
    if SNEAK_HOLD_ACTIONS[action] then
        local pressed = (activation == "press" or activation == "hold"
                         or activation == 1 or activation == 2)
        if pressed ~= KCD2MP.playerSneaking then
            KCD2MP.playerSneaking = pressed
            mp_log("SNEAK=" .. tostring(pressed) .. " hold via '" .. action .. "'")
            KCD2MP.logActions = false
        end
    end
end

-- ===== Player hook =====

local ok2, err2 = pcall(function()
    if not (Player and Player.Client) then return end

    -- OnInit: fires when save is loaded
    local origOnInit = Player.Client.OnInit
    Player.Client.OnInit = function(self)
        if origOnInit then origOnInit(self) end
        System.LogAlways("[KCD2-MP] Player loaded!")
        KCD2MP_GetPos()

        -- Re-install OnAction hooks here (after player fully initialized).
        -- Player.Client.OnAction may be reset during game load; re-hooking in OnInit
        -- ensures our handler is always active.
        local origCA = Player.Client.OnAction
        Player.Client.OnAction = function(s, action, activation, value)
            if origCA then pcall(origCA, s, action, activation, value) end
            handleAction(action, activation, value)
        end
        System.LogAlways("[KCD2-MP] Client.OnAction hooked")
    end

    -- Also hook at mod-init time (catches actions before first save load)
    local origCA0 = Player.Client.OnAction
    Player.Client.OnAction = function(self, action, activation, value)
        if origCA0 then pcall(origCA0, self, action, activation, value) end
        handleAction(action, activation, value)
    end

    -- Also try Player.OnAction (non-Client path, some CryEngine versions use this)
    local origPA = Player.OnAction
    Player.OnAction = function(self, action, activation, value)
        if origPA then pcall(origPA, self, action, activation, value) end
        handleAction(action, activation, value)
    end

    System.LogAlways("[KCD2-MP] Player hooks OK (OnInit + OnAction x2)")
end)
if not ok2 then
    System.LogAlways("[KCD2-MP] Hook error: " .. tostring(err2))
end



System.AddCCommand("mp_spawn_armor", [[
    if not player then System.LogAlways("[MP] no player"); return end
    local pos = player:GetWorldPos()
    local npc = System.SpawnEntity({class="NPC", name="TestNPC", position=pos, scale={x=1,y=1,z=1}})
    if not npc then System.LogAlways("[MP] SpawnEntity failed"); return end
    pcall(function() npc.Properties.factionName = "outlaw" end)
    -- Step 1: add items to inventory via ItemManager (same pattern as player.lua)
    local GAMBESON = "00b7ed62-a7bd-4269-acfa-8d852366579b"
    local CUIRASS  = "10ff6d35-8c14-4871-8656-bdc3476d8b12"
    local ok1, e1 = pcall(function()
        local g = ItemManager.CreateItem(GAMBESON, 1, 1)
        npc.inventory:AddItem(g)
        local c = ItemManager.CreateItem(CUIRASS, 1, 1)
        npc.inventory:AddItem(c)
    end)
    System.LogAlways("[MP] AddItems: ok=" .. tostring(ok1) .. " " .. tostring(e1))
    -- Step 2: visually equip via ClothingPreset GUID (defined in clothing_preset__kdcmp.xml)
    local ok2, e2 = pcall(function()
        npc.actor:EquipClothingPreset("dc000001-0000-0000-0000-000000000000")
    end)
    System.LogAlways("[MP] EquipClothingPreset: ok=" .. tostring(ok2) .. " " .. tostring(e2))
]], "Spawn NPC with cuirass")