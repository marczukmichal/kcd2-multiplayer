# Contributing to KCD2 Multiplayer

Thanks for wanting to help out! This is a young, experimental project — contributions of any size (bug reports, small fixes, or features) are welcome.

## Requirements

- [.NET 8 SDK](https://dotnet.microsoft.com/download)
- Kingdom Come: Deliverance II + KCD2 Modding Tools (only needed if you want to actually run/test the mod in-game — not required to build or contribute to the relay/client code)
- A configured NuGet source. If `dotnet build` fails with `NU1100` errors, check `dotnet nuget list source` — if it's empty, add the public feed:
  ```
  dotnet nuget add source https://api.nuget.org/v3/index.json --name nuget.org
  ```

## Building

```powershell
cd dotnet
dotnet build
```

Run the server and client directly for local testing:
```powershell
dotnet run --project KcdMp.Server
dotnet run --project KcdMp.Client -- localhost 7778 PC1 http://localhost:1404
```

See the main [README](README.md) for full in-game setup (installing the mod, exposing the debug API, etc).

## Testing

If a `KcdMp.Tests` project is present on your branch (added alongside the equipment sync work), run it with:
```powershell
dotnet run --project KcdMp.Tests
```

There's no formal test framework wired in yet — tests are plain assertions with pass/fail console output. If you add new packet types or protocol changes, add round-trip tests following the existing pattern.

## Branch/PR conventions

- Branch names in this repo generally follow `feat/<short-name>` or `<short-name>` for features, and `fix/<short-name>` for bug fixes.
- Keep PRs focused — one feature or fix per PR makes review easier for a project with limited maintainer bandwidth.
- Before opening a PR, make sure `dotnet build` succeeds with no new errors, and run any relevant tests.
- If your change affects the Lua mod side (`kdcmp/Data/Scripts/Startup/kdcmp.lua`), rebuild the `.pak` using [KCD2-PAK](https://github.com/7H3LaughingMan/KCD2-PAK) as noted in the README's Dev Notes.

## Project structure

```
dotnet/
  KcdMp.Server/   - relay server (coordinates client connections)
  KcdMp.Client/   - client agent (talks to local game debug API + relay)
kdcmp/            - the in-game Lua mod (ghost NPC rendering, commands)
docs/             - game API / protocol notes
```

Each `KcdMp.Client` instance only talks to its own local game instance via the debug API (`localhost:1403`) — there's no cross-machine game API access, only client-to-relay TCP traffic.

## Reporting issues / getting unstuck

Open a GitHub issue with what you tried, what you expected, and what happened instead (logs from `kcd.log` or the client/server console help a lot). Response times can be slow since this is a side project for the maintainer — patience appreciated.
