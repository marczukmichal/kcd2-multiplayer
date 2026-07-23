# KCD2 Lua API - Проверенные методы

**Languages:** [English](kcd2_lua_api.md) | [Português](kcd2_lua_api.pt-BR.md) | [Español](kcd2_lua_api.es.md) | [中文](kcd2_lua_api.zh-CN.md) | [Русский](kcd2_lua_api.ru.md)

Kingdom Come: Deliverance 2, v1.5.2, CryEngine, Lua 5.1.
Все методы проверены в игре. Источники извлечены из `Scripts.pak`.

---

## System

```lua
System.LogAlways(msg)
System.AddCCommand(name, luaCode, description)
System.ExecuteCommand(cmd)
System.SetCVar(name, value)
System.GetCVarValue(name)                     -- возвращает строку
System.SpawnEntity(params)                    -- возвращает entity или nil
System.GetEntityByName(name)
System.GetEntityByClass(class)
```

**Таблица параметров SpawnEntity:**

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
Script.SetTimer(ms, callback)    -- только во время выполнения, НЕ из стартовых/init-скриптов
Script.ReloadScript(path)
```

---

## Entity (базовые методы)

```lua
entity:GetWorldPos()             -- возвращает {x, y, z}
entity:SetWorldPos({x, y, z})
entity:GetAngles()               -- возвращает углы Эйлера {x, y, z}
entity:Hide(1/0)
entity:Destroy()
```

---

## ItemManager

```lua
local itemHandle = ItemManager.CreateItem(itemGuid, quantity, condition)
-- condition: 1.0 = идеальное состояние, 0.0 = сломано
-- Используйте это вместо inventory:CreateItem(), когда нужно экипировать предметы
```

---

## entity.inventory

```lua
entity.inventory:AddItem(itemHandle)
entity.inventory:FindItem(guid)              -- возвращает handle слота или nil
entity.inventory:RemoveAllItems()
```

---

## entity.actor

```lua
-- Визуальная экипировка через пресет одежды (РАБОТАЕТ на NPC)
entity.actor:EquipClothingPreset(clothingPresetGuid)

-- Пресет оружия
entity.actor:EquipWeaponPreset(weaponPresetGuid)

-- Экипировать предмет из слота инвентаря (добавляется в слот, но НЕ отображается визуально на NPC)
entity.actor:EquipInventoryItem(slot)

-- Прочитать текущий пресет
local guid = entity.actor:GetInitialClothingPreset()
```

> **Предупреждение:** `EquipInventoryItem` на NPC кладёт предмет в инвентарь, но НЕ отображает
> его визуально на модели. Используйте `EquipClothingPreset` для визуальной экипировки.

---

## Экипировка брони на заспавненного NPC

Полный рабочий шаблон (проверено):

```lua
local pos = player:GetWorldPos()
local npc = System.SpawnEntity({class="NPC", name="TestNPC", position=pos, scale={x=1,y=1,z=1}})
if not npc then return end

-- Шаг 1: добавить предметы в инвентарь
local GAMBESON = "00b7ed62-a7bd-4269-acfa-8d852366579b"  -- GambesonShort01_m04_D2
local CUIRASS  = "10ff6d35-8c14-4871-8656-bdc3476d8b12"  -- Cuirass07_m01_A4

npc.inventory:AddItem(ItemManager.CreateItem(GAMBESON, 1, 1))
npc.inventory:AddItem(ItemManager.CreateItem(CUIRASS,  1, 1))

