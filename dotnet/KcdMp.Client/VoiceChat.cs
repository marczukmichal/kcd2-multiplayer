using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using System.Collections.Concurrent;

namespace KcdMp.Client;

/// <summary>
/// Proximity voice chat.
/// Captures microphone at 16 kHz mono 16-bit PCM, sends 20 ms frames via callback.
/// Receives frames from remote players and plays them with distance-based volume.
/// Max audible range: MAX_RANGE metres (linear falloff).
/// </summary>
public sealed class VoiceChat : IDisposable
{
    // ---- Audio constants ----
    const int   SAMPLE_RATE   = 16000;
    const int   FRAME_MS      = 20;
    const int   FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS / 1000; // 320 samples
    const int   FRAME_BYTES   = FRAME_SAMPLES * 2;              // 640 bytes (16-bit)
    const float MAX_RANGE     = 20f;   // metres – beyond this, volume = 0
    const short VAD_THRESHOLD = 400;   // 16-bit amplitude threshold (~1.2 % of max)

    private readonly WaveFormat _pcmFormat = new(SAMPLE_RATE, 16, 1);
    private readonly Action<byte[]> _onFrameCaptured; // called with raw PCM frame to send

    // Capture
    private WaveInEvent? _waveIn;
    private readonly byte[] _capBuf = new byte[FRAME_BYTES];
    private int _capPos;

    // Playback
    private WaveOutEvent?          _waveOut;
    private MixingSampleProvider?  _mixer;

    // Per-player state (keyed by ghostId byte)
    private readonly ConcurrentDictionary<byte, BufferedWaveProvider> _buffers = new();
    private readonly ConcurrentDictionary<byte, VolumeSampleProvider> _volumes = new();

    // Positions (updated from outside)
    private readonly ConcurrentDictionary<byte, (float x, float y, float z)> _ghostPos = new();
    public (float x, float y, float z) LocalPos { get; set; }

    public bool Muted { get; set; } = false;
    private volatile bool _running;

    public VoiceChat(Action<byte[]> onFrameCaptured)
    {
        _onFrameCaptured = onFrameCaptured;
    }

    // -------------------------------------------------------------------------
    // Start / Stop
    // -------------------------------------------------------------------------

    public void Start()
    {
        if (_running) return;
        _running = true;

        // Playback: float mixer → WaveOut
        var floatFormat = WaveFormat.CreateIeeeFloatWaveFormat(SAMPLE_RATE, 1);
        _mixer   = new MixingSampleProvider(floatFormat) { ReadFully = true };
        _waveOut = new WaveOutEvent { DesiredLatency = 80 };
        _waveOut.Init(_mixer);
        _waveOut.Play();

        // Capture: 16-bit PCM → buffer → VAD → frame callback
        _waveIn = new WaveInEvent { WaveFormat = _pcmFormat, BufferMilliseconds = FRAME_MS };
        _waveIn.DataAvailable += OnCaptureData;
        _waveIn.StartRecording();

        Console.WriteLine($"[voice] Started  16kHz mono PCM  frame={FRAME_BYTES}B  range={MAX_RANGE}m");
    }

    public void Stop()
    {
        if (!_running) return;
        _running = false;
        try { _waveIn?.StopRecording(); } catch { }
        try { _waveOut?.Stop(); }         catch { }
    }

    public void Dispose()
    {
        Stop();
        _waveIn?.Dispose();
        _waveOut?.Dispose();
    }

    // -------------------------------------------------------------------------
    // Capture
    // -------------------------------------------------------------------------

    private void OnCaptureData(object? sender, WaveInEventArgs e)
    {
        if (!_running || Muted) return;

        int src = 0;
        while (src < e.BytesRecorded)
        {
            int toCopy = Math.Min(FRAME_BYTES - _capPos, e.BytesRecorded - src);
            Buffer.BlockCopy(e.Buffer, src, _capBuf, _capPos, toCopy);
            _capPos += toCopy;
            src     += toCopy;

            if (_capPos >= FRAME_BYTES)
            {
                if (HasVoice(_capBuf))
                {
                    var frame = new byte[FRAME_BYTES];
                    Buffer.BlockCopy(_capBuf, 0, frame, 0, FRAME_BYTES);
                    _onFrameCaptured(frame);
                }
                _capPos = 0;
            }
        }
    }

    private static bool HasVoice(byte[] pcm)
    {
        for (int i = 0; i < pcm.Length - 1; i += 2)
        {
            short s = (short)(pcm[i] | (pcm[i + 1] << 8));
            if (s > VAD_THRESHOLD || s < -VAD_THRESHOLD) return true;
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // Playback
    // -------------------------------------------------------------------------

    /// <summary>Called when a voice frame arrives from a remote player.</summary>
    public void OnVoiceReceived(byte sourceId, byte[] pcm)
    {
        if (!_running) return;

        // Create playback pipeline for this player on first packet.
        if (!_buffers.ContainsKey(sourceId))
        {
            var buf = new BufferedWaveProvider(_pcmFormat)
            {
                DiscardOnBufferOverflow = true,
                BufferDuration = TimeSpan.FromMilliseconds(400),
            };
            var vol = new VolumeSampleProvider(buf.ToSampleProvider()) { Volume = 1f };

            if (_buffers.TryAdd(sourceId, buf) && _volumes.TryAdd(sourceId, vol))
                _mixer!.AddMixerInput(vol);
        }

        if (_buffers.TryGetValue(sourceId, out var buffer))
            buffer.AddSamples(pcm, 0, pcm.Length);

        ApplyVolume(sourceId);
    }

    /// <summary>Update the 3D position of a remote player's ghost for proximity volume.</summary>
    public void UpdateGhostPos(byte ghostId, float x, float y, float z)
    {
        _ghostPos[ghostId] = (x, y, z);
        ApplyVolume(ghostId);
    }

    /// <summary>Remove a player — silence and discard their audio pipeline.</summary>
    public void RemovePlayer(byte ghostId)
    {
        _ghostPos.TryRemove(ghostId, out _);
        if (_volumes.TryRemove(ghostId, out var vol))
            vol.Volume = 0f;
        _buffers.TryRemove(ghostId, out _);
    }

    /// <summary>Recalculate volume for all players — call when local position changes.</summary>
    public void UpdateAllVolumes()
    {
        foreach (var id in _volumes.Keys)
            ApplyVolume(id);
    }

    private void ApplyVolume(byte ghostId)
    {
        if (!_volumes.TryGetValue(ghostId, out var vol)) return;

        if (!_ghostPos.TryGetValue(ghostId, out var gp))
        {
            vol.Volume = 1f;
            return;
        }

        var lp     = LocalPos;
        float dx   = gp.x - lp.x;
        float dy   = gp.y - lp.y;
        float dist = MathF.Sqrt(dx * dx + dy * dy);
        // Linear falloff: 100% at 0m, 0% at MAX_RANGE
        vol.Volume = Math.Max(0f, 1f - dist / MAX_RANGE);
    }
}
