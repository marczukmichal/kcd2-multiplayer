using System.Net;
using System.Net.Sockets;

namespace KcdMp.Server;

public class RelayServer(int port, bool echo = false)
{
    private readonly List<ClientSession> _clients = [];
    private readonly object _lock = new();
    public bool Echo { get; } = echo;

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

    /// <summary>Broadcasts a position update from <paramref name="source"/> to all other ready clients.
    /// In echo mode also reflects the position back to the sender as ghost id=0.</summary>
    public void Broadcast(ClientSession source, float x, float y, float z, float rotZ, byte flags)
    {
        List<ClientSession> targets;
        lock (_lock)
            targets = [.. _clients.Where(c => c != source && c.IsReady)];

        foreach (var target in targets)
            target.EnqueueGhost(source.Id, x, y, z, rotZ, flags);

        if (Echo)
        {
            // Place echo ghost 1 m to the right of the player's facing direction
            float sideX = (float)Math.Cos(rotZ);
            float sideY = -(float)Math.Sin(rotZ);
            source.EnqueueGhost(0, x + sideX, y + sideY, z, rotZ, flags);
        }
    }

    /// <summary>Sends a Name (0x03) packet about <paramref name="source"/> to all other ready clients.</summary>
    public void BroadcastName(ClientSession source)
    {
        if (source.Name is null) return;

        List<ClientSession> targets;
        lock (_lock)
            targets = [.. _clients.Where(c => c != source && c.IsReady)];

        foreach (var target in targets)
            target.EnqueueName(source.Id, source.Name);
    }

    /// <summary>Sends Name (0x03) packets of all currently ready clients to <paramref name="newClient"/>.</summary>
    public void SendAllNamesTo(ClientSession newClient)
    {
        List<ClientSession> existing;
        lock (_lock)
            existing = [.. _clients.Where(c => c != newClient && c.IsReady)];

        foreach (var c in existing)
            newClient.EnqueueName(c.Id, c.Name!);
    }
}
