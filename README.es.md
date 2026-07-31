# KCD2 Multiplayer

**Languages:** [English](README.md) | [Português](README.pt-BR.md) | [Español](README.es.md) | [中文](README.zh-CN.md) | [Русский](README.ru.md)

Mod experimental de multijugador para Kingdom Come: Deliverance II. Cada jugador ve al otro como un NPC fantasma — la posición y la rotación se sincronizan en tiempo real.

## Arquitectura

```
PC1: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┐
                                                          ├── [KcdMpServer.exe]
PC2: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┘
```

- **KcdMpServer.exe** — servidor de retransmisión (relay), puede ejecutarse en cualquier lugar (uno de los PCs con el juego o una máquina dedicada)
- **KcdMpClient.exe** — se ejecuta en cada PC con el juego; lee la posición local y la envía al servidor relay, recibe las posiciones de los demás jugadores y actualiza su fantasma en el juego local

Cada agente cliente habla únicamente con su propio juego de forma local — no hay llamadas a la API del juego a través de la LAN.

---

## Requisitos

- Kingdom Come: Deliverance II
- KCD2 Modding Tools (gratis en Steam — entrada separada en la biblioteca, necesaria para habilitar la API de depuración)

---

## Paso 1: Instalar el Mod (ambos PCs)

1. Copia la carpeta `kdcmp` al directorio `Mods` de las Modding Tools:
   ```
   <ModdingTools>\Mods\kdcmp\
   ```
   Ejemplo: `D:\SteamLibrary\steamapps\common\KCD2ModMods\Mods\kdcmp\`

2. Estructura final de carpetas:
   ```
   Mods/
     kdcmp/
       mod.manifest
       Data/
         kdcmp.pak
   ```

3. Inicia siempre el juego a través de **KCD2 Modding Tools** (no con el acceso directo del juego base).

4. Carga una partida guardada y luego verifica que el mod se haya cargado — abre `kcd.log` y busca:
   ```
   [KCD2-MP] === MOD INIT ===
   ```

---

## Paso 2: Configuración de Red (ambos PCs)

La API de depuración del juego solo escucha en `localhost:1403`. Abre **PowerShell como Administrador** en **cada PC** y ejecuta:

```powershell
# Expone la API del juego en el puerto 1404 (accesible desde la misma máquina)
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=1404 connectaddress=127.0.0.1 connectport=1403
netsh advfirewall firewall add rule name="KCD2 API 1404" dir=in action=allow protocol=TCP localport=1404
```

Verifica que funcione (el juego debe tener una partida cargada):
```powershell
curl.exe http://localhost:1404/api/rpg/Calendar?depth=1
# Debe devolver XML con GameTime > 0
```

### Abrir el puerto 7778 en el PC del servidor relay

En el PC que ejecuta **KcdMpServer.exe**, abre también el puerto del relay:

```powershell
netsh advfirewall firewall add rule name="KCD2MP Relay 7778" dir=in action=allow protocol=TCP localport=7778
```

---

## Paso 3: Ejecutar el Servidor Relay

Elige un PC (o una máquina dedicada) para alojar el relay. Ejecuta:

```
KcdMpServer.exe
```

O con un puerto personalizado:
```
KcdMpServer.exe --port 7778
```

Deberías ver:
```
=== KCD2 Multiplayer Relay Server ===
Port: 7778

Listening on port 7778...
Waiting for clients to connect.
```

El servidor no tiene configuración — no necesita conocer la IP de nadie.

---

## Paso 4: Ejecutar el Agente Cliente (en cada PC con el juego)

Cada jugador ejecuta `KcdMpClient.exe` en su propia máquina.

```
KcdMpClient.exe <serverIP> <serverPort> <tuNombre> <gameApiUrl>
```

| Argumento | Descripción | Ejemplo |
|---|---|---|
| `serverIP` | IP del PC que ejecuta el servidor relay | `192.168.1.10` o `localhost` |
| `serverPort` | Puerto del servidor relay (por defecto 7778) | `7778` |
| `tuNombre` | Tu nombre de usuario | `PC1` |
| `gameApiUrl` | API de depuración local del juego | `http://localhost:1404` |

