# KCD2 Lua API - 已验证的方法

**Languages:** [English](kcd2_lua_api.md) | [Português](kcd2_lua_api.pt-BR.md) | [Español](kcd2_lua_api.es.md) | [中文](kcd2_lua_api.zh-CN.md) | [Русский](kcd2_lua_api.ru.md)

Kingdom Come: Deliverance 2，v1.5.2，CryEngine，Lua 5.1。
所有方法均已在游戏中验证。源码提取自 `Scripts.pak`。

---

## System

```lua
System.LogAlways(msg)
System.AddCCommand(name, luaCode, description)
System.ExecuteCommand(cmd)
System.SetCVar(name, value)
System.GetCVarValue(name)                     -- 返回字符串
System.SpawnEntity(params)                    -- 返回 entity 或 nil
System.GetEntityByName(name)
System.GetEntityByClass(class)
```

**SpawnEntity 参数表：**

```lua
System.SpawnEntity({
    class    = "NPC",            -- NPC、AnimObject、GeomEntity、BasicEntity、Player
    name     = "MyNPC",
    position = {x=0, y=0, z=0},
    scale    = {x=1, y=1, z=1},
})
```

---

## Script

```lua
Script.SetTimer(ms, callback)    -- 仅限运行时使用，不能在 startup/init 脚本中调用
Script.ReloadScript(path)
```

---

## Entity（基础）

```lua
entity:GetWorldPos()             -- 返回 {x, y, z}
entity:SetWorldPos({x, y, z})
entity:GetAngles()               -- 返回欧拉角 {x, y, z}
entity:Hide(1/0)
entity:Destroy()
```

---

## ItemManager

```lua
local itemHandle = ItemManager.CreateItem(itemGuid, quantity, condition)
-- condition: 1.0 = 完好，0.0 = 损坏
-- 需要给 NPC 装备物品时，使用这个而不是 inventory:CreateItem()
```

---

## entity.inventory

```lua
entity.inventory:AddItem(itemHandle)
entity.inventory:FindItem(guid)              -- 返回槽位句柄或 nil
entity.inventory:RemoveAllItems()
```

---

## entity.actor

```lua
-- 通过服装预设进行视觉装备（在 NPC 上有效）
entity.actor:EquipClothingPreset(clothingPresetGuid)

-- 武器预设
entity.actor:EquipWeaponPreset(weaponPresetGuid)

-- 从库存槽位装备物品（会加入库存槽位，但不会在 NPC 模型上显示）
entity.actor:EquipInventoryItem(slot)

-- 读取当前预设
local guid = entity.actor:GetInitialClothingPreset()
```

> **注意：** 在 NPC 上使用 `EquipInventoryItem` 会把物品放入库存，但**不会**在模型上
> 视觉呈现。若要实现视觉上的装备效果，请使用 `EquipClothingPreset`。

---

## 给生成的 NPC 装备盔甲

完整可用的模式（已验证）：

```lua
local pos = player:GetWorldPos()
local npc = System.SpawnEntity({class="NPC", name="TestNPC", position=pos, scale={x=1,y=1,z=1}})
if not npc then return end

-- 第 1 步：将物品添加到库存
local GAMBESON = "00b7ed62-a7bd-4269-acfa-8d852366579b"  -- GambesonShort01_m04_D2
local CUIRASS  = "10ff6d35-8c14-4871-8656-bdc3476d8b12"  -- Cuirass07_m01_A4

npc.inventory:AddItem(ItemManager.CreateItem(GAMBESON, 1, 1))
npc.inventory:AddItem(ItemManager.CreateItem(CUIRASS,  1, 1))

-- 第 2 步：通过 ClothingPreset 进行视觉装备（GUID 在 XML 中定义）
npc.actor:EquipClothingPreset("dc000001-0000-0000-0000-000000000000")
```

### 所需的 XML 文件（pak 内的 `Libs/Tables/item/clothing_preset__modname.xml`）

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

