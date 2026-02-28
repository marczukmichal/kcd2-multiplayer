# KCD2 Multiplayer

Experimental multiplayer mod for Kingdom Come: Deliverance II. Each player sees the other as a ghost NPC — position and rotation are synced in real time. Includes proximity voice chat.

## Features

- Real-time position, rotation and horse-riding sync
- Proximity voice chat (linear volume falloff, audible up to 20 m)
- Player name display (auto-detected from Steam)

## Architecture

```
PC1: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┐
                                                          ├── [KcdMpServer]
PC2: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┘
```

- **KcdMpServer** — relay server, can run anywhere (Windows or Linux)
- **KcdMpClient.exe** — runs on every PC with the game; reads local position and pushes to the relay server, receives other players' positions and updates their ghost in the local game

Each client agent talks to its own game locally — no cross-LAN game API calls.

---

## Requirements

- Kingdom Come: Deliverance II
- KCD2 Modding Tools (free on Steam — separate library entry, needed to enable the debug API)

---

## Step 1: Install the Mod (both PCs)

1. Copy the `kdcmp` folder to your Modding Tools `Mods` directory:
   ```
   <ModdingTools>\Mods\kdcmp\
   ```
   Example: `D:\SteamLibrary\steamapps\common\KCD2ModMods\Mods\kdcmp\`

2. Final folder structure:
   ```
   Mods/
     kdcmp/
       mod.manifest
       Data/
         kdcmp.pak
   ```

3. Always launch the game through **KCD2 Modding Tools** (not the base game shortcut).

4. Load a save, then verify the mod loaded — open `kcd.log` and look for:
   ```
   [KCD2-MP] === MOD INIT ===
   ```

---

## Step 2: Network Setup

Open **PowerShell as Administrator** on the PC that runs the relay server and open the relay port:

```powershell
netsh advfirewall firewall add rule name="KCD2MP Relay 7778" dir=in action=allow protocol=TCP localport=7778
```

Verify the game API works (game must have a save loaded):
```powershell
curl.exe http://localhost:1403/api/rpg/Calendar?depth=1
# Should return XML with GameTime > 0
```

---

## Step 3: Run the Relay Server

Pick one PC (or a dedicated machine) to host the relay.

**Windows:**
```
KcdMpServer.exe
```

**Linux:**
```bash
chmod +x KcdMpServer
./KcdMpServer
```

Or with a custom port:
```
KcdMpServer.exe --port 7778
./KcdMpServer --port 7778
```

You should see:
```
=== KCD2 Multiplayer Relay Server ===
Port: 7778

Listening on port 7778...
Waiting for clients to connect.
```

The server has no config — it doesn't need to know anyone's IP.

---

## Step 4: Run the Client Agent (every PC with the game)

Each player runs `KcdMpClient.exe` on their own machine.

```
KcdMpClient.exe [serverIP] [serverPort] [yourName] [gameApiUrl]
```

All arguments are optional — if omitted, the client auto-detects your Steam name and uses `localhost:7778` and `http://localhost:1403`.

| Argument | Description | Default |
|---|---|---|
| `serverIP` | IP of the PC running the relay server | `localhost` |
| `serverPort` | Relay server port | `7778` |
| `yourName` | Your display name (auto-read from Steam if omitted) | Steam name |
| `gameApiUrl` | Local game debug API | `http://localhost:1403` |

### Example: relay server on PC1, two players

**PC1** (relay server + game on same machine):
```
KcdMpClient.exe localhost 7778 PC1 http://localhost:1403
```

**PC2**:
```
KcdMpClient.exe 192.168.1.10 7778 PC2 http://localhost:1403
```

Replace `192.168.1.10` with PC1's actual local IP (`ipconfig` → IPv4 Address).

When connected, you'll see:
```
Game ready!
Connected! Assigned id=1
[pos] 1042.3 847.1 204.6  rot=1.57
[voice] Started  16kHz mono PCM  frame=640B  range=20m
```

---

## Voice Chat

Proximity voice chat starts automatically when the client connects.

- **Range:** 20 metres — volume falls off linearly to zero at max range
- **Format:** 16 kHz mono 16-bit PCM, 20 ms frames
- **VAD:** frames with no detected speech are not transmitted
- **Mute:** not yet exposed as a hotkey — can be added in a future version

No extra ports are needed — voice data is relayed through the same TCP connection as position data.

---

## Startup Order

1. Start the relay server (any time, stays running)
2. On each PC: launch the game via Modding Tools, load a save
3. On each PC: start `KcdMpClient.exe`
4. Both clients connect → players see each other's ghosts and hear each other's voice

Client agents automatically wait for the game to have a save loaded and reconnect if the relay server restarts.

---

## Building from Source

Requires [.NET 8 SDK](https://dotnet.microsoft.com/download).

```powershell
cd dotnet

# Run directly (development)
dotnet run --project KcdMp.Server
dotnet run --project KcdMp.Client -- localhost 7778 PC1 http://localhost:1403

# Build standalone executables (no .NET required to run)
dotnet publish KcdMp.Server -c Release -r win-x64   --self-contained -p:PublishSingleFile=true -o publish\server-win
dotnet publish KcdMp.Server -c Release -r linux-x64 --self-contained -p:PublishSingleFile=true -o publish\server-linux
dotnet publish KcdMp.Client -c Release -r win-x64   --self-contained -p:PublishSingleFile=true -o publish\client-win
```

---

## Troubleshooting

### `localhost:1403` not responding
- Make sure you launched the game through **Modding Tools**, not the base game
- Make sure a save is loaded (API returns nothing on the main menu)

### Port 1403 blocked by URL reservation
A URL reservation may be blocking it. Run as Admin:
```powershell
netsh http show urlacl | findstr 1403
# If found:
netsh http delete urlacl url=http://+:1403/
netsh http delete urlacl url=http://*:1403/
```
Then restart the game.

### Client can't connect to relay server
- Check relay server IP with `ipconfig` → IPv4 Address
- Make sure port 7778 firewall rule was added on the server PC
- Try `ping <serverIP>` from the client PC

### No voice / microphone not working
- Windows: check that `KcdMpClient.exe` has microphone access (Settings → Privacy → Microphone)
- Make sure your default recording device is set correctly in Windows Sound settings

### Mod not loading
Check `kcd.log` for `[KCD2-MP] === MOD INIT ===`. If missing:
- Verify the `kdcmp` folder is in the correct `Mods` directory
- Make sure the game was launched through Modding Tools

---

## Removing Network Setup

```powershell
netsh advfirewall firewall delete rule name="KCD2MP Relay 7778"
```

---

## Known Limitations

- Position and rotation sync only — no inventory, quests, or save sync
- Both players must have a save loaded for sync to work
- Ghost NPC appearance depends on NPC spawning in the area
- Voice chat requires Windows on the client side (NAudio dependency)

## Dev Notes

To rebuild the mod pak after editing Lua scripts, use [KCD2-PAK](https://github.com/7H3LaughingMan/KCD2-PAK).
