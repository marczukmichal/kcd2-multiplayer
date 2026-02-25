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
/// C→S  0x01  Position:   [x:4f][y:4f][z:4f][rotZ:4f]   (16 bytes, LE IEEE-754)
/// S→C  0xFF  Ack:        [assignedId:1]
/// S→C  0x02  Ghost:      [ghostId:1][x:4f][y:4f][z:4f][rotZ:4f]  (17 bytes)
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

            // --- Position receive loop ---
            var posPayload = new byte[16];
            while (true)
            {
                await ReadExactAsync(header);
                int type = header[0];
                int payloadLen = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(1));

                if (type != 0x01 || payloadLen != 16)
                {
                    // Skip unknown/malformed packet
                    if (payloadLen > 0)
                    {
                        var skip = new byte[payloadLen];
                        await ReadExactAsync(skip);
                    }
                    continue;
                }

                await ReadExactAsync(posPayload);

                float x    = ReadFloat(posPayload, 0);
                float y    = ReadFloat(posPayload, 4);
                float z    = ReadFloat(posPayload, 8);
                float rotZ = ReadFloat(posPayload, 12);

                _server.Broadcast(this, x, y, z, rotZ);
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
    public void EnqueueGhost(byte ghostId, float x, float y, float z, float rotZ)
    {
        var payload = new byte[17];
        payload[0] = ghostId;
        WriteFloat(payload, 1, x);
        WriteFloat(payload, 5, y);
        WriteFloat(payload, 9, z);
        WriteFloat(payload, 13, rotZ);
        EnqueueRaw(BuildPacket(0x02, payload));
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

    private async Task ReadExactAsync(byte[] buffer)
    {
        int offset = 0;
        while (offset < buffer.Length)
        {
            int n = await _stream.ReadAsync(buffer, offset, buffer.Length - offset);
            if (n == 0) throw new EndOfStreamException();
            offset += n;
        }
    }
}