-- Шаг 2: визуально экипировать через ClothingPreset (GUID задан в XML)
npc.actor:EquipClothingPreset("dc000001-0000-0000-0000-000000000000")
```

### Необходимый XML (`Libs/Tables/item/clothing_preset__modname.xml` внутри pak)

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

**Правила:**

- Файл должен называться `clothing_preset__*.xml` (двойное подчёркивание) — игра объединяет все файлы, подходящие под этот шаблон
- `clothing_preset_id` должен быть корректным шестнадцатеричным UUID (только цифры 0-9 и буквы a-f!)
- `EquipClothingPreset` принимает **GUID** (`clothing_preset_id`), а не имя
- Предметы, перечисленные внутри `<Items>`, визуально надеваются на модель персонажа

---

## Анимация NPC

```lua
entity:StartAnimation(slot, animName)         -- РАБОТАЕТ: "run", "walk", "idle", ...
entity:StopAnimation(slot, layer)
entity:IsAnimationRunning(slot, layer)
entity:SetAnimationSpeed(slot, layer, speed)
entity:GetAnimationTime(slot, layer)
entity:GetAnimationLength(slot, animName)
entity:ForceCharacterUpdate(slot, bool)

-- НЕДОСТУПНО на NPC:
-- SetAnimationInput, SetMotionParameter, PlayAnimation
```

---

## ИИ NPC (entity.AI)

```lua
entity.AI:SetRefPointPosition({x, y, z})
entity.AI:GoTo({x, y, z})
entity.AI:SetForcedNavigation({x, y, z})
-- доступно ещё более 50 функций ИИ
```

---

## Специфично для игрока

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
-- Известные элементы: "Menu", "ApseModalDialog"
```

---

## Отладочный REST API (localhost:1403)

| Эндпоинт                                            | Описание                        |
| --------------------------------------------------- | -------------------------------- |
| `GET /api/rpg/SoulList/PlayerSoul?depth=1`          | Позиция, имя и состояние игрока |
| `GET /api/rpg/Calendar?depth=1`                     | GameTime (0 = главное меню)     |
| `GET /api/System/Console/ExecuteString?command=...` | Выполнить команду консоли        |
| `GET /api/System/Console/GetCvarValue?name=...`     | Прочитать значение CVar          |
| `GET /api/<path>?info`                              | Узнать свойства/методы           |
| `GET /api/<path>?depth=1`                           | Прочитать значения                |

Выполнение Lua: добавьте `#` перед командой, например `#System.SetCVar("x","y")`

Приём для чтения значений: записать через Lua в CVar, затем прочитать его через GetCvarValue.

> **Примечание про WSL2:** `curl` из WSL2 не может достучаться до `localhost:1403` на Windows.
> Используйте `powershell.exe` или `cmd.exe /c curl.exe`.

---

## Известные GUID предметов

| Предмет                | GUID                                    |
| ---------------------- | --------------------------------------- |
| GambesonShort01_m04_D2 | `00b7ed62-a7bd-4269-acfa-8d852366579b`  |
| Cuirass07_m01_A4       | `10ff6d35-8c14-4871-8656-bdc3476d8b12`  |

Источник данных о предметах: `Data/Tables.pak → Libs/Tables/item/item.xml`

---

## Скрипт сборки Pak (PowerShell)

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

> Перед пересборкой pak всегда закрывайте игру (пока игра запущена, файл заблокирован).

---

## Ссылки на исходники (Scripts.pak)

| Файл                                            | Содержимое                                                             |
| ------------------------------------------------ | ------------------------------------------------------------------------ |
| `Scripts/Debug/CombatDebug.lua`                | SpawnEnemy, EquipClothingPreset, EquipWeaponPreset, пресеты tblArmor  |
| `Scripts/Entities/actor/player.lua`            | ItemManager.CreateItem, AddItem, EquipClothingPreset (читы на экипировку) |
| `Scripts/Entities/AI/InventoryDummyPlayer.lua` | Структура entity NPC, BasicActor/BasicAI                                |
| `Scripts/Entities/WH/Stash/AnimStash.lua`      | Паттерны инвентаря, взаимодействие с тайником (stash)                   |
| `Scripts/FlowNodes/InventoryWeapon.lua`        | Flow-узлы инвентаря оружия                                              |
