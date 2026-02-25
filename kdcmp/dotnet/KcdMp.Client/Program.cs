using KcdMp.Client;

// Usage: KcdMpClient [serverHost] [serverPort] [name] [gameApiBase]
// All arguments are optional; defaults work for a single-PC setup.
string serverHost  = args.Length > 0 ? args[0] : "localhost";
int    serverPort  = args.Length > 1 ? int.Parse(args[1]) : 7778;
string name        = args.Length > 2 ? args[2] : Environment.MachineName;
string gameApiBase = args.Length > 3 ? args[3] : "http://localhost:1404";

Console.WriteLine("=== KCD2 Multiplayer Client Agent ===");
Console.WriteLine($"Server : {serverHost}:{serverPort}");
Console.WriteLine($"Name   : {name}");
Console.WriteLine($"Game   : {gameApiBase}");
Console.WriteLine();

var bridge = new GameBridge(serverHost, serverPort, name, gameApiBase);
await bridge.RunAsync();
