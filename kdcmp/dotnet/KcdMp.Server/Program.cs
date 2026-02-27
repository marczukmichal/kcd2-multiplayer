using KcdMp.Server;

int port = 7778;
bool echo = false;
for (int i = 0; i < args.Length; i++)
{
    if (args[i] == "--port" && i + 1 < args.Length)
        port = int.Parse(args[++i]);
    if (args[i] == "--echo")
        echo = true;
}

Console.WriteLine("=== KCD2 Multiplayer Relay Server ===");
Console.WriteLine($"Port: {port}  Echo: {echo}");
Console.WriteLine();

var server = new RelayServer(port, echo);
await server.RunAsync();
