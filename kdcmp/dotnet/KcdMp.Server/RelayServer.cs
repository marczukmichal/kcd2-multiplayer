using System.Net;
using System.Net.Sockets;

namespace KcdMp.Server;

public class RelayServer(int port)
{
    private readonly List<ClientSession> _clients = [];
    private readonly object _lock = new();

    public async Task RunAsync()
    {
        var listener = new TcpListener(IPAddress.Any, port);
        listener.Start();
        Console.WriteLine($"Listening on port {port}...");
        Console.WriteLine("Waiting for clients to connect.");
        Console.WriteLine();

        while (true)
        {
            var tcp = await listener.AcceptTcpClientAsync();
            var session = new ClientSession(tcp, this);

            lock (_lock)
                _clients.Add(session);

            _ = session.RunAsync().ContinueWith(_ =>
            {
                lock (_lock)
                    _clients.Remove(session);
                Console.WriteLine($"[-] {session.Name ?? $"id={session.Id}"} disconnected. Clients: {_clients.Count}");
            });
        }
    }

    /// <summary>Broadcasts a position update from <paramref name="source"/> to all other ready clients.</summary>
    public void Broadcast(ClientSession source, float x, float y, float z, float rotZ)
    {
        List<ClientSession> targets;
        lock (_lock)
            targets = [.. _clients.Where(c => c != source && c.IsReady)];

        foreach (var target in targets)
            target.EnqueueGhost(source.Id, x, y, z, rotZ);
    }
}
