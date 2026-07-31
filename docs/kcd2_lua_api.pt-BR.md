# KCD2 Lua API - Métodos Verificados

**Languages:** [English](kcd2_lua_api.md) | [Português](kcd2_lua_api.pt-BR.md) | [Español](kcd2_lua_api.es.md) | [中文](kcd2_lua_api.zh-CN.md) | [Русский](kcd2_lua_api.ru.md)

Kingdom Come: Deliverance 2, v1.5.2, CryEngine, Lua 5.1.
Todos os métodos verificados em jogo. Fontes extraídas do `Scripts.pak`.

---

## System

```lua
System.LogAlways(msg)
System.AddCCommand(name, luaCode, description)
System.ExecuteCommand(cmd)
System.SetCVar(name, value)
System.GetCVarValue(name)                     -- retorna string
System.SpawnEntity(params)                    -- retorna entity ou nil
System.GetEntityByName(name)
System.GetEntityByClass(class)
```

**Tabela de parâmetros do SpawnEntity:**

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
Script.SetTimer(ms, callback)    -- apenas em runtime, NÃO em scripts de startup/init
Script.ReloadScript(path)
```

---

## Entity (básico)

```lua
entity:GetWorldPos()             -- retorna {x, y, z}
entity:SetWorldPos({x, y, z})
entity:GetAngles()               -- retorna {x, y, z} em ângulos de Euler
entity:Hide(1/0)
entity:Destroy()
```

---

## ItemManager

```lua
local itemHandle = ItemManager.CreateItem(itemGuid, quantity, condition)
-- condition: 1.0 = perfeito, 0.0 = quebrado
-- Use isso em vez de inventory:CreateItem() quando precisar equipar itens
```

---

## entity.inventory

```lua
entity.inventory:AddItem(itemHandle)
entity.inventory:FindItem(guid)              -- retorna o handle do slot ou nil
entity.inventory:RemoveAllItems()
```

---

## entity.actor

```lua
-- Equipar visualmente via preset de roupa (FUNCIONA em NPC)
entity.actor:EquipClothingPreset(clothingPresetGuid)

-- Preset de arma
entity.actor:EquipWeaponPreset(weaponPresetGuid)

-- Equipar item de um slot do inventário (adiciona ao slot mas NÃO aparece visualmente no NPC)
entity.actor:EquipInventoryItem(slot)

-- Ler o preset atual
local guid = entity.actor:GetInitialClothingPreset()
```

> **Aviso:** `EquipInventoryItem` em um NPC coloca o item no inventário, mas NÃO o exibe
> visualmente no modelo. Use `EquipClothingPreset` para equipar visualmente.

---

## Equipando Armadura em um NPC Spawnado

Padrão completo e funcional (verificado):

```lua
local pos = player:GetWorldPos()
local npc = System.SpawnEntity({class="NPC", name="TestNPC", position=pos, scale={x=1,y=1,z=1}})
if not npc then return end

-- Passo 1: adicionar itens ao inventário
local GAMBESON = "00b7ed62-a7bd-4269-acfa-8d852366579b"  -- GambesonShort01_m04_D2
local CUIRASS  = "10ff6d35-8c14-4871-8656-bdc3476d8b12"  -- Cuirass07_m01_A4

npc.inventory:AddItem(ItemManager.CreateItem(GAMBESON, 1, 1))
npc.inventory:AddItem(ItemManager.CreateItem(CUIRASS,  1, 1))

-- Passo 2: equipar visualmente via ClothingPreset (GUID definido no XML)
npc.actor:EquipClothingPreset("dc000001-0000-0000-0000-000000000000")
```

### XML Necessário (`Libs/Tables/item/clothing_preset__modname.xml` dentro do pak)

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

**Regras:**

- O arquivo deve se chamar `clothing_preset__*.xml` (duplo underscore) — o jogo mescla todos os arquivos que casarem com o padrão
- `clothing_preset_id` deve ser um UUID hexadecimal válido (apenas dígitos 0-9 e letras a-f!)
- `EquipClothingPreset` recebe o **GUID** (`clothing_preset_id`), não o nome
- Itens listados dentro de `<Items>` são vestidos visualmente no modelo do personagem

---

## Animação de NPC

```lua
entity:StartAnimation(slot, animName)         -- FUNCIONA: "run", "walk", "idle", ...
entity:StopAnimation(slot, layer)
entity:IsAnimationRunning(slot, layer)
entity:SetAnimationSpeed(slot, layer, speed)
entity:GetAnimationTime(slot, layer)
entity:GetAnimationLength(slot, animName)
entity:ForceCharacterUpdate(slot, bool)

-- NÃO disponível em NPC:
-- SetAnimationInput, SetMotionParameter, PlayAnimation
```

---

## IA do NPC (entity.AI)

```lua
entity.AI:SetRefPointPosition({x, y, z})
entity.AI:GoTo({x, y, z})
entity.AI:SetForcedNavigation({x, y, z})
-- mais de 50 funções adicionais de IA disponíveis
```

---

## Específico do Player

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
-- Elementos conhecidos: "Menu", "ApseModalDialog"
```

---

## API REST de Debug (localhost:1403)

| Endpoint                                            | Descrição                    |
| --------------------------------------------------- | ----------------------------- |
| `GET /api/rpg/SoulList/PlayerSoul?depth=1`          | Posição, nome e estado do jogador |
| `GET /api/rpg/Calendar?depth=1`                     | GameTime (0 = menu principal) |
| `GET /api/System/Console/ExecuteString?command=...` | Executar comando de console   |
| `GET /api/System/Console/GetCvarValue?name=...`     | Ler valor de uma CVar         |
| `GET /api/<path>?info`                              | Descobrir propriedades/métodos |
| `GET /api/<path>?depth=1`                           | Ler valores                   |

Execução de Lua: prefixe o comando com `#`, ex.: `#System.SetCVar("x","y")`

Truque de avaliação: escreva em uma CVar via Lua, leia de volta via GetCvarValue.

> **Nota WSL2:** o `curl` do WSL2 não consegue alcançar `localhost:1403` do Windows.
> Use `powershell.exe` ou `cmd.exe /c curl.exe`.

---

## GUIDs de Itens Conhecidos

| Item                   | GUID                                   |
| ---------------------- | -------------------------------------- |
| GambesonShort01_m04_D2 | `00b7ed62-a7bd-4269-acfa-8d852366579b` |
| Cuirass07_m01_A4       | `10ff6d35-8c14-4871-8656-bdc3476d8b12` |

Fonte dos dados de itens: `Data/Tables.pak → Libs/Tables/item/item.xml`

---

## Script de Build do Pak (PowerShell)

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

> Sempre feche o jogo antes de recompilar o pak (o arquivo fica travado enquanto o jogo roda).

---

## Referências de Fontes (Scripts.pak)

| Arquivo                                        | Conteúdo                                                              |
| ----------------------------------------------- | ----------------------------------------------------------------------- |
| `Scripts/Debug/CombatDebug.lua`                | SpawnEnemy, EquipClothingPreset, EquipWeaponPreset, tblArmor presets |
| `Scripts/Entities/actor/player.lua`            | ItemManager.CreateItem, AddItem, EquipClothingPreset (cheats de equipamento) |
| `Scripts/Entities/AI/InventoryDummyPlayer.lua` | Estrutura de entity de NPC, BasicActor/BasicAI                       |
| `Scripts/Entities/WH/Stash/AnimStash.lua`      | Padrões de inventário, interação com baú/stash                       |
| `Scripts/FlowNodes/InventoryWeapon.lua`        | Flow nodes de inventário de armas                                    |
