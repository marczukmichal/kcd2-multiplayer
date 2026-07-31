# KCD2 Lua API - Métodos Verificados

**Languages:** [English](kcd2_lua_api.md) | [Português](kcd2_lua_api.pt-BR.md) | [Español](kcd2_lua_api.es.md) | [中文](kcd2_lua_api.zh-CN.md) | [Русский](kcd2_lua_api.ru.md)

Kingdom Come: Deliverance 2, v1.5.2, CryEngine, Lua 5.1.
Todos los métodos verificados en el juego. Fuentes extraídas de `Scripts.pak`.

---

## System

```lua
System.LogAlways(msg)
System.AddCCommand(name, luaCode, description)
System.ExecuteCommand(cmd)
System.SetCVar(name, value)
System.GetCVarValue(name)                     -- devuelve string
System.SpawnEntity(params)                    -- devuelve entity o nil
System.GetEntityByName(name)
System.GetEntityByClass(class)
```

**Tabla de parámetros de SpawnEntity:**

```lua
System.SpawnEntity({
    class    = "NPC",            -- NPC, AnimObject, GeomEntity, BasicEntity, Player
    name     = "MyNPC",
    position = {x=0, y=0, z=0},
    scale    = {x=1, y=1, z=1},
})
```

---

## Script

```lua
Script.SetTimer(ms, callback)    -- solo en runtime, NO desde scripts de startup/init
Script.ReloadScript(path)
```

---

## Entity (básico)

```lua
entity:GetWorldPos()             -- devuelve {x, y, z}
entity:SetWorldPos({x, y, z})
entity:GetAngles()               -- devuelve {x, y, z} en ángulos de Euler
entity:Hide(1/0)
entity:Destroy()
```

---

## ItemManager

```lua
local itemHandle = ItemManager.CreateItem(itemGuid, quantity, condition)
-- condition: 1.0 = perfecto, 0.0 = roto
-- Úsalo en lugar de inventory:CreateItem() cuando necesites equipar objetos
```

---

## entity.inventory

```lua
entity.inventory:AddItem(itemHandle)
entity.inventory:FindItem(guid)              -- devuelve el handle del slot o nil
entity.inventory:RemoveAllItems()
```

---

## entity.actor

```lua
-- Equipar visualmente mediante un preset de ropa (FUNCIONA en NPC)
entity.actor:EquipClothingPreset(clothingPresetGuid)

-- Preset de arma
entity.actor:EquipWeaponPreset(weaponPresetGuid)

-- Equipar un objeto desde un slot del inventario (se añade al slot pero NO se muestra visualmente en el modelo del NPC)
entity.actor:EquipInventoryItem(slot)

-- Leer el preset actual
local guid = entity.actor:GetInitialClothingPreset()
```

> **Advertencia:** `EquipInventoryItem` en un NPC coloca el objeto en el inventario, pero NO lo
> muestra visualmente en el modelo. Usa `EquipClothingPreset` para el equipamiento visual.

---

## Equipar Armadura en un NPC Generado (Spawned)

Patrón completo y funcional (verificado):

```lua
local pos = player:GetWorldPos()
local npc = System.SpawnEntity({class="NPC", name="TestNPC", position=pos, scale={x=1,y=1,z=1}})
if not npc then return end

-- Paso 1: añadir objetos al inventario
local GAMBESON = "00b7ed62-a7bd-4269-acfa-8d852366579b"  -- GambesonShort01_m04_D2
local CUIRASS  = "10ff6d35-8c14-4871-8656-bdc3476d8b12"  -- Cuirass07_m01_A4

npc.inventory:AddItem(ItemManager.CreateItem(GAMBESON, 1, 1))
npc.inventory:AddItem(ItemManager.CreateItem(CUIRASS,  1, 1))

-- Paso 2: equipar visualmente mediante ClothingPreset (GUID definido en el XML)
npc.actor:EquipClothingPreset("dc000001-0000-0000-0000-000000000000")
```

### XML Requerido (`Libs/Tables/item/clothing_preset__modname.xml` dentro del pak)

```xml
<?xml version="1.0" encoding="us-ascii"?>
<database xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="barbora"
          xsi:noNamespaceSchemaLocation="../database.xsd">
    <clothing_presets version="2">
        <clothing_preset
            clothing_preset_id="dc000001-0000-0000-0000-000000000000"
            clothing_preset_name="kcd2mp_ghost_armor"
            gender="Male"
            prefers_hood_on="false">
            <Items>
                <Guid>00b7ed62-a7bd-4269-acfa-8d852366579b</Guid>
                <Guid>10ff6d35-8c14-4871-8656-bdc3476d8b12</Guid>
            </Items>
        </clothing_preset>
    </clothing_presets>
</database>
```

**Reglas:**

