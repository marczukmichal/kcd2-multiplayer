#!/usr/bin/env pwsh
# Local test script - no second PC needed.
# Usage: powershell.exe -File test_local.ps1

$base = "http://localhost:1403"

function Lua($code) {
    $enc = [Uri]::EscapeDataString("#$code")
    $resp = cmd.exe /c curl.exe -s "$base/api/System/Console/ExecuteString?command=$enc" 2>$null
    return $resp
}

function ReadCvar($name) {
    $resp = cmd.exe /c curl.exe -s "$base/api/System/Console/GetCvarValue?name=$name" 2>$null
    if ($resp -match '>([^<]*)<') { return $Matches[1] }
    return $resp
}

function EvalLua($code) {
    Lua("System.SetCVar('sv_servername',(function() $code end)())") | Out-Null
    Start-Sleep -Milliseconds 200
    return ReadCvar "sv_servername"
}

function PopLogs($max = 30) {
    $got = 0
    for ($i = 0; $i -lt $max; $i++) {
        $msg = EvalLua "return KCD2MP_PopLog()"
        if ([string]::IsNullOrEmpty($msg) -or $msg -match "xsi:") { break }
        Write-Host "  LOG: $msg"
        $got++
    }
    if ($got -eq 0) { Write-Host "  (no logs)" }
}

# ---- Check mod is loaded ----
Write-Host "=== Checking mod ===" -ForegroundColor Cyan
$modOk = EvalLua "return KCD2MP and 'OK' or 'MISSING'"
Write-Host "Mod: $modOk"
if ($modOk -ne "OK") {
    Write-Host "ERROR: Mod not loaded! Check kcd.log" -ForegroundColor Red
    exit 1
}

# ---- Player position ----
Write-Host ""
Write-Host "=== Player position ===" -ForegroundColor Cyan
$posRaw = EvalLua "if player then local p=player:GetWorldPos(); return string.format('%.1f,%.1f,%.1f',p.x,p.y,p.z) else return 'no player' end"
Write-Host "Position: $posRaw"

# ---- Test 1: Name setting ----
Write-Host ""
Write-Host "=== TEST 1: Ghost spawn + name ===" -ForegroundColor Yellow
Lua("KCD2MP_SpawnTest()") | Out-Null
Write-Host "Ghost spawned (id='test_ghost'). Waiting 2s for 1.5s name timer..."
Start-Sleep -Seconds 2
PopLogs

$soulName = EvalLua "local g=KCD2MP.ghosts['test_ghost']; return g and g.entity and g.entity.soul and tostring(g.entity.soul.name) or 'nil'"
Write-Host "soul.name: '$soulName'"
if ($soulName -eq "Playertest_ghost") {
    Write-Host "  NAME OK: fallback name set correctly" -ForegroundColor Green
} else {
    Write-Host "  NAME UNEXPECTED: got '$soulName'" -ForegroundColor Red
}

# ---- Test 2: Riding simulation (proper full flow via UpdateGhost) ----
Write-Host ""
Write-Host "=== TEST 2: Riding simulation (UpdateGhost with isRiding=true) ===" -ForegroundColor Yellow
Write-Host "Simulating incoming packet: isRiding=true for 'rider1'..."
# This mirrors exactly what the C# client does: KCD2MP_UpdateGhost(id, x,y,z,rot, isRiding)
Lua("local p=player:GetWorldPos(); KCD2MP_UpdateGhost('rider1', p.x+4, p.y, p.z, 0, true)") | Out-Null
Write-Host "Waiting 2s (horse spawn 400ms + name timer 1500ms)..."
Start-Sleep -Seconds 2
PopLogs

# Verify state
$isRiding     = EvalLua "local g=KCD2MP.ghosts['rider1']; return g and g.istate and tostring(g.istate.isRiding) or 'nil'"
$rideFallback = EvalLua "local g=KCD2MP.ghosts['rider1']; return g and g.istate and tostring(g.istate.ridingFallback) or 'nil'"
$horseOk      = EvalLua "return KCD2MP.horseGhosts['rider1'] and 'YES' or 'NO'"
$npcName      = EvalLua "local g=KCD2MP.ghosts['rider1']; return g and g.entity and g.entity.soul and tostring(g.entity.soul.name) or 'nil'"

Write-Host ""
Write-Host "State after riding start:"
Write-Host "  istate.isRiding    = $isRiding     (should be true)"
Write-Host "  istate.ridingFallback = $rideFallback  (true = engine mount failed, using +1.1m offset)"
Write-Host "  horse ghost exists = $horseOk      (should be YES)"
Write-Host "  NPC soul.name      = $npcName"

if ($isRiding -eq "true" -and $horseOk -eq "YES") {
    Write-Host "  RIDING OK: NPC interp tick should be positioning NPC at horse+1.1m" -ForegroundColor Green
    if ($rideFallback -eq "true") {
        Write-Host "  FALLBACK ACTIVE: NPC offset +1.1m above horse (engine mount APIs unavailable)" -ForegroundColor Yellow
    } else {
        Write-Host "  ENGINE MOUNT: NPC should be attached to horse by engine" -ForegroundColor Green
    }
} else {
    Write-Host "  RIDING FAILED (check logs above)" -ForegroundColor Red
}

# Probe riding animations on the riding ghost
Write-Host ""
Write-Host "--- Probing riding animations (get on your horse now if you want player anim too) ---" -ForegroundColor Cyan
Lua("KCD2MP_ProbeRidingAnims()") | Out-Null
Start-Sleep -Milliseconds 3000
# Read from kcd.log via REST (LogAlways goes to file, not debug queue)
$rideIdleVal  = EvalLua "return tostring(KCD2MP._ridingIdleAnim)"
$rideGallopVal = EvalLua "return tostring(KCD2MP._ridingGallopAnim)"
Write-Host "Cached ride idle anim  : $rideIdleVal"
Write-Host "Cached ride gallop anim: $rideGallopVal"
Write-Host "Check kcd.log for 'RIDING HIT' lines to see which animations exist"

# ---- Test 3: Dismount ----
Write-Host ""
Write-Host "=== TEST 3: Dismount (isRiding=false) ===" -ForegroundColor Yellow
Lua("local p=player:GetWorldPos(); KCD2MP_UpdateGhost('rider1', p.x+4, p.y, p.z, 0, false)") | Out-Null
Start-Sleep -Milliseconds 500
PopLogs 10

$isRidingAfter = EvalLua "local g=KCD2MP.ghosts['rider1']; return g and g.istate and tostring(g.istate.isRiding) or 'nil'"
$horseAfter    = EvalLua "return KCD2MP.horseGhosts['rider1'] and 'STILL EXISTS' or 'REMOVED'"
Write-Host "After dismount: isRiding=$isRidingAfter  horse=$horseAfter"
if ($isRidingAfter -eq "false" -and $horseAfter -eq "REMOVED") {
    Write-Host "  DISMOUNT OK" -ForegroundColor Green
} else {
    Write-Host "  DISMOUNT UNEXPECTED" -ForegroundColor Red
}

# ---- Cleanup ----
Write-Host ""
Write-Host "=== Cleanup ===" -ForegroundColor Cyan
Write-Host "Press ENTER to remove all ghosts, or Ctrl+C to keep for inspection..."
Read-Host | Out-Null
Lua("KCD2MP_RemoveAllGhosts()") | Out-Null
Write-Host "Done."
