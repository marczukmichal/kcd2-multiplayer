using KcdMp.Server;

int port = 7778;
for (int i = 0; i < args.Length; i++)
{
    if (args[i] == "--port" && i + 1 < args.Length)
        port = int.Parse(args[++i]);
}

Console.WriteLine("=== KCD2 Multiplayer Relay Server ===");
Console.WriteLine($"Port: {port}");
Console.WriteLine();

var server = new RelayServer(port);
await server.RunAsync();
