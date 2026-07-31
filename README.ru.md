# KCD2 Multiplayer

**Languages:** [English](README.md) | [Português](README.pt-BR.md) | [Español](README.es.md) | [中文](README.zh-CN.md) | [Русский](README.ru.md)

Экспериментальный мультиплеерный мод для Kingdom Come: Deliverance II. Каждый игрок видит другого как NPC-призрака — позиция и поворот синхронизируются в реальном времени.

## Архитектура

```
PC1: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┐
                                                          ├── [KcdMpServer.exe]
PC2: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┘
```

- **KcdMpServer.exe** — сервер-ретранслятор (relay), может работать где угодно (на одном из игровых ПК или на выделенной машине)
- **KcdMpClient.exe** — работает на каждом ПК с игрой; читает локальную позицию и отправляет её на сервер-ретранслятор, получает позиции других игроков и обновляет их призрака в локальной игре

Каждый клиентский агент общается только со своей локальной игрой — никаких вызовов игрового API через локальную сеть (LAN).

---

## Требования

- Kingdom Come: Deliverance II
- KCD2 Modding Tools (бесплатно в Steam — отдельная запись в библиотеке, нужна для включения отладочного API)

---

## Шаг 1: Установка мода (на обоих ПК)

1. Скопируйте папку `kdcmp` в директорию `Mods` Modding Tools:
   ```
   <ModdingTools>\Mods\kdcmp\
   ```
   Пример: `D:\SteamLibrary\steamapps\common\KCD2ModMods\Mods\kdcmp\`

2. Итоговая структура папок:
   ```
   Mods/
     kdcmp/
       mod.manifest
       Data/
         kdcmp.pak
   ```

3. Всегда запускайте игру через **KCD2 Modding Tools** (а не через ярлык обычной игры).

4. Загрузите сохранение, затем проверьте, что мод загрузился — откройте `kcd.log` и найдите строку:
   ```
   [KCD2-MP] === MOD INIT ===
   ```

---

## Шаг 2: Настройка сети (на обоих ПК)

Отладочный API игры слушает только `localhost:1403`. Откройте **PowerShell от имени администратора** на **каждом ПК** и выполните:

```powershell
# Открываем игровой API на порту 1404 (доступен с той же машины)
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=1404 connectaddress=127.0.0.1 connectport=1403
netsh advfirewall firewall add rule name="KCD2 API 1404" dir=in action=allow protocol=TCP localport=1404
```

Проверьте, что всё работает (в игре должно быть загружено сохранение):
```powershell
curl.exe http://localhost:1404/api/rpg/Calendar?depth=1
# Должен вернуть XML с GameTime > 0
```

### Откройте порт 7778 на ПК с сервером-ретранслятором

На ПК, где запущен **KcdMpServer.exe**, также откройте порт ретранслятора:

```powershell
netsh advfirewall firewall add rule name="KCD2MP Relay 7778" dir=in action=allow protocol=TCP localport=7778
```

---

## Шаг 3: Запуск сервера-ретранслятора

Выберите один ПК (или выделенную машину) для размещения ретранслятора. Запустите:

```
KcdMpServer.exe
```

Или с пользовательским портом:
```
KcdMpServer.exe --port 7778
```

Вы должны увидеть:
```
=== KCD2 Multiplayer Relay Server ===
Port: 7778

Listening on port 7778...
Waiting for clients to connect.
```

У сервера нет конфигурации — ему не нужно знать чей-либо IP-адрес.

---

## Шаг 4: Запуск клиентского агента (на каждом ПК с игрой)

Каждый игрок запускает `KcdMpClient.exe` на своей машине.

```
KcdMpClient.exe <serverIP> <serverPort> <вашеИмя> <gameApiUrl>
```

| Аргумент | Описание | Пример |
|---|---|---|
| `serverIP` | IP ПК, на котором запущен сервер-ретранслятор | `192.168.1.10` или `localhost` |
| `serverPort` | Порт сервера-ретранслятора (по умолчанию 7778) | `7778` |
| `вашеИмя` | Ваше отображаемое имя | `PC1` |
| `gameApiUrl` | Локальный отладочный API игры | `http://localhost:1404` |

