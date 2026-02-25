using System.Buffers.Binary;
using System.Globalization;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace KcdMp.Client;

/// <summary>
/// Bridges a local KCD2 game instance with the central relay server.
///
/// Responsibilities:
///   1. Wait for the game to have a save loaded (GameTime > 0).
///   2. Connect to the relay server via TCP and send Handshake.
///   3. Push local player position every tick (only when changed).
///   4. Receive Ghost packets from the relay server and update the local
///      game's ghost NPCs via the game debug REST API.
/// </summary>
public partial class GameBridge(string serverHost, int serverPort, string name, string gameApiBase)
{
    private const int TickMs = 150;
    private const float PosThreshold = 0.05f;
    private const float RotThreshold = 0.02f;

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(3) };

    // Last pushed position (for change detection)
    private float _lastX, _lastY, _lastZ, _lastRotZ;
    private bool _hasPushed;

    public async Task RunAsync()
    {
        while (true)
        {
            await WaitForGameAsync();

            try
            {
                await ConnectAndRunAsync();
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[!] Unexpected error: {ex.Message}");
            }

            Console.WriteLine("Reconnecting in 3 s...");
            Console.WriteLine();
            await Task.Delay(3000);
        }
    }

    // -------------------------------------------------------------------------
    // Phase 1 – wait for a save to be loaded
    // -------------------------------------------------------------------------

    private async Task WaitForGameAsync()
    {
        Console.WriteLine("Waiting for game to load a save...");
        while (true)
        {
            try
            {
                var xml = await _http.GetStringAsync($"{gameApiBase}/api/rpg/Calendar?depth=1");
                var m = GameTimeRegex().Match(xml);
                if (m.Success && float.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out float t) && t > 0)
                {
                    Console.WriteLine("Game ready!");
                    return;
                }
            }
            catch { /* game not running yet */ }

            await Task.Delay(3000);
        }
    }

    // -------------------------------------------------------------------------
    // Phase 2 – connected to relay server
    // -------------------------------------------------------------------------

    private async Task ConnectAndRunAsync()
    {
        using var tcp = new TcpClient();

        Console.WriteLine($"Connecting to relay server {serverHost}:{serverPort}...");
        try
        {
            await tcp.ConnectAsync(serverHost, serverPort);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[!] Cannot connect: {ex.Message}");
            return;
        }

        var stream = tcp.GetStream();

        // --- Handshake ---
        var nameBytes = Encoding.UTF8.GetBytes(name);
        var handshake = new byte[3 + nameBytes.Length];
        handshake[0] = 0x00;
        handshake[1] = (byte)nameBytes.Length; // payloadLen low byte (name ≤ 255 chars)
        handshake[2] = 0x00;                   // payloadLen high byte
        nameBytes.CopyTo(handshake, 3);
        await stream.WriteAsync(handshake);

        // --- Ack (S→C  0xFF [id:1]) ---
        var ack = new byte[4]; // header(3) + id(1)
        await ReadExactAsync(stream, ack);
        byte myId = ack[3];
        Console.WriteLine($"Connected! Assigned id={myId}");
        Console.WriteLine();

        _hasPushed = false;

        // Start background receive loop (ghost updates from server)
        using var cts = new CancellationTokenSource();
        var receiveTask = ReceiveLoopAsync(stream, cts.Token);

        // --- Position push loop ---
        try
        {
            while (tcp.Connected)
            {
                var pos = await ReadPositionAsync();
                if (pos.HasValue)
                {
                    var (x, y, z, rotZ) = pos.Value;
                    if (!_hasPushed || HasChanged(x, y, z, rotZ))
                    {
                        _hasPushed = true;
                        _lastX = x; _lastY = y; _lastZ = z; _lastRotZ = rotZ;
                        await SendPositionAsync(stream, x, y, z, rotZ);
                        Console.WriteLine($"[pos] {x:F1} {y:F1} {z:F1}  rot={rotZ:F2}");
                    }
                }
                await Task.Delay(TickMs);
            }
        }
        finally
        {
            cts.Cancel();
            try { await receiveTask; } catch { }
        }
    }

    // -------------------------------------------------------------------------
    // Receive loop – server pushes Ghost packets to us
    // -------------------------------------------------------------------------

    private async Task ReceiveLoopAsync(NetworkStream stream, CancellationToken ct)
    {
        var header = new byte[3];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                await ReadExactAsync(stream, header, ct);
                int type       = header[0];
                int payloadLen = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(1));
                var payload    = new byte[payloadLen];
                await ReadExactAsync(stream, payload, ct);

                if (type == 0x02 && payloadLen == 17)
                {
                    byte ghostId = payload[0];
                    float x    = ReadFloat(payload, 1);
                    float y    = ReadFloat(payload, 5);
                    float z    = ReadFloat(payload, 9);
                    float rotZ = ReadFloat(payload, 13);
                    await UpdateGhostAsync(ghostId.ToString(), x, y, z, rotZ);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is IOException or SocketException or EndOfStreamException) { }
    }

    // -------------------------------------------------------------------------
    // Game REST API helpers
    // -------------------------------------------------------------------------

    private async Task<(float x, float y, float z, float rotZ)?> ReadPositionAsync()
    {
        try
        {
            // Position
            var xml = await _http.GetStringAsync($"{gameApiBase}/api/rpg/SoulList/PlayerSoul?depth=1");
            var posMatch = PosRegex().Match(xml);
            if (!posMatch.Success) return null;

            var parts = posMatch.Groups[1].Value.Split(',');
            if (parts.Length < 3) return null;

            float x = float.Parse(parts[0], CultureInfo.InvariantCulture);
            float y = float.Parse(parts[1], CultureInfo.InvariantCulture);
            float z = float.Parse(parts[2], CultureInfo.InvariantCulture);

            // Rotation via CVar eval trick
            float rotZ = 0;
            try
            {
                await ExecLuaAsync(@"System.SetCVar(""sv_servername"",tostring(player:GetWorldAngles().z))");
                var rotXml = await _http.GetStringAsync($"{gameApiBase}/api/System/Console/GetCvarValue?name=sv_servername");
                var rm = CvarValueRegex().Match(rotXml);
                if (rm.Success) float.TryParse(rm.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out rotZ);
            }
            catch { /* rotation read failed, use 0 */ }

            return (x, y, z, rotZ);
        }
        catch
        {
            return null;
        }
    }

    private async Task UpdateGhostAsync(string ghostId, float x, float y, float z, float rotZ)
    {
        string gx  = x.ToString("F2",  CultureInfo.InvariantCulture);
        string gy  = y.ToString("F2",  CultureInfo.InvariantCulture);
        string gz  = z.ToString("F2",  CultureInfo.InvariantCulture);
        string rot = rotZ.ToString("F4", CultureInfo.InvariantCulture);

        try
        {
            await ExecLuaAsync($@"KCD2MP_UpdateGhost(""{ghostId}"",{gx},{gy},{gz},{rot})");
            Console.WriteLine($"[ghost {ghostId}] {gx} {gy} {gz}");
        }
        catch { /* game might have unloaded */ }
    }

    private async Task ExecLuaAsync(string lua)
    {
        var cmd = Uri.EscapeDataString($"#{lua}");
        await _http.GetStringAsync($"{gameApiBase}/api/System/Console/ExecuteString?command={cmd}");
    }

    // -------------------------------------------------------------------------
    // TCP helpers
    // -------------------------------------------------------------------------

    private static async Task SendPositionAsync(NetworkStream stream, float x, float y, float z, float rotZ)
    {
        var packet = new byte[3 + 16];
        packet[0] = 0x01;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), 16);
        WriteFloat(packet, 3,  x);
        WriteFloat(packet, 7,  y);
        WriteFloat(packet, 11, z);
        WriteFloat(packet, 15, rotZ);
        await stream.WriteAsync(packet);
    }

    private static float ReadFloat(byte[] buf, int offset) =>
        BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(buf.AsSpan(offset)));

    private static void WriteFloat(byte[] buf, int offset, float value) =>
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(offset), BitConverter.SingleToInt32Bits(value));

    private static async Task ReadExactAsync(NetworkStream stream, byte[] buffer, CancellationToken ct = default)
    {
        int offset = 0;
        while (offset < buffer.Length)
        {
            int n = await stream.ReadAsync(buffer, offset, buffer.Length - offset, ct);
            if (n == 0) throw new EndOfStreamException();
            offset += n;
        }
    }

    private bool HasChanged(float x, float y, float z, float rotZ) =>
        Math.Abs(x - _lastX)       > PosThreshold ||
        Math.Abs(y - _lastY)       > PosThreshold ||
        Math.Abs(z - _lastZ)       > PosThreshold ||
        Math.Abs(rotZ - _lastRotZ) > RotThreshold;

    // -------------------------------------------------------------------------
    // Source-generated regexes
    // -------------------------------------------------------------------------

    [GeneratedRegex(@"GameTime=""([^""]+)""")]
    private static partial Regex GameTimeRegex();

    [GeneratedRegex(@"Position=""([^""]+)""")]
    private static partial Regex PosRegex();

    [GeneratedRegex(@">([^<]*)<")]
    private static partial Regex CvarValueRegex();
}
