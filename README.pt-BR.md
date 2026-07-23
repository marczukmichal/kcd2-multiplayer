# KCD2 Multiplayer

**Languages:** [English](README.md) | [Português](README.pt-BR.md) | [Español](README.es.md) | [中文](README.zh-CN.md) | [Русский](README.ru.md)

Mod experimental de multiplayer para Kingdom Come: Deliverance II. Cada jogador vê o outro como um NPC-fantasma — posição e rotação são sincronizadas em tempo real.

## Arquitetura

```
PC1: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┐
                                                          ├── [KcdMpServer.exe]
PC2: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┘
```

- **KcdMpServer.exe** — servidor relay, pode rodar em qualquer lugar (um dos PCs com o jogo ou uma máquina dedicada)
- **KcdMpClient.exe** — roda em cada PC com o jogo; lê a posição local e envia para o servidor relay, recebe as posições dos outros jogadores e atualiza o fantasma deles no jogo local

Cada agente cliente conversa apenas com o próprio jogo localmente — nenhuma chamada da API do jogo passa pela rede local (LAN).

---

## Requisitos

- Kingdom Come: Deliverance II
- KCD2 Modding Tools (gratuito na Steam — entrada separada na biblioteca, necessária para habilitar a API de debug)

---

## Passo 1: Instalar o Mod (ambos os PCs)

1. Copie a pasta `kdcmp` para o diretório `Mods` das Modding Tools:
   ```
   <ModdingTools>\Mods\kdcmp\
   ```
   Exemplo: `D:\SteamLibrary\steamapps\common\KCD2ModMods\Mods\kdcmp\`

2. Estrutura final de pastas:
   ```
   Mods/
     kdcmp/
       mod.manifest
       Data/
         kdcmp.pak
   ```

3. Sempre inicie o jogo através das **KCD2 Modding Tools** (não pelo atalho do jogo base).

4. Carregue um save e depois verifique se o mod foi carregado — abra o `kcd.log` e procure por:
   ```
   [KCD2-MP] === MOD INIT ===
   ```

---

## Passo 2: Configuração de Rede (ambos os PCs)

A API de debug do jogo escuta apenas em `localhost:1403`. Abra o **PowerShell como Administrador** em **cada PC** e execute:

```powershell
# Expõe a API do jogo na porta 1404 (acessível pela mesma máquina)
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=1404 connectaddress=127.0.0.1 connectport=1403
netsh advfirewall firewall add rule name="KCD2 API 1404" dir=in action=allow protocol=TCP localport=1404
```

Verifique se funcionou (o jogo precisa ter um save carregado):
```powershell
curl.exe http://localhost:1404/api/rpg/Calendar?depth=1
# Deve retornar XML com GameTime > 0
```

### Abrir a porta 7778 no PC do servidor relay

No PC que roda o **KcdMpServer.exe**, abra também a porta do relay:

```powershell
netsh advfirewall firewall add rule name="KCD2MP Relay 7778" dir=in action=allow protocol=TCP localport=7778
```

---

## Passo 3: Rodar o Servidor Relay

Escolha um PC (ou uma máquina dedicada) para hospedar o relay. Execute:

```
KcdMpServer.exe
```

Ou com uma porta customizada:
```
KcdMpServer.exe --port 7778
```

Você deverá ver:
```
=== KCD2 Multiplayer Relay Server ===
Port: 7778

Listening on port 7778...
Waiting for clients to connect.
```

O servidor não tem configuração — ele não precisa saber o IP de ninguém.

---

## Passo 4: Rodar o Agente Cliente (em cada PC com o jogo)

Cada jogador roda o `KcdMpClient.exe` na própria máquina.

```
KcdMpClient.exe <serverIP> <serverPort> <seuNome> <gameApiUrl>
```

| Argumento | Descrição | Exemplo |
|---|---|---|
| `serverIP` | IP do PC que roda o servidor relay | `192.168.1.10` ou `localhost` |
| `serverPort` | Porta do servidor relay (padrão 7778) | `7778` |
| `seuNome` | Seu nome de exibição | `PC1` |
| `gameApiUrl` | API de debug local do jogo | `http://localhost:1404` |

### Exemplo: servidor relay no PC1, dois jogadores

**PC1** (servidor relay + jogo na mesma máquina):
```
KcdMpClient.exe localhost 7778 PC1 http://localhost:1404
```

**PC2**:
```
KcdMpClient.exe 192.168.1.10 7778 PC2 http://localhost:1404
```

Substitua `192.168.1.10` pelo IP local real do PC1 (`ipconfig` → Endereço IPv4).

Quando conectado, você verá:
```
Game ready!
Connected! Assigned id=1
[pos] 1042.3 847.1 204.6  rot=1.57
```

---

## Ordem de Inicialização

1. Inicie o **KcdMpServer.exe** (a qualquer momento, permanece rodando)
2. Em cada PC: inicie o jogo pelas Modding Tools, carregue um save
3. Em cada PC: inicie o **KcdMpClient.exe**
4. Ambos os clientes conectam → os jogadores veem o fantasma um do outro

Os agentes cliente esperam automaticamente o jogo ter um save carregado e reconectam se o servidor relay reiniciar.

---

## Compilando a Partir do Código-Fonte

Requer o [.NET 8 SDK](https://dotnet.microsoft.com/download).

```powershell
cd dotnet

# Rodar diretamente (desenvolvimento)
dotnet run --project KcdMp.Server
dotnet run --project KcdMp.Client -- localhost 7778 PC1 http://localhost:1404

# Compilar .exe standalone (não precisa de .NET instalado para rodar)
dotnet publish KcdMp.Server -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o publish\server
dotnet publish KcdMp.Client -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o publish\client
```

Saída: `dotnet\publish\server\KcdMpServer.exe` e `dotnet\publish\client\KcdMpClient.exe`

---

## Solução de Problemas

### `localhost:1404` não responde
- Confira se você iniciou o jogo pelas **Modding Tools**, não pelo jogo base
- Confira se um save está carregado (a API não retorna nada no menu principal)
- Rode o comando de portproxy novamente (ele é resetado após reiniciar o Windows)

### Porta 1403 não inicia no jogo
Uma reserva de URL pode estar bloqueando. Rode como Admin:
```powershell
netsh http show urlacl | findstr 1403
# Se encontrar:
netsh http delete urlacl url=http://+:1403/
netsh http delete urlacl url=http://*:1403/
```
Depois reinicie o jogo.

### Cliente não consegue conectar ao servidor relay
- Confira o IP do servidor relay com `ipconfig` → Endereço IPv4
- Confira se a regra de firewall da porta 7778 foi adicionada no PC do servidor
- Tente `ping <serverIP>` a partir do PC cliente

### Mod não carrega
Confira o `kcd.log` procurando por `[KCD2-MP] === MOD INIT ===`. Se não encontrar:
- Verifique se a pasta `kdcmp` está no diretório `Mods` correto
- Confira se o jogo foi iniciado pelas Modding Tools

---

## Removendo a Configuração de Rede

```powershell
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=1404
netsh advfirewall firewall delete rule name="KCD2 API 1404"
netsh advfirewall firewall delete rule name="KCD2MP Relay 7778"
```

---

## Limitações Conhecidas

- Apenas sincronização de posição e rotação — sem inventário, quests ou sincronização de save
- Ambos os jogadores precisam ter um save carregado para a sincronização funcionar
- A aparência do NPC-fantasma depende do NPC spawnar na área

## Notas de Desenvolvimento

Para recompilar o pak do mod após editar os scripts Lua, use o [KCD2-PAK](https://github.com/7H3LaughingMan/KCD2-PAK).
