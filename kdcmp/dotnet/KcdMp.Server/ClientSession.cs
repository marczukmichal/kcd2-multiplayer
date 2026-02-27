using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;

namespace KcdMp.Server;

/// <summary>
/// Handles one connected client agent.
///
/// Wire protocol (all packets):
///   [type:1][payloadLen:2 LE][payload:N]
///
/// C→S  0x00  Handshake:  [nameLen:1][name:UTF-8]
/// C→S  0x01  Position:   [x:4f][y:4f][z:4f][rotZ:4f][flags:1]  (17 bytes, LE IEEE-754)
///               flags bit 0: isRiding
/// S→C  0xFF  Ack:        [assignedId:1]
/// S→C  0x02  Ghost:      [ghostId:1][x:4f][y:4f][z:4f][rotZ:4f][flags:1]  (18 bytes)
/// S→C  0x03  Name:       [ghostId:1][name:UTF-8...]
/// </summary>
public class ClientSession
{
    private static int _idCounter;

    private readonly TcpClient _tcp;
    private readonly NetworkStream _stream;
    private readonly RelayServer _server;
    private readonly Channel<byte[]> _writeQueue = Channel.CreateUnbounded<byte[]>();

    public byte Id { get; } = (byte)Interlocked.Increment(ref _idCounter);
    public string? Name { get; private set; }
    public bool IsReady => Name is not null;

    public ClientSession(TcpClient tcp, RelayServer server)
    {
        _tcp = tcp;
        _stream = tcp.GetStream();
        _server = server;
    }

    public async Task RunAsync()
    {
        var writeTask = WriteLoopAsync();
        try
        {
            // --- Handshake ---
            var header = new byte[3];
            await ReadExactAsync(header);

            if (header[0] != 0x00)
            {
                Console.WriteLine($"[!] Client sent bad handshake type 0x{header[0]:X2}, dropping.");
                return;
            }

            int nameLen = header[1]; // single byte, max 255
            var nameBytes = new byte[nameLen];
            await ReadExactAsync(nameBytes);
            Name = Encoding.UTF8.GetString(nameBytes);

            Console.WriteLine($"[+] '{Name}' connected (id={Id}) from {_tcp.Client.RemoteEndPoint}. Clients: active");

            // Send Ack with assigned ID
            EnqueueRaw(BuildPacket(0xFF, [Id]));

            // Broadcast this client's name to all others; send existing names to this client
            _server.BroadcastName(this);
            _server.SendAllNamesTo(this);

            // --- Position receive loop ---
            // Accepts both v1 (16 bytes: x,y,z,rotZ) and v2 (17 bytes: x,y,z,rotZ,flags)
            var posPayload = new byte[17];
            while (true)
            {
                await ReadExactAsync(header);
                int type = header[0];
                int payloadLen = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(1));

                if (type != 0x01 || (payloadLen != 16 && payloadLen != 17))
                {
                    // Skip unknown/malformed packet
                    if (payloadLen > 0)
                    {
                        var skip = new byte[payloadLen];
                        await ReadExactAsync(skip);
                    }
                    continue;
                }

                // Read exactly payloadLen bytes (16 or 17)
                await ReadExactAsync(posPayload, payloadLen);

                float x    = ReadFloat(posPayload, 0);
                float y    = ReadFloat(posPayload, 4);
                float z    = ReadFloat(posPayload, 8);
                float rotZ = ReadFloat(posPayload, 12);
                byte  flags = payloadLen >= 17 ? posPayload[16] : (byte)0x00;

                _server.Broadcast(this, x, y, z, rotZ, flags);
            }
        }
        catch (Exception ex) when (ex is IOException or SocketException or EndOfStreamException)
        {
            // Normal disconnect
        }
        finally
        {
            _writeQueue.Writer.Complete();
            await writeTask;
            _tcp.Dispose();
        }
    }

    /// <summary>Thread-safe: enqueue a Ghost packet to be sent to this client.</summary>
    public void EnqueueGhost(byte ghostId, float x, float y, float z, float rotZ, byte flags)
    {
        var payload = new byte[18];
        payload[0] = ghostId;
        WriteFloat(payload, 1, x);
        WriteFloat(payload, 5, y);
        WriteFloat(payload, 9, z);
        WriteFloat(payload, 13, rotZ);
        payload[17] = flags;
        EnqueueRaw(BuildPacket(0x02, payload));
    }

    /// <summary>Thread-safe: enqueue a Name packet (0x03) to be sent to this client.</summary>
    public void EnqueueName(byte ghostId, string name)
    {
        var nameBytes = Encoding.UTF8.GetBytes(name);
        var payload = new byte[1 + nameBytes.Length];
        payload[0] = ghostId;
        nameBytes.CopyTo(payload, 1);
        EnqueueRaw(BuildPacket(0x03, payload));
    }

    private void EnqueueRaw(byte[] packet) =>
        _writeQueue.Writer.TryWrite(packet);

    private async Task WriteLoopAsync()
    {
        await foreach (var packet in _writeQueue.Reader.ReadAllAsync())
        {
            try { await _stream.WriteAsync(packet); }
            catch { break; }
        }
    }

    // ---- Helpers ----

    private static byte[] BuildPacket(byte type, byte[] payload)
    {
        var packet = new byte[3 + payload.Length];
        packet[0] = type;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)payload.Length);
        payload.CopyTo(packet, 3);
        return packet;
    }

    private static float ReadFloat(byte[] buf, int offset) =>
        BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(buf.AsSpan(offset)));

    private static void WriteFloat(byte[] buf, int offset, float value) =>
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(offset), BitConverter.SingleToInt32Bits(value));

    private Task ReadExactAsync(byte[] buffer) => ReadExactAsync(buffer, buffer.Length);

    private async Task ReadExactAsync(byte[] buffer, int count)
    {
        int offset = 0;
        while (offset < count)
        {
            int n = await _stream.ReadAsync(buffer, offset, count - offset);
            if (n == 0) throw new EndOfStreamException();
            offset += n;
        }
    }
}
