import * as http from "http";

// Game debug API
const DEBUG_API = "http://localhost:1403";
const TICK_MS = 200;

interface PlayerState {
  x: number;
  y: number;
  z: number;
  rotZ: number;
  timestamp: number;
}

let localPlayer: PlayerState | null = null;
let apiAvailable = false;
let modLoaded = false;
let ghostSpawned = false;

// ===== Debug API Communication =====

function fetchAPI(path: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const url = `${DEBUG_API}${path}`;
    http
      .get(url, { timeout: 3000 }, (res) => {
        let data = "";
        res.on("data", (chunk: string) => (data += chunk));
        res.on("end", () => resolve(data));
      })
      .on("error", reject)
      .on("timeout", function () {
        this.destroy();
        reject(new Error("timeout"));
      });
  });
}

// Execute a console command (CVar or Lua with # prefix)
async function execConsole(cmd: string): Promise<string> {
  return fetchAPI(
    `/api/System/Console/ExecuteString?command=${encodeURIComponent(cmd)}`,
  );
}

// Execute Lua code in game
async function execLua(lua: string): Promise<string> {
  return execConsole(`#${lua}`);
}

// Read a CVar value
async function getCvar(name: string): Promise<string> {
  const xml = await fetchAPI(
    `/api/System/Console/GetCvarValue?name=${encodeURIComponent(name)}`,
  );
  const match = xml.match(/>([^<]*)</);
  return match ? match[1] : "";
}

// Read Lua expression result via CVar trick
async function evalLua(expr: string): Promise<string> {
  await execLua(`System.SetCVar("sv_servername",tostring(${expr}))`);
  return getCvar("sv_servername");
}

// ===== Player Position + Rotation =====

async function readPlayerFromAPI(): Promise<PlayerState | null> {
  try {
    // Read position from REST API
    const xml = await fetchAPI("/api/rpg/SoulList/PlayerSoul?depth=1");
    const posMatch = xml.match(/Position="([^"]+)"/);
    if (!posMatch) return null;

    const parts = posMatch[1].split(",");
    if (parts.length < 3) return null;

    // Read rotation via Lua (player:GetWorldAngles().z)
    let rotZ = 0;
    try {
      const rotStr = await evalLua("player:GetWorldAngles().z");
      const parsed = parseFloat(rotStr);
      if (!isNaN(parsed)) rotZ = parsed;
    } catch {
      // rotation read failed, use 0
    }

    return {
      x: parseFloat(parts[0]),
      y: parseFloat(parts[1]),
      z: parseFloat(parts[2]),
      rotZ,
      timestamp: Date.now(),
    };
  } catch {
    return null;
  }
}

// ===== Ghost NPC Management =====

async function updateGhost(playerPos: PlayerState) {
  // Place ghost 3 meters offset from player (for testing)
  const gx = (playerPos.x + 3).toFixed(2);
  const gy = playerPos.y.toFixed(2);
  const gz = playerPos.z.toFixed(2);
  const rot = playerPos.rotZ.toFixed(4);

  if (modLoaded) {
    try {
      await execLua(
        `KCD2MP_UpdateGhost("test_ghost",${gx},${gy},${gz},${rot})`,
      );
      if (!ghostSpawned) {
        console.log(`[server] Ghost spawned via mod: ${gx}, ${gy}, ${gz}`);
        ghostSpawned = true;
      }
    } catch {
      // silent
    }
  } else {
    try {
      const lua = ghostSpawned
        ? `local e=System.GetEntityByName("mp_ghost"); if e then e:SetWorldPos({x=${gx},y=${gy},z=${gz}}); e:SetWorldAngles({x=0,y=0,z=${rot}}) end`
        : `local e=System.SpawnEntity({class="NPC",name="mp_ghost",position={x=${gx},y=${gy},z=${gz}}}); if e then KCD2MP_GhostId=e.id end`;
      await execLua(lua);
      if (!ghostSpawned) {
        console.log(`[server] Ghost spawned (no mod): ${gx}, ${gy}, ${gz}`);
        ghostSpawned = true;
      }
    } catch {
      // silent
    }
  }
}

// ===== Probe & Health Check =====

async function probeAPI(): Promise<boolean> {
  try {
    // Check if game is running (not main menu)
    const calendarXml = await fetchAPI("/api/rpg/Calendar?depth=1");
    const timeMatch = calendarXml.match(/GameTime="([^"]+)"/);
    const gameTime = timeMatch ? parseFloat(timeMatch[1]) : 0;

    if (gameTime === 0) {
      console.log(
        "[server] Game on main menu (GameTime=0). Waiting for save...",
      );
      return false;
    }

    // Read player info
    const playerXml = await fetchAPI("/api/rpg/SoulList/PlayerSoul?depth=1");
    const nameMatch = playerXml.match(/Name="([^"]+)"/);
    const posMatch = playerXml.match(/Position="([^"]+)"/);
    console.log(
      `[server] Game running! Player: ${nameMatch?.[1] ?? "?"} at ${posMatch?.[1] ?? "?"}`,
    );

    // Check if mod is loaded
    const modType = await evalLua("type(KCD2MP)");
    modLoaded = modType === "table";
    console.log(
      `[server] Mod loaded: ${modLoaded ? "YES" : "NO (using fallback)"}`,
    );

    return true;
  } catch (e: any) {
    console.log(`[server] API probe failed: ${e.message}`);
    return false;
  }
}

// ===== Main Loop =====

function stateChanged(a: PlayerState | null, b: PlayerState): boolean {
  if (!a) return true;
  return (
    Math.abs(a.x - b.x) > 0.05 ||
    Math.abs(a.y - b.y) > 0.05 ||
    Math.abs(a.z - b.z) > 0.05 ||
    Math.abs(a.rotZ - b.rotZ) > 0.02
  );
}

let probeInterval = 0;
async function tick() {
  if (!apiAvailable) {
    probeInterval++;
    // Probe every 3 seconds (not every tick)
    if (probeInterval % 15 === 1) {
      apiAvailable = await probeAPI();
      if (apiAvailable) {
        console.log("");
        console.log("[server] === READY ===");
        console.log("");
      }
    }
    return;
  }

  try {
    const pos = await readPlayerFromAPI();
    if (pos && stateChanged(localPlayer, pos)) {
      localPlayer = pos;
      console.log(
        `[player] x=${pos.x.toFixed(1)} y=${pos.y.toFixed(1)} z=${pos.z.toFixed(1)} rot=${pos.rotZ.toFixed(2)}`,
      );

      await updateGhost(pos);
    }
  } catch {
    // API might have disconnected (game reload, etc.)
    console.log("[server] API connection lost, re-probing...");
    apiAvailable = false;
    ghostSpawned = false;
    probeInterval = 0;
  }
}

// ===== Start =====

console.log("[server] KCD2 Multiplayer Server starting...");
console.log("[server] Debug API:", DEBUG_API);
console.log("[server] Tick interval:", TICK_MS, "ms");
console.log("");

setInterval(tick, TICK_MS);
