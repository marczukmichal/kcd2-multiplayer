param(
    [string]$Port = "1404"
)

$b = "http://localhost:$Port"

function Eval($lua) {
    $e = [uri]::EscapeDataString("#$lua")
    try { iwr "$b/api/System/Console/ExecuteString?command=$e" -UseBasicParsing | Out-Null } catch {}
}

function ReadCvar($name) {
    try {
        $xml = (iwr "$b/api/System/Console/GetCvarValue?name=$name" -UseBasicParsing).Content
        if ($xml -match '>([^<]*)<') { return $Matches[1].Trim() }
    } catch {}
    return "(error)"
}

function Test($label, $lua) {
    Eval "System.SetCVar(`"sv_servername`",$lua)"
    $val = ReadCvar "sv_servername"
    Write-Host ("{0,-22} = {1}" -f $label, $val)
}

Write-Host ""
Write-Host "=== RIDING DETECTION PROBE (port $Port) ===" -ForegroundColor Cyan
Write-Host "Jedz na koniu i sprawdz wyniki ponizej:"
Write-Host ""

# --- Terrain height (przez mod-context funkcje, nie inline ExecuteString) ---
Write-Host "-- Terrain height (przez mod funkcje) --" -ForegroundColor Yellow

# Startuj interp tick zeby KCD2MP.isRiding bylo aktualizowane
Eval 'KCD2MP_StartInterp()'
Start-Sleep -Milliseconds 500  # czekaj na kilka tickow

Test "KCD2MP.isRiding"    'tostring(KCD2MP and KCD2MP.isRiding)'

# Wywolaj mod-context funkcje diagnostyczna (ma dostep do Terrain, player itd)
Eval 'KCD2MP_DiagRideDetect()'
$val = ReadCvar "sv_servername"
Write-Host ("{0,-22} = {1}" -f "DiagRideDetect", $val)

Write-Host ""
Write-Host "-- API methods (ExecuteString context) --" -ForegroundColor Yellow
Test "soul.bRiding"       'tostring(player.soul and player.soul.bRiding)'
Test "human:IsRiding()"   'tostring(player.human and player.human:IsRiding())'
Test "GetLinkedParent()"  'tostring(player:GetLinkedParent())'

Write-Host ""
