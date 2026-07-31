# KCD2 Multiplayer

**Languages:** [English](README.md) | [Português](README.pt-BR.md) | [Español](README.es.md) | [中文](README.zh-CN.md) | [Русский](README.ru.md)

《天国：拯救2》(Kingdom Come: Deliverance II) 的实验性多人游戏模组。每个玩家会看到对方以"幽灵 NPC"的形式出现——位置和朝向实时同步。

## 架构

```
PC1: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┐
                                                          ├── [KcdMpServer.exe]
PC2: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┘
```

- **KcdMpServer.exe** — 中继服务器，可以运行在任意一台机器上（其中一台游戏 PC 或专用服务器）
- **KcdMpClient.exe** — 运行在每台装有游戏的 PC 上；读取本地玩家位置并发送给中继服务器，同时接收其他玩家的位置并更新本地游戏中对应的幽灵 NPC

每个客户端代理只与自己本机的游戏通信——不存在跨局域网的游戏 API 调用。

---

## 系统要求

- 《天国：拯救2》(Kingdom Come: Deliverance II)
- KCD2 Modding Tools（Steam 上免费获取——是独立于游戏本体的另一个库条目，用于启用调试 API）

---

## 第 1 步：安装模组（两台 PC 都要做）

1. 将 `kdcmp` 文件夹复制到 Modding Tools 的 `Mods` 目录中：
   ```
   <ModdingTools>\Mods\kdcmp\
   ```
   示例：`D:\SteamLibrary\steamapps\common\KCD2ModMods\Mods\kdcmp\`

2. 最终的文件夹结构：
   ```
   Mods/
     kdcmp/
       mod.manifest
       Data/
         kdcmp.pak
   ```

3. 请始终通过 **KCD2 Modding Tools** 启动游戏（而不是游戏本体的快捷方式）。

4. 加载一个存档，然后确认模组已加载——打开 `kcd.log`，查找以下内容：
   ```
   [KCD2-MP] === MOD INIT ===
   ```

---

## 第 2 步：网络配置（两台 PC 都要做）

游戏的调试 API 只监听 `localhost:1403`。请在**每台 PC** 上以**管理员身份**打开 PowerShell 并执行：

```powershell
# 将游戏 API 暴露在 1404 端口上（同一台机器可访问）
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=1404 connectaddress=127.0.0.1 connectport=1403
netsh advfirewall firewall add rule name="KCD2 API 1404" dir=in action=allow protocol=TCP localport=1404
```

验证是否生效（游戏必须已加载存档）：
```powershell
curl.exe http://localhost:1404/api/rpg/Calendar?depth=1
# 应返回包含 GameTime > 0 的 XML
```

### 在中继服务器所在的 PC 上开放 7778 端口

在运行 **KcdMpServer.exe** 的 PC 上，还需要开放中继端口：

```powershell
netsh advfirewall firewall add rule name="KCD2MP Relay 7778" dir=in action=allow protocol=TCP localport=7778
```

---

## 第 3 步：运行中继服务器

选择一台 PC（或一台专用机器）来托管中继服务。运行：

```
KcdMpServer.exe
```

或者使用自定义端口：
```
KcdMpServer.exe --port 7778
```

你应该会看到：
```
=== KCD2 Multiplayer Relay Server ===
Port: 7778

Listening on port 7778...
Waiting for clients to connect.
```

服务器没有任何配置项——它不需要知道任何人的 IP 地址。

---

## 第 4 步：运行客户端代理（每台装有游戏的 PC 都要做）

每位玩家在自己的机器上运行 `KcdMpClient.exe`。

```
KcdMpClient.exe <serverIP> <serverPort> <你的名字> <gameApiUrl>
```

| 参数 | 说明 | 示例 |
|---|---|---|
| `serverIP` | 运行中继服务器的 PC 的 IP 地址 | `192.168.1.10` 或 `localhost` |
| `serverPort` | 中继服务器端口（默认 7778） | `7778` |
| `你的名字` | 你的显示名称 | `PC1` |
| `gameApiUrl` | 本地游戏调试 API 地址 | `http://localhost:1404` |

### 示例：中继服务器运行在 PC1 上，两名玩家

**PC1**（中继服务器与游戏在同一台机器上）：
```
KcdMpClient.exe localhost 7778 PC1 http://localhost:1404
```

**PC2**：
```
KcdMpClient.exe 192.168.1.10 7778 PC2 http://localhost:1404
```

将 `192.168.1.10` 替换为 PC1 的实际本地 IP 地址（`ipconfig` → IPv4 地址）。

连接成功后，你会看到：
```
Game ready!
Connected! Assigned id=1
[pos] 1042.3 847.1 204.6  rot=1.57
```

---

## 启动顺序

1. 启动 **KcdMpServer.exe**（可以随时启动，会一直运行）
2. 在每台 PC 上：通过 Modding Tools 启动游戏，加载存档
3. 在每台 PC 上：启动 **KcdMpClient.exe**
4. 两个客户端都连接后 → 玩家们就能看到彼此的幽灵 NPC

客户端代理会自动等待游戏加载存档，并在中继服务器重启后自动重连。

---

## 从源代码构建

需要 [.NET 8 SDK](https://dotnet.microsoft.com/download)。

```powershell
cd dotnet

# 直接运行（开发模式）
dotnet run --project KcdMp.Server
dotnet run --project KcdMp.Client -- localhost 7778 PC1 http://localhost:1404

# 构建独立的 .exe（运行时无需安装 .NET）
dotnet publish KcdMp.Server -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o publish\server
dotnet publish KcdMp.Client -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o publish\client
```

输出：`dotnet\publish\server\KcdMpServer.exe` 和 `dotnet\publish\client\KcdMpClient.exe`

---

## 故障排查

### `localhost:1404` 无响应
- 确认你是通过 **Modding Tools** 启动的游戏，而不是游戏本体
- 确认已加载存档（在主菜单时 API 不会返回任何数据）
- 重新执行一次 portproxy 命令（Windows 重启后该设置会被重置）

### 游戏中 1403 端口无法启动
可能有 URL 预留（URL reservation）阻塞了它。以管理员身份运行：
```powershell
netsh http show urlacl | findstr 1403
# 如果找到了：
netsh http delete urlacl url=http://+:1403/
netsh http delete urlacl url=http://*:1403/
```
然后重启游戏。

### 客户端无法连接到中继服务器
- 用 `ipconfig` → IPv4 地址检查中继服务器的 IP
- 确认服务器所在 PC 已添加 7778 端口的防火墙规则
- 从客户端 PC 尝试 `ping <serverIP>`

### 模组未加载
检查 `kcd.log` 中是否有 `[KCD2-MP] === MOD INIT ===`。如果没有：
- 确认 `kdcmp` 文件夹位于正确的 `Mods` 目录中
- 确认游戏是通过 Modding Tools 启动的

---

## 移除网络配置

```powershell
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=1404
netsh advfirewall firewall delete rule name="KCD2 API 1404"
netsh advfirewall firewall delete rule name="KCD2MP Relay 7778"
```

---

## 已知限制

- 仅同步位置和朝向——没有物品栏、任务或存档同步
- 双方玩家都必须加载存档，同步才能生效
- 幽灵 NPC 的外观取决于该区域是否能生成 NPC

## 开发说明

编辑 Lua 脚本后，如需重新打包模组 pak 文件，请使用 [KCD2-PAK](https://github.com/7H3LaughingMan/KCD2-PAK)。
