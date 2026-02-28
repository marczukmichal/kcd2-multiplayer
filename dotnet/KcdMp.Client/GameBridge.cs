using System.Buffers.Binary;
using System.Collections.Concurrent;
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
///
/// Smoothness optimisation:
///   - Position read = 1 HTTP call (GET PlayerSoul) per TickMs.
///   - Rotation + riding state are read in a SEPARATE background loop every
///     RotStateIntervalMs (80 ms). Cached values are used by the position loop.
///     This cuts per-tick latency from ~50 ms to ~15 ms.
/// </summary>
public partial class GameBridge(string serverHost, int serverPort, string name, string gameApiBase)
{
    private const int TickMs           = 10;
    private const int RotStateIntervalMs = 80;
    private const float PosThreshold  = 0.05f;
    private const float RotThreshold  = 0.02f;

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMilliseconds(800) };

    // Last pushed position (for change detection)
    private float _lastX, _lastY, _lastZ, _lastRotZ;
    private bool _hasPushed;

    // Cached rotation + riding state updated by background loop (volatile = visible across threads)
    private volatile float _cachedRotZ = 0f;
    private volatile bool  _cachedIsRiding = false;

    // Ping: maps sent timestamp (ticks) → Stopwatch timestamp at send time
    private readonly ConcurrentDictionary<long, long> _pingsSent = new();

    // Voice: frames captured by VoiceChat are queued here, drained in main loop
    private readonly ConcurrentQueue<byte[]> _voiceQueue = new();
    private VoiceChat? _voice;

    public async Task RunAsync(CancellationToken ct = default)
    {
        while (!ct.IsCancellationRequested)
        {
            await WaitForGameAsync(ct);
            if (ct.IsCancellationRequested) break;

            try
            {
                await ConnectAndRunAsync(ct);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                Console.WriteLine($"[!] Unexpected error: {ex.Message}");
            }

            if (ct.IsCancellationRequested) break;
            Console.WriteLine("Reconnecting in 3 s...");
            Console.WriteLine();
            await Task.Delay(3000, ct).ContinueWith(_ => { });
        }
    }

    // -------------------------------------------------------------------------
    // Phase 1 – wait for a save to be loaded
    // -------------------------------------------------------------------------

    private async Task WaitForGameAsync(CancellationToken ct = default)
    {
        Console.WriteLine("Waiting for game to load a save...");
        while (!ct.IsCancellationRequested)
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

            await Task.Delay(3000, ct).ContinueWith(_ => { });
        }
    }

    // -------------------------------------------------------------------------
    // Phase 2 – connected to relay server
    // -------------------------------------------------------------------------

    private async Task ConnectAndRunAsync(CancellationToken appCt = default)
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

        // Kick off the Lua interp tick immediately so KCD2MP.isRiding gets updated
        // even before the first ghost is spawned (e.g. player already on horse at connect time).
        try { await ExecLuaAsync("if KCD2MP_StartInterp then KCD2MP_StartInterp() end"); }
        catch { /* ignore if mod not loaded yet */ }

        // Start voice chat — frames captured on background thread, queued, sent in main loop.
        _voice = new VoiceChat(frame => _voiceQueue.Enqueue(frame));
        try { _voice.Start(); }
        catch (Exception ex) { Console.WriteLine($"[voice] Failed to start: {ex.Message}"); }

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(appCt);

        // Start background tasks
        var receiveTask  = ReceiveLoopAsync(stream, cts.Token);
        var rotStateTask = RotStateLoopAsync(cts.Token);
        var pingTask     = PingLoopAsync(stream, cts.Token);

        // --- Position push loop ---
        try
        {
            int tickCount = 0;
            long totalReadMs = 0;

            while (tcp.Connected)
            {
                var sw = System.Diagnostics.Stopwatch.StartNew();
                var pos = await ReadPositionAsync();
                sw.Stop();
                totalReadMs += sw.ElapsedMilliseconds;
                tickCount++;

                if (pos.HasValue)
                {
                    var (x, y, z) = pos.Value;
                    float rotZ    = _cachedRotZ;
                    bool  riding  = _cachedIsRiding;

                    // Update voice local position and recalculate all player volumes.
                    if (_voice != null)
                    {
                        _voice.LocalPos = (x, y, z);
                        _voice.UpdateAllVolumes();
                    }

                    if (!_hasPushed || HasChanged(x, y, z, rotZ))
                    {
                        _hasPushed = true;
                        _lastX = x; _lastY = y; _lastZ = z; _lastRotZ = rotZ;
                        await SendPositionAsync(stream, x, y, z, rotZ, riding);
                        Console.WriteLine($"[pos] {x:F1} {y:F1} {z:F1}  rot={rotZ:F2}  riding={riding}  read={sw.ElapsedMilliseconds}ms");
                    }
                }

                // Drain captured voice frames and send to server.
                while (_voiceQueue.TryDequeue(out var voiceFrame))
                    await SendVoiceAsync(stream, voiceFrame);

                // Print average read time every 100 ticks
                if (tickCount % 100 == 0)
                    Console.WriteLine($"[stat] avg read={totalReadMs / tickCount}ms over {tickCount} ticks");

                await Task.Delay(TickMs);
            }
        }
        finally
        {
            cts.Cancel();
            try { await receiveTask;  } catch { }
            try { await rotStateTask; } catch { }
            try { await pingTask;     } catch { }
            _voice?.Stop();
            _voice?.Dispose();
            _voice = null;
            Console.WriteLine("Removing all ghosts...");
            try { await ExecLuaAsync("KCD2MP_RemoveAllGhosts()"); } catch { }
        }
    }

    // -------------------------------------------------------------------------
    // Background rotation + riding state loop (every RotStateIntervalMs)
    // -------------------------------------------------------------------------

    private async Task PingLoopAsync(NetworkStream stream, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(2000, ct);
                long ts = DateTime.UtcNow.Ticks;
                var tsBytes = new byte[8];
                BinaryPrimitives.WriteInt64LittleEndian(tsBytes, ts);
                _pingsSent[ts] = System.Diagnostics.Stopwatch.GetTimestamp();
                var packet = new byte[3 + 8];
                packet[0] = 0x04;
                BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), 8);
                tsBytes.CopyTo(packet, 3);
                await stream.WriteAsync(packet, ct);
            }
            catch (OperationCanceledException) { break; }
            catch { break; }
        }
    }

    private async Task RotStateLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                // Riding state is detected in the Lua interp tick (where Terrain API is
                // available) and cached in KCD2MP.isRiding. We just read that here.
                // Note: Terrain.GetElevation is NOT available in ExecuteString context.
                await ExecLuaAsync(
                    @"System.SetCVar(""sv_servername"",(function()" +
                    @"local r=player:GetWorldAngles().z;" +
                    @"local ride=KCD2MP and KCD2MP.isRiding and 'r' or 's';" +
                    @"return string.format('%.4f,%s',r,ride)end)())");

                var xml = await _http.GetStringAsync($"{gameApiBase}/api/System/Console/GetCvarValue?name=sv_servername");
                var m = CvarValueRegex().Match(xml);
                if (m.Success)
                {
                    var parts = m.Groups[1].Value.Split(',');
                    if (parts.Length >= 1 && float.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out float rot))
                        _cachedRotZ = rot;
                    if (parts.Length >= 2)
                        _cachedIsRiding = parts[1].Trim() == "r";
                }
            }
            catch { /* game might be loading, just use cached values */ }

            await Task.Delay(RotStateIntervalMs, ct);
        }
    }

    // -------------------------------------------------------------------------
    // Receive loop – server pushes Ghost and Name packets to us
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

                if (type == 0x05 && payloadLen == 8)
                {
                    long ts = BinaryPrimitives.ReadInt64LittleEndian(payload);
                    if (_pingsSent.TryRemove(ts, out long sentAt))
                    {
                        int ms = (int)((System.Diagnostics.Stopwatch.GetTimestamp() - sentAt)
                                       * 1000L / System.Diagnostics.Stopwatch.Frequency);
                        Console.WriteLine($"[ping] {ms} ms");
                        try { await ExecLuaAsync($"KCD2MP_ShowPing({ms})"); } catch { }
                    }
                }
                else if (type == 0x02 && (payloadLen == 17 || payloadLen == 18))
                {
                    // Ghost packet v1 (17): [ghostId:1][x:4f][y:4f][z:4f][rotZ:4f]
                    // Ghost packet v2 (18): [ghostId:1][x:4f][y:4f][z:4f][rotZ:4f][flags:1]
                    byte ghostId   = payload[0];
                    float x        = ReadFloat(payload, 1);
                    float y        = ReadFloat(payload, 5);
                    float z        = ReadFloat(payload, 9);
                    float rotZ     = ReadFloat(payload, 13);
                    bool  isRiding = payloadLen >= 18 && (payload[17] & 0x01) != 0;
                    _voice?.UpdateGhostPos(ghostId, x, y, z);
                    await UpdateGhostAsync(ghostId.ToString(), x, y, z, rotZ, isRiding);
                }
                else if (type == 0x03 && payloadLen >= 2)
                {
                    // Name packet: [ghostId:1][name:UTF-8...]
                    byte ghostId = payload[0];
                    string gname = Encoding.UTF8.GetString(payload, 1, payloadLen - 1);
                    await SetGhostNameAsync(ghostId.ToString(), gname);
                }
                else if (type == 0x06 && payloadLen == 1)
                {
                    // Disconnect packet: [ghostId:1]
                    byte ghostId = payload[0];
                    Console.WriteLine($"[disconnect] ghost {ghostId} removed");
                    _voice?.RemovePlayer(ghostId);
                    try { await ExecLuaAsync($"KCD2MP_RemoveGhost(\"{ghostId}\")"); } catch { }
                }
                else if (type == 0x08 && payloadLen == 641)
                {
                    // Voice packet: [sourceId:1][pcm: 640 bytes]
                    byte sourceId = payload[0];
                    var pcm = new byte[640];
                    Buffer.BlockCopy(payload, 1, pcm, 0, 640);
                    _voice?.OnVoiceReceived(sourceId, pcm);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is IOException or SocketException or EndOfStreamException) { }
    }

    // -------------------------------------------------------------------------
    // Game REST API helpers
    // -------------------------------------------------------------------------

    /// <summary>
    /// Reads local player position via a single HTTP call (GET PlayerSoul).
    /// Rotation and riding state come from the background RotStateLoopAsync.
    /// </summary>
    private async Task<(float x, float y, float z)?> ReadPositionAsync()
    {
        try
        {
            var xml = await _http.GetStringAsync($"{gameApiBase}/api/rpg/SoulList/PlayerSoul?depth=1");
            var posMatch = PosRegex().Match(xml);
            if (!posMatch.Success) return null;

            var parts = posMatch.Groups[1].Value.Split(',');
            if (parts.Length < 3) return null;

            float x = float.Parse(parts[0], CultureInfo.InvariantCulture);
            float y = float.Parse(parts[1], CultureInfo.InvariantCulture);
            float z = float.Parse(parts[2], CultureInfo.InvariantCulture);
            return (x, y, z);
        }
        catch
        {
            return null;
        }
    }

    private async Task UpdateGhostAsync(string ghostId, float x, float y, float z, float rotZ, bool isRiding)
    {
        string gx   = x.ToString("F2",  CultureInfo.InvariantCulture);
        string gy   = y.ToString("F2",  CultureInfo.InvariantCulture);
        string gz   = z.ToString("F2",  CultureInfo.InvariantCulture);
        string rot  = rotZ.ToString("F4", CultureInfo.InvariantCulture);
        string ride = isRiding ? "true" : "false";

        try
        {
            await ExecLuaAsync($@"KCD2MP_UpdateGhost(""{ghostId}"",{gx},{gy},{gz},{rot},{ride})");
            Console.WriteLine($"[ghost {ghostId}] {gx} {gy} {gz} riding={isRiding}");
        }
        catch { /* game might have unloaded */ }
    }

    private async Task SetGhostNameAsync(string ghostId, string ghostName)
    {
        // Escape any quotes in name to avoid Lua injection
        var safeName = ghostName.Replace("\\", "\\\\").Replace("\"", "\\\"");
        try
        {
            await ExecLuaAsync($@"KCD2MP_SetGhostName(""{ghostId}"",""{safeName}"")");
            Console.WriteLine($"[name] ghost {ghostId} = {ghostName}");
        }
        catch { }
    }

    private async Task ExecLuaAsync(string lua)
    {
        var cmd = Uri.EscapeDataString($"#{lua}");
        await _http.GetStringAsync($"{gameApiBase}/api/System/Console/ExecuteString?command={cmd}");
    }

    // -------------------------------------------------------------------------
    // TCP helpers
    // -------------------------------------------------------------------------

    private static async Task SendVoiceAsync(NetworkStream stream, byte[] pcm)
    {
        // 3 header + 640 payload = 643 bytes
        var packet = new byte[3 + 640];
        packet[0] = 0x07;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), 640);
        Buffer.BlockCopy(pcm, 0, packet, 3, 640);
        await stream.WriteAsync(packet);
    }

    private static async Task SendPositionAsync(NetworkStream stream, float x, float y, float z, float rotZ, bool isRiding)
    {
        // 3 header + 17 payload = 20 bytes
        var packet = new byte[3 + 17];
        packet[0] = 0x01;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), 17);
        WriteFloat(packet, 3,  x);
        WriteFloat(packet, 7,  y);
        WriteFloat(packet, 11, z);
        WriteFloat(packet, 15, rotZ);
        packet[19] = isRiding ? (byte)0x01 : (byte)0x00;
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
