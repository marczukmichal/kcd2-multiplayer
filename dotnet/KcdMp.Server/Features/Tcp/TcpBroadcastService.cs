using KcdMp.Server.Features.ClientHandling;

namespace KcdMp.Server.Features.Tcp;

/// <summary>
/// Service class that handles TCP broadcasts.
/// </summary>
public class TcpBroadcastService
{
    private readonly object _lock = new();

    private readonly bool _echo;
    private readonly ClientHandler _clientHandler;
    
    public TcpBroadcastService(IConfiguration configuration, ClientHandler clientHandler)
    {
        _echo = configuration.GetValue<bool>("Echo");
        _clientHandler = clientHandler;
    }
    
	/// <summary>
	/// Broadcasts a position update from <paramref name="source"/> to all other ready clients.
    /// In echo mode also reflects the position back to the sender as ghost id=0.
    /// </summary>
    public void Broadcast(ClientSession source, float x, float y, float z, float rotZ, byte flags)
    {
        List<ClientSession> targets;
        lock (_lock)
            targets = [.. _clientHandler.GetClients().Where(c => c != source && c.IsReady)];

        foreach (var target in targets)
            target.EnqueueGhost(source.Id, x, y, z, rotZ, flags);

        if (_echo)
        {
            // Place echo ghost 1 m to the right of the player's facing direction
            float sideX = (float)Math.Cos(rotZ);
            float sideY = -(float)Math.Sin(rotZ);
            source.EnqueueGhost(0, x + sideX, y + sideY, z, rotZ, flags);
        }
    }

    /// <summary>
    /// Sends a Name (0x03) packet about <paramref name="source"/> to all other ready clients.
    /// </summary>
    public void BroadcastName(ClientSession source)
    {
        if (source.Name is null) return;

        List<ClientSession> targets;
        lock (_lock)
            targets = [.. _clientHandler.GetClients().Where(c => c != source && c.IsReady)];

        foreach (var target in targets)
            target.EnqueueName(source.Id, source.Name);
    }

    /// <summary>
    /// Broadcasts a Disconnect (0x06) packet to all remaining clients so they can remove the ghost.
    /// </summary>
    public void BroadcastDisconnect(ClientSession disconnected)
    {
        List<ClientSession> targets;
        lock (_lock)
            targets = [.. _clientHandler.GetClients().Where(c => c.IsReady)];

        foreach (var target in targets)
            target.EnqueueDisconnect(disconnected.Id);
    }

    /// <summary>
    /// Sends Name (0x03) packets of all currently ready clients to <paramref name="newClient"/>.
    /// </summary>
    public void SendAllNamesTo(ClientSession newClient)
    {
        List<ClientSession> existing;
        lock (_lock)
            existing = [.. _clientHandler.GetClients().Where(c => c != newClient && c.IsReady)];

        foreach (var c in existing)
            newClient.EnqueueName(c.Id, c.Name!);
    }
}