- El archivo debe llamarse `clothing_preset__*.xml` (doble guion bajo) — el juego combina todos los archivos que coincidan con el patrón
- `clothing_preset_id` debe ser un UUID hexadecimal válido (¡solo dígitos 0-9 y letras a-f!)
- `EquipClothingPreset` recibe el **GUID** (`clothing_preset_id`), no el nombre
- Los objetos listados dentro de `<Items>` se visten visualmente en el modelo del personaje

---

## Animación de NPC

```lua
entity:StartAnimation(slot, animName)         -- FUNCIONA: "run", "walk", "idle", ...
entity:StopAnimation(slot, layer)
entity:IsAnimationRunning(slot, layer)
entity:SetAnimationSpeed(slot, layer, speed)
entity:GetAnimationTime(slot, layer)
entity:GetAnimationLength(slot, animName)
entity:ForceCharacterUpdate(slot, bool)

-- NO disponible en NPC:
-- SetAnimationInput, SetMotionParameter, PlayAnimation
```

---

## IA del NPC (entity.AI)

```lua
entity.AI:SetRefPointPosition({x, y, z})
entity.AI:GoTo({x, y, z})
entity.AI:SetForcedNavigation({x, y, z})
-- más de 50 funciones adicionales de IA disponibles
```

---

## Específico del Jugador

```lua
player:GetWorldPos()                          -- {x, y, z}
player.human:IsInDialog()
player.soul:IsInCombatDanger()
player.soul:HaveSkill('thievery')
player.soul:GetSkillLevel("thievery")
```

---

## UIAction

```lua
UIAction.RegisterElementListener(state, element, -1, "OnShow"/"OnHide", "callbackName")
-- Elementos conocidos: "Menu", "ApseModalDialog"
```

---

## API REST de Depuración (localhost:1403)

| Endpoint                                            | Descripción                   |
| --------------------------------------------------- | ------------------------------ |
| `GET /api/rpg/SoulList/PlayerSoul?depth=1`          | Posición, nombre y estado del jugador |
| `GET /api/rpg/Calendar?depth=1`                     | GameTime (0 = menú principal)  |
| `GET /api/System/Console/ExecuteString?command=...` | Ejecutar comando de consola    |
| `GET /api/System/Console/GetCvarValue?name=...`     | Leer el valor de una CVar      |
| `GET /api/<path>?info`                              | Descubrir propiedades/métodos  |
| `GET /api/<path>?depth=1`                           | Leer valores                   |

Ejecución de Lua: antepón `#` al comando, p. ej. `#System.SetCVar("x","y")`

Truco de evaluación: escribe en una CVar mediante Lua, léela de vuelta con GetCvarValue.

> **Nota WSL2:** `curl` desde WSL2 no puede alcanzar `localhost:1403` de Windows.
> Usa `powershell.exe` o `cmd.exe /c curl.exe`.

---

## GUIDs de Objetos Conocidos

| Objeto                 | GUID                                   |
| ---------------------- | -------------------------------------- |
| GambesonShort01_m04_D2 | `00b7ed62-a7bd-4269-acfa-8d852366579b` |
| Cuirass07_m01_A4       | `10ff6d35-8c14-4871-8656-bdc3476d8b12` |

Fuente de los datos de objetos: `Data/Tables.pak → Libs/Tables/item/item.xml`

---

## Script de Compilación del Pak (PowerShell)

```powershell
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$pakPath = 'D:\kcd2multiplayer\kdcmp\Data\kdcmp.pak'
$srcRoot  = 'D:\kcd2multiplayer\kdcmp\Data'
$files    = @(
    'Scripts\Startup\kdcmp.lua',
    'Libs\Tables\item\clothing_preset__kdcmp.xml'
)

Remove-Item $pakPath -Force -ErrorAction SilentlyContinue
$zip = [System.IO.Compression.ZipFile]::Open($pakPath, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($rel in $files) {
    $entry  = $zip.CreateEntry($rel.Replace('\','/'), [System.IO.Compression.CompressionLevel]::NoCompression)
    $stream = $entry.Open()
    $bytes  = [System.IO.File]::ReadAllBytes((Join-Path $srcRoot $rel))
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
}
$zip.Dispose()
```

> Cierra siempre el juego antes de recompilar el pak (el archivo queda bloqueado mientras el juego se ejecuta).

---

## Referencias de Fuentes (Scripts.pak)

| Archivo                                        | Contenido                                                              |
| ----------------------------------------------- | ------------------------------------------------------------------------ |
| `Scripts/Debug/CombatDebug.lua`                | SpawnEnemy, EquipClothingPreset, EquipWeaponPreset, presets tblArmor  |
| `Scripts/Entities/actor/player.lua`            | ItemManager.CreateItem, AddItem, EquipClothingPreset (trucos de equipo) |
| `Scripts/Entities/AI/InventoryDummyPlayer.lua` | Estructura de entity de NPC, BasicActor/BasicAI                       |
| `Scripts/Entities/WH/Stash/AnimStash.lua`      | Patrones de inventario, interacción con baúles/stash                 |
| `Scripts/FlowNodes/InventoryWeapon.lua`        | Flow nodes de inventario de armas                                     |
