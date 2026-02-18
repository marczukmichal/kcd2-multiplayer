import * as http from "http";

// ===== CONFIG =====

const TICK_MS = 200;

interface GameClient {
  name: string;
  api: string;
  ready: boolean;
  modLoaded: boolean;
  ghostSpawned: boolean;
  lastPos: PlayerState | null;
  probeCount: number;
}

interface PlayerState {
  x: number;
  y: number;
  z: number;
  rotZ: number;
}

// Two game clients on LAN
const clients: GameClient[] = [
  {
    name: "PC1",
    api: "http://192.168.18.33:1404",
    ready: false,
    modLoaded: false,
    ghostSpawned: false,
    lastPos: null,
    probeCount: 0,
  },
  {
    name: "PC2",
    api: "http://192.168.18.29:1404",
    ready: false,
    modLoaded: false,
    ghostSpawned: false,
    lastPos: null,
    probeCount: 0,
  },
];

// ===== API Helpers =====

function fetchAPI(baseUrl: string, path: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const url = `${baseUrl}${path}`;
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

async function execLua(baseUrl: string, lua: string): Promise<string> {
  const cmd = `#${lua}`;
  return fetchAPI(
    baseUrl,
    `/api/System/Console/ExecuteString?command=${encodeURIComponent(cmd)}`,
  );
}

async function getCvar(baseUrl: string, name: string): Promise<string> {
  const xml = await fetchAPI(
    baseUrl,
    `/api/System/Console/GetCvarValue?name=${encodeURIComponent(name)}`,
  );
  const match = xml.match(/>([^<]*)</);
  return match ? match[1] : "";
}

async function evalLua(baseUrl: string, expr: string): Promise<string> {
  await execLua(baseUrl, `System.SetCVar("sv_servername",tostring(${expr}))`);
  return getCvar(baseUrl, "sv_servername");
}

// ===== Read Player Position =====

async function readPlayer(client: GameClient): Promise<PlayerState | null> {
  try {
    const xml = await fetchAPI(
      client.api,
      "/api/rpg/SoulList/PlayerSoul?depth=1",
    );
    const posMatch = xml.match(/Position="([^"]+)"/);
    if (!posMatch) return null;

    const parts = posMatch[1].split(",");
    if (parts.length < 3) return null;

    // Read rotation
    let rotZ = 0;
    try {
      const rotStr = await evalLua(client.api, "player:GetWorldAngles().z");
      const parsed = parseFloat(rotStr);
      if (!isNaN(parsed)) rotZ = parsed;
    } catch {}

    return {
      x: parseFloat(parts[0]),
      y: parseFloat(parts[1]),
      z: parseFloat(parts[2]),
      rotZ,
    };
  } catch {
    return null;
  }
}

// ===== Update Ghost on Target Client =====

async function updateGhost(
  target: GameClient,
  sourceClient: GameClient,
  pos: PlayerState,
) {
  const gx = pos.x.toFixed(2);
  const gy = pos.y.toFixed(2);
  const gz = pos.z.toFixed(2);
  const rot = pos.rotZ.toFixed(4);
  const ghostId = sourceClient.name.toLowerCase();

  if (target.modLoaded) {
    await execLua(
      target.api,
      `KCD2MP_UpdateGhost("${ghostId}",${gx},${gy},${gz},${rot})`,
    );
  } else {
    // Fallback: direct spawn/move without mod
    const name = `mp_ghost_${ghostId}`;
    if (!target.ghostSpawned) {
      await execLua(
        target.api,
        `System.SpawnEntity({class="NPC",name="${name}",position={x=${gx},y=${gy},z=${gz}}})`,
      );
    } else {
      await execLua(
        target.api,
        `local e=System.GetEntityByName("${name}"); if e then e:SetWorldPos({x=${gx},y=${gy},z=${gz}}); e:SetWorldAngles({x=0,y=0,z=${rot}}) end`,
      );
    }
  }

  if (!target.ghostSpawned) {
    console.log(
      `[${target.name}] Ghost "${ghostId}" spawned at ${gx},${gy},${gz}`,
    );
    target.ghostSpawned = true;
  }
}

// ===== Probe Client =====

async function probeClient(client: GameClient): Promise<boolean> {
  try {
    const calendarXml = await fetchAPI(client.api, "/api/rpg/Calendar?depth=1");
    const timeMatch = calendarXml.match(/GameTime="([^"]+)"/);
    const gameTime = timeMatch ? parseFloat(timeMatch[1]) : 0;

    if (gameTime === 0) {
      console.log(`[${client.name}] Main menu (GameTime=0)`);
      return false;
    }

    const playerXml = await fetchAPI(
      client.api,
      "/api/rpg/SoulList/PlayerSoul?depth=1",
    );
    const nameMatch = playerXml.match(/Name="([^"]+)"/);
    const posMatch = playerXml.match(/Position="([^"]+)"/);
    console.log(
      `[${client.name}] Game running! Player: ${nameMatch?.[1] ?? "?"} at ${posMatch?.[1] ?? "?"}`,
    );

    // Check mod
    const modType = await evalLua(client.api, "type(KCD2MP)");
    client.modLoaded = modType === "table";
    console.log(
      `[${client.name}] Mod: ${client.modLoaded ? "YES" : "NO (fallback)"}`,
    );

    return true;
  } catch (e: any) {
    console.log(`[${client.name}] Probe failed: ${e.message}`);
    return false;
  }
}

// ===== Position Changed =====

function posChanged(a: PlayerState | null, b: PlayerState): boolean {
  if (!a) return true;
  return (
    Math.abs(a.x - b.x) > 0.05 ||
    Math.abs(a.y - b.y) > 0.05 ||
    Math.abs(a.z - b.z) > 0.05 ||
    Math.abs(a.rotZ - b.rotZ) > 0.02
  );
}

// ===== Main Tick =====

async function tick() {
  // Probe clients that aren't ready
  for (const client of clients) {
    if (!client.ready) {
      client.probeCount++;
      if (client.probeCount % 15 === 1) {
        client.ready = await probeClient(client);
        if (client.ready) {
          console.log(`[${client.name}] === READY ===`);
        }
      }
      continue;
    }
  }

  // For each pair: read pos from one, send ghost to other
  for (let i = 0; i < clients.length; i++) {
    const source = clients[i];
    const target = clients[1 - i]; // the other client

    if (!source.ready) continue;

    try {
      const pos = await readPlayer(source);
      if (!pos) continue;

      if (posChanged(source.lastPos, pos)) {
        source.lastPos = pos;
        console.log(
          `[${source.name}] x=${pos.x.toFixed(1)} y=${pos.y.toFixed(1)} z=${pos.z.toFixed(1)} rot=${pos.rotZ.toFixed(2)}`,
        );

        // Send to other client (if ready)
        if (target.ready) {
          try {
            await updateGhost(target, source, pos);
          } catch (e: any) {
            console.log(`[${target.name}] Ghost update failed: ${e.message}`);
          }
        }
      }
    } catch {
      console.log(`[${source.name}] Connection lost, re-probing...`);
      source.ready = false;
      source.probeCount = 0;
    }
  }
}

// ===== Start =====

console.log("=== KCD2 Multiplayer Server ===");
console.log("");
for (const c of clients) {
  console.log(`  ${c.name}: ${c.api}`);
}
console.log("");
console.log(`Tick: ${TICK_MS}ms`);
console.log("Waiting for both games...");
console.log("");

setInterval(tick, TICK_MS);
