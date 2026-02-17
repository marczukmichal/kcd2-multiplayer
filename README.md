# KCD2 Multiplayer - Setup Guide

## Requirements

- Kingdom Come: Deliverance II
- KCD2 Modding Tools (free on Steam - separate entry in library)
- Two PCs on the same local network (LAN)
- One PC runs the server (Node.js required)

## Architecture

```
PC1 (server)                    PC2
  Game + Mod                     Game + Mod
  Debug API :1404                Debug API :1404
       \                           /
        \--- Server (Node.js) ---/
        reads positions, sends ghosts
```

The server reads player position from each PC's debug API and sends a ghost NPC to the other PC. Each player sees the other as an NPC in their game world.

## Step 1: Install KCD2 Modding Tools

On **both PCs**:

1. Open Steam Library
2. Search for "Kingdom Come Deliverance II Modding Tools"
3. Install it (free)
4. Always launch the game through Modding Tools (this enables the debug API)

## Step 2: Install the Mod

On **both PCs**:

1. Copy the `kdcmp` folder to:

   ```
   <Mod tools Install Path>\Mods\kdcmp\
   ```

   Example: `D:\SteamLibrary\steamapps\common\KCD2ModMods\kdcmp\`

2. The folder structure should be:

   ```
   Mods/
     kdcmp/
       mod.manifest
       Data/
         kdcmp.pak
         Scripts/
           Startup/
             kdcmp.lua
   ```

3. Launch the game through Modding Tools and load a save

4. Verify the mod loaded - check `kcd.log` for:
   ```
   [KCD2-MP] === MOD INIT ===
   [KCD2-MP] Commands OK
   ```

## Step 3: Network Setup (Both PCs)

The debug API listens on `localhost:1403` by default. It's not accessible from the network. We need to expose it via port forwarding on port 1404.

On **each PC**, open **PowerShell as Administrator** and run:

```powershell
# Forward external port 1404 to local API on 1403
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=1404 connectaddress=127.0.0.1 connectport=1403

# Open port 1404 in Windows Firewall
netsh advfirewall firewall add rule name="KCD2 API 1404" dir=in action=allow protocol=TCP localport=1404
```

To verify it works, on each PC run:

```powershell
curl.exe http://localhost:1404/api/rpg/Calendar?depth=1
```

You should see XML with GameTime (not 0 - load a save first).

Then from the **other PC**, test with the first PC's IP:

```powershell
curl.exe http://<OTHER_PC_IP>:1404/api/rpg/Calendar?depth=1
```

### Troubleshooting: API Not Starting on Port 1403

If `localhost:1403` doesn't work even with Modding Tools:

A port reservation may be blocking it. Run as Admin:

```powershell
# Check if something reserves port 1403
netsh http show urlacl | findstr 1403

# If found, delete all reservations:
netsh http delete urlacl url=http://+:1403/
netsh http delete urlacl url=http://*:1403/
```

Then restart the game.

### Troubleshooting: Can't Reach Other PC

1. Check both PCs are on the same network: `ipconfig` - look at IPv4 Address
2. Try pinging the other PC: `ping <OTHER_PC_IP>`
3. Make sure the firewall rule was added: `netsh advfirewall firewall show rule name="KCD2 API 1404"`
4. Make sure the port proxy is set: `netsh interface portproxy show all`
5. Make sure the game is running with a loaded save (API returns nothing on main menu)

## Step 4: Configure and Run the Server

On the PC that will run the server:

1. Install Node.js (v18+): https://nodejs.org/

2. Edit `server/index.ts` - update the IP addresses:

   ```typescript
   const clients: GameClient[] = [
     {
       name: "PC1",
       api: "http://<PC1_IP>:1404",
       // ...
     },
     {
       name: "PC2",
       api: "http://<PC2_IP>:1404",
       // ...
     },
   ];
   ```

3. Install dependencies and run:

   ```bash
   cd server
   npm install
   npx tsx index.ts
   ```

4. The server will show:

   ```
   === KCD2 Multiplayer Server ===
     PC1: http://<IP>:1404
     PC2: http://<IP>:1404
   Waiting for both games...
   ```

5. Once both games are running with loaded saves, you'll see:

   ```
   [PC1] === READY ===
   [PC2] === READY ===
   ```

6. Each player should now see the other as an NPC ghost in their world.

## Removing Network Setup

To undo the port forwarding and firewall rules:

```powershell
# Remove port forward
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=1404

# Remove firewall rule
netsh advfirewall firewall delete rule name="KCD2 API 1404"
```

## Known Limitations

- Ghost NPC does not have walking/running animation (stands still, teleports between positions)
- No quest, inventory, or save synchronization
- Position sync only - movement, rotation
- Both players must be in a loaded save for sync to work
- Server must be restarted if a player reloads their save
