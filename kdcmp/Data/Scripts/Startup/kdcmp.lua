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
        Properties = {
            sFactionName = "Neutral",
        },
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
        -- Animation state
        animState = "none",   -- "none", "idle", "run"
        animTimer = 0,        -- ticks since last StartAnimation call
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

    -- Try to disable AI so it doesn't fight our animation calls
    pcall(function() entity:SetAIEnabled(false) end)
    pcall(function() entity:EnableAI(false) end)

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

            -- Terrain snap: prevent ghost from going underground
            -- Terrain.GetElevation(x, y) returns terrain Z at horizontal position (x, y)
            local sz = z
            pcall(function()
                local gz = Terrain.GetElevation(x, y)
                if gz and sz < gz then
                    sz = gz
                    istate.cz = gz  -- update lerp source so next frame continues from snapped z
                end
            end)

            -- Apply to entity
            local ok, err = pcall(function()
                ghost.entity:SetWorldPos({x=x, y=y, z=sz})
                ghost.entity:SetWorldAngles({x=0, y=0, z=r})
            end)
            if not ok then
                System.LogAlways("[KCD2-MP] InterpTick err on '" .. id .. "': " .. tostring(err))
                ghost.entity = nil
            else
                -- === Animation ===
                -- Speed from velocity (horizontal only, ignore vertical)
                local speed = math.sqrt(istate.vx * istate.vx + istate.vy * istate.vy)
                -- Animation state machine based on speed
                -- Thresholds from ADB analysis (KCD2 walk ~1.5 m/s, run ~4 m/s)
                local wantAnim, wantTag
                if speed > 2.5 then
                    wantAnim = "3d_relaxed_run_turn_strafe"
                    wantTag  = "run"
                elseif speed > 0.3 then
                    wantAnim = "3d_relaxed_walk_turn_strafe"
                    wantTag  = "walk"
                else
                    wantAnim = "relaxed_idle_both"
                    wantTag  = ""
                end

                istate.animTimer = (istate.animTimer or 0) + 1
                if wantAnim ~= istate.animState or istate.animTimer >= 20 then
                    istate.animState = wantAnim
                    istate.animTimer = 0
                    -- StartAnimation: works for walk/idle (started=true)
                    -- For run blendspace (started=false) AI.SetAnimationTag takes over
                    pcall(function() ghost.entity:StartAnimation(0, wantAnim) end)
                    -- AI tag drives Mannequin fragment selection
                    pcall(function() AI.SetAnimationTag(ghost.entityId, wantTag) end)
                    pcall(function() AI.SetSpeed(ghost.entityId, speed) end)
                end
                istate.isMoving = (speed > 0.3)
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