**规则：**

- 文件名必须是 `clothing_preset__*.xml`（双下划线）——游戏会合并所有匹配该模式的文件
- `clothing_preset_id` 必须是合法的十六进制 UUID（只能是数字 0-9 和字母 a-f！）
- `EquipClothingPreset` 接收的是 **GUID**（`clothing_preset_id`），而不是名称
- `<Items>` 中列出的物品会在角色模型上以视觉形式穿戴出来

---

## NPC 动画

```lua
entity:StartAnimation(slot, animName)         -- 有效："run"、"walk"、"idle" 等
entity:StopAnimation(slot, layer)
entity:IsAnimationRunning(slot, layer)
entity:SetAnimationSpeed(slot, layer, speed)
entity:GetAnimationTime(slot, layer)
entity:GetAnimationLength(slot, animName)
entity:ForceCharacterUpdate(slot, bool)

-- 在 NPC 上不可用：
-- SetAnimationInput、SetMotionParameter、PlayAnimation
```

---

## NPC AI（entity.AI）

```lua
entity.AI:SetRefPointPosition({x, y, z})
entity.AI:GoTo({x, y, z})
entity.AI:SetForcedNavigation({x, y, z})
-- 还有 50 多个其他 AI 函数可用
```

---

## 玩家专属

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
-- 已知的元素："Menu"、"ApseModalDialog"
```

---

## 调试 REST API（localhost:1403）

| 端点                                                 | 说明                          |
| --------------------------------------------------- | ----------------------------- |
| `GET /api/rpg/SoulList/PlayerSoul?depth=1`          | 玩家位置、名称与状态           |
| `GET /api/rpg/Calendar?depth=1`                     | GameTime（0 表示在主菜单）     |
| `GET /api/System/Console/ExecuteString?command=...` | 执行控制台命令                 |
| `GET /api/System/Console/GetCvarValue?name=...`     | 读取 CVar 的值                 |
| `GET /api/<path>?info`                              | 发现属性/方法                  |
| `GET /api/<path>?depth=1`                           | 读取数值                       |

执行 Lua：命令前加 `#` 前缀，例如 `#System.SetCVar("x","y")`

取值小技巧：通过 Lua 写入某个 CVar，再通过 GetCvarValue 把它读回来。

> **WSL2 提示：** WSL2 中的 `curl` 无法访问 Windows 的 `localhost:1403`。
> 请使用 `powershell.exe` 或 `cmd.exe /c curl.exe`。

---

## 已知物品 GUID

| 物品                    | GUID                                    |
| ---------------------- | --------------------------------------- |
| GambesonShort01_m04_D2 | `00b7ed62-a7bd-4269-acfa-8d852366579b`  |
| Cuirass07_m01_A4       | `10ff6d35-8c14-4871-8656-bdc3476d8b12`  |

物品数据来源：`Data/Tables.pak → Libs/Tables/item/item.xml`

---

## Pak 构建脚本（PowerShell）

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

> 重新打包 pak 之前一定要先关闭游戏（游戏运行时该文件会被锁定）。

---

## 源码参考（Scripts.pak）

| 文件                                             | 内容                                                                  |
| ------------------------------------------------ | --------------------------------------------------------------------- |
| `Scripts/Debug/CombatDebug.lua`                | SpawnEnemy、EquipClothingPreset、EquipWeaponPreset、tblArmor 预设     |
| `Scripts/Entities/actor/player.lua`            | ItemManager.CreateItem、AddItem、EquipClothingPreset（装备作弊）      |
| `Scripts/Entities/AI/InventoryDummyPlayer.lua` | NPC 的 entity 结构、BasicActor/BasicAI                                |
| `Scripts/Entities/WH/Stash/AnimStash.lua`      | 库存模式、储物箱（stash）交互                                          |
| `Scripts/FlowNodes/InventoryWeapon.lua`        | 武器库存的 flow node                                                  |