### Ejemplo: servidor relay en PC1, dos jugadores

**PC1** (servidor relay + juego en la misma máquina):
```
KcdMpClient.exe localhost 7778 PC1 http://localhost:1404
```

**PC2**:
```
KcdMpClient.exe 192.168.1.10 7778 PC2 http://localhost:1404
```

Reemplaza `192.168.1.10` con la IP local real del PC1 (`ipconfig` → Dirección IPv4).

Cuando esté conectado, verás:
```
Game ready!
Connected! Assigned id=1
[pos] 1042.3 847.1 204.6  rot=1.57
```

---

## Orden de Inicio

1. Inicia **KcdMpServer.exe** (en cualquier momento, permanece en ejecución)
2. En cada PC: inicia el juego a través de Modding Tools, carga una partida
3. En cada PC: inicia **KcdMpClient.exe**
4. Ambos clientes se conectan → los jugadores ven el fantasma del otro

Los agentes cliente esperan automáticamente a que el juego tenga una partida cargada y se reconectan si el servidor relay se reinicia.

---

## Compilar Desde el Código Fuente

Requiere el [.NET 8 SDK](https://dotnet.microsoft.com/download).

```powershell
cd dotnet

# Ejecutar directamente (desarrollo)
dotnet run --project KcdMp.Server
dotnet run --project KcdMp.Client -- localhost 7778 PC1 http://localhost:1404

# Compilar un .exe independiente (no requiere .NET instalado para ejecutarse)
dotnet publish KcdMp.Server -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o publish\server
dotnet publish KcdMp.Client -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o publish\client
```

Salida: `dotnet\publish\server\KcdMpServer.exe` y `dotnet\publish\client\KcdMpClient.exe`

---

## Solución de Problemas

### `localhost:1404` no responde
- Asegúrate de haber iniciado el juego a través de **Modding Tools**, no el juego base
- Asegúrate de que haya una partida cargada (la API no devuelve nada en el menú principal)
- Ejecuta de nuevo el comando de portproxy (se reinicia al reiniciar Windows)

### El puerto 1403 no se inicia en el juego
Una reserva de URL puede estar bloqueándolo. Ejecuta como Administrador:
```powershell
netsh http show urlacl | findstr 1403
# Si se encuentra:
netsh http delete urlacl url=http://+:1403/
netsh http delete urlacl url=http://*:1403/
```
Luego reinicia el juego.

### El cliente no puede conectarse al servidor relay
- Verifica la IP del servidor relay con `ipconfig` → Dirección IPv4
- Asegúrate de que se haya añadido la regla de firewall del puerto 7778 en el PC del servidor
- Prueba `ping <serverIP>` desde el PC cliente

### El mod no carga
Revisa `kcd.log` buscando `[KCD2-MP] === MOD INIT ===`. Si falta:
- Verifica que la carpeta `kdcmp` esté en el directorio `Mods` correcto
- Asegúrate de que el juego se haya iniciado a través de Modding Tools

---

## Eliminar la Configuración de Red

```powershell
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=1404
netsh advfirewall firewall delete rule name="KCD2 API 1404"
netsh advfirewall firewall delete rule name="KCD2MP Relay 7778"
```

---

## Limitaciones Conocidas

- Solo sincronización de posición y rotación — sin inventario, misiones ni sincronización de partidas guardadas
- Ambos jugadores deben tener una partida cargada para que la sincronización funcione
- La apariencia del NPC fantasma depende de que un NPC pueda aparecer en la zona

## Notas de Desarrollo

Para reconstruir el pak del mod después de editar los scripts Lua, usa [KCD2-PAK](https://github.com/7H3LaughingMan/KCD2-PAK).
