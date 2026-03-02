using KcdMp.Client;
using Microsoft.Win32;
using System.Text.RegularExpressions;

// Usage: KcdMpClient [serverHost] [serverPort] [name] [gameApiBase]
// All arguments are optional; defaults work for a single-PC setup.
string serverHost  = args.Length > 0 ? args[0] : "localhost";
int    serverPort  = args.Length > 1 ? int.Parse(args[1]) : 7778;
string name        = args.Length > 2 ? args[2]
    : GetSteamNameFromKcdLog()   // primary: kcd.log written by KCD2's own Steam API
    ?? GetSteamPersonaName()     // fallback: loginusers.vdf
    ?? Environment.MachineName;  // last resort
string gameApiBase = args.Length > 3 ? args[3] : "http://localhost:1404";

// ---------------------------------------------------------------------------
// Find all Steam library paths via libraryfolders.vdf, then look for
// KCD2's kcd.log (which contains the line user_id=STEAMID='PersonaName').
// ---------------------------------------------------------------------------
static string? GetSteamNameFromKcdLog()
{
    try
    {
        // Steam client directory  (e.g. C:\Program Files (x86)\Steam)
        string? steamDir =
            Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null) as string
            ?? Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam",           "InstallPath", null) as string
            ?? Registry.GetValue(@"HKEY_CURRENT_USER\SOFTWARE\Valve\Steam",            "SteamPath",   null) as string;

        Console.WriteLine($"[KcdLog] Steam dir = {steamDir ?? "(not found)"}");
        if (steamDir is null) return null;

        // Collect all Steam library root paths from libraryfolders.vdf
        var libraryPaths = new List<string> { steamDir };

        string lf = Path.Combine(steamDir, "config", "libraryfolders.vdf");
        if (File.Exists(lf))
        {
            var pathRe = new Regex(@"""path""\s+""([^""]+)""", RegexOptions.IgnoreCase);
            foreach (string line in File.ReadLines(lf))
            {
                var m = pathRe.Match(line.Trim());
                if (m.Success)
                {
                    string p = m.Groups[1].Value.Replace("\\\\", "\\");
                    if (!libraryPaths.Contains(p, StringComparer.OrdinalIgnoreCase))
                        libraryPaths.Add(p);
                }
            }
        }

        Console.WriteLine($"[KcdLog] Steam libraries: {string.Join(", ", libraryPaths)}");

        // KCD2 sub-path inside any library
        const string KCD2SubPath = @"steamapps\common\KingdomComeDeliverance2\kcd.log";

        var nameRe = new Regex(@"user_id=\d+='([^']+)'");

        foreach (string lib in libraryPaths)
        {
            string logPath = Path.Combine(lib, KCD2SubPath);
            if (!File.Exists(logPath)) continue;

            Console.WriteLine($"[KcdLog] Reading {logPath}");
            int n = 0;
            foreach (string line in File.ReadLines(logPath))
            {
                var m = nameRe.Match(line);
                if (m.Success)
                {
                    Console.WriteLine($"[KcdLog] Found Steam name: {m.Groups[1].Value}");
                    return m.Groups[1].Value;
                }
                if (++n > 500) break;
            }
        }
    }
    catch (Exception ex) { Console.WriteLine($"[KcdLog] Error: {ex.Message}"); }
    return null;
}

// ---------------------------------------------------------------------------
// Parse Steam's loginusers.vdf: prefer AutoLoginUser, fall back to MostRecent.
// ---------------------------------------------------------------------------
static string? GetSteamPersonaName()
{
    try
    {
        string? steamPath =
            Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null) as string
            ?? Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam",           "InstallPath", null) as string;

        string? autoLogin =
            Registry.GetValue(@"HKEY_CURRENT_USER\SOFTWARE\Valve\Steam", "AutoLoginUser", null) as string;

        Console.WriteLine($"[Steam] VDF InstallPath={steamPath ?? "(not found)"}  AutoLoginUser={autoLogin ?? "(not found)"}");
        if (steamPath is null) return null;

        string vdfPath = Path.Combine(steamPath, "config", "loginusers.vdf");
        if (!File.Exists(vdfPath)) { Console.WriteLine("[Steam] loginusers.vdf not found"); return null; }

        int depth = 0;
        string? curPersona = null;
        bool curIsAutoLogin = false, curIsMostRecent = false;
        string? bestPersona = null, recentPersona = null;
        var kvRe = new Regex(@"^""([^""]+)""\s+""([^""]*)""$");

        foreach (string raw in File.ReadLines(vdfPath))
        {
            string line = raw.Trim();
            if (line == "{") { depth++; continue; }
            if (line == "}")
            {
                if (depth == 2)
                {
                    if (curIsAutoLogin  && curPersona != null) bestPersona   = curPersona;
                    if (curIsMostRecent && curPersona != null) recentPersona = curPersona;
                    curPersona = null; curIsAutoLogin = false; curIsMostRecent = false;
                }
                depth--;
                continue;
            }
            if (depth != 2) continue;
            var m = kvRe.Match(line);
            if (!m.Success) continue;
            string key = m.Groups[1].Value, val = m.Groups[2].Value;
            if (key.Equals("PersonaName", StringComparison.OrdinalIgnoreCase)) curPersona = val;
            if (key.Equals("MostRecent",  StringComparison.OrdinalIgnoreCase) && val == "1") curIsMostRecent = true;
            if (key.Equals("AccountName", StringComparison.OrdinalIgnoreCase)
                && autoLogin != null && val.Equals(autoLogin, StringComparison.OrdinalIgnoreCase))
                curIsAutoLogin = true;
        }

        string? result = bestPersona ?? recentPersona;
        Console.WriteLine($"[Steam] PersonaName = {result ?? "(not found)"}");
        return result;
    }
    catch (Exception ex) { Console.WriteLine($"[Steam] Error: {ex.Message}"); }
    return null;
}

Console.WriteLine("=== KCD2 Multiplayer Client Agent ===");
Console.WriteLine($"Server : {serverHost}:{serverPort}");
Console.WriteLine($"Name   : {name}");
Console.WriteLine($"Game   : {gameApiBase}");
Console.WriteLine();

using var cts = new CancellationTokenSource();

// Graceful shutdown on Ctrl+C or window close — gives finally blocks time to clean up ghosts.
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
AppDomain.CurrentDomain.ProcessExit += (_, _) => { cts.Cancel(); Thread.Sleep(500); };

var bridge = new GameBridge(serverHost, serverPort, name, gameApiBase);
await bridge.RunAsync(cts.Token);