### Пример: сервер-ретранслятор на PC1, два игрока

**PC1** (сервер-ретранслятор и игра на одной машине):
```
KcdMpClient.exe localhost 7778 PC1 http://localhost:1404
```

**PC2**:
```
KcdMpClient.exe 192.168.1.10 7778 PC2 http://localhost:1404
```

Замените `192.168.1.10` на реальный локальный IP-адрес PC1 (`ipconfig` → IPv4-адрес).

После подключения вы увидите:
```
Game ready!
Connected! Assigned id=1
[pos] 1042.3 847.1 204.6  rot=1.57
```

---

## Порядок запуска

1. Запустите **KcdMpServer.exe** (в любое время, работает постоянно)
2. На каждом ПК: запустите игру через Modding Tools, загрузите сохранение
3. На каждом ПК: запустите **KcdMpClient.exe**
4. Оба клиента подключаются → игроки видят призраков друг друга

Клиентские агенты автоматически ждут, пока в игре загрузится сохранение, и переподключаются при перезапуске сервера-ретранслятора.

---

## Сборка из исходного кода

Требуется [.NET 8 SDK](https://dotnet.microsoft.com/download).

```powershell
cd dotnet

# Запуск напрямую (для разработки)
dotnet run --project KcdMp.Server
dotnet run --project KcdMp.Client -- localhost 7778 PC1 http://localhost:1404

# Сборка автономного .exe (для запуска не нужен установленный .NET)
dotnet publish KcdMp.Server -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o publish\server
dotnet publish KcdMp.Client -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o publish\client
```

Результат: `dotnet\publish\server\KcdMpServer.exe` и `dotnet\publish\client\KcdMpClient.exe`

---

## Решение проблем

### `localhost:1404` не отвечает
- Убедитесь, что вы запустили игру через **Modding Tools**, а не через обычную игру
- Убедитесь, что сохранение загружено (в главном меню API ничего не возвращает)
- Выполните команду portproxy заново (сбрасывается после перезагрузки Windows)

### Порт 1403 не запускается в игре
Возможно, его блокирует резервирование URL. Запустите от имени администратора:
```powershell
netsh http show urlacl | findstr 1403
# Если найдено:
netsh http delete urlacl url=http://+:1403/
netsh http delete urlacl url=http://*:1403/
```
Затем перезапустите игру.

### Клиент не может подключиться к серверу-ретранслятору
- Проверьте IP сервера-ретранслятора через `ipconfig` → IPv4-адрес
- Убедитесь, что на ПК сервера добавлено правило файервола для порта 7778
- Попробуйте `ping <serverIP>` с клиентского ПК

### Мод не загружается
Проверьте `kcd.log` на наличие строки `[KCD2-MP] === MOD INIT ===`. Если её нет:
- Убедитесь, что папка `kdcmp` находится в правильной директории `Mods`
- Убедитесь, что игра была запущена через Modding Tools

---

## Удаление сетевой настройки

```powershell
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=1404
netsh advfirewall firewall delete rule name="KCD2 API 1404"
netsh advfirewall firewall delete rule name="KCD2MP Relay 7778"
```

---

## Известные ограничения

- Синхронизируются только позиция и поворот — без инвентаря, квестов или синхронизации сохранений
- Для работы синхронизации у обоих игроков должно быть загружено сохранение
- Внешний вид NPC-призрака зависит от того, может ли NPC появиться (заспавниться) в данной области

## Заметки для разработчиков

Чтобы пересобрать pak мода после редактирования Lua-скриптов, используйте [KCD2-PAK](https://github.com/7H3LaughingMan/KCD2-PAK).
