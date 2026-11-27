using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using Hermes.Core.Voice;
using HermesHQ.Services;
using Microsoft.UI.Windowing;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechRecognition;

namespace HermesHQ.Features.Voice;

/// Real Windows audio capture, playback, live speech recognition, device enumeration,
/// folder protection, and system audio events for Voice Memos, Dictation, and Talk.
/// Uses Win32 `winmm.dll` waveIn/waveOut P/Invoke (safe marshaling, no `unsafe` blocks)
/// for low-latency PCM capture/streaming and WinRT `MediaPlayer` for multi-format playback.
public static class WindowsVoiceAudio
{
    public static IMemoAudioInput MemoInput { get; } = new WindowsMemoAudioInput();
    public static IMemoAudioOutput MemoOutput { get; } = new WindowsMemoAudioOutput();
    public static WindowsMemoSystemEvents SystemEvents { get; } = new();
    public static IMemoFolderGuard FolderGuard { get; } = new WindowsMemoFolderGuard();

    public static IDictationCapturing CreateDictationCapture() => new WindowsDictationCapture();
    public static ITalkCapturing CreateTalkCapture() => new WindowsTalkCapture();
    public static ITalkSpeaker CreateTalkSpeaker() => new WindowsTalkSpeaker();
    public static ILiveVoiceTransport CreateLiveTransport() => new WindowsLiveVoiceTransport();
    public static ILiveWordsListening CreateLiveWords() => new WindowsLiveWordsEngine();

    public static IReadOnlyList<TalkAudioRoute> ListOutputRoutes() => WindowsAudioDevices.ListOutputs();
    public static IReadOnlyList<TalkAudioRoute> ListInputRoutes() => WindowsAudioDevices.ListInputs();

    public static bool IsWindowActive() => App.Window is { } w && w.AppWindow.IsVisible
        && w.AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Minimized };
}

// MARK: - Win32 winmm.dll P/Invoke (100% safe C#, compiles cleanly in CompileCheck and WinAppSDK 1.8)

internal static class WinMm
{
    public const uint WaveMapper = unchecked((uint)-1);
    public const uint CallbackFunction = 0x00030000;
    public const ushort WaveFormatPcm = 1;
    public const uint WimData = 0x3C0;
    public const uint WhdrDone = 0x00000001;
    public const uint WhdrPrepared = 0x00000002;
    public const uint MmsysErrNoError = 0;
    public const uint MmsysErrAllocated = 4;
    public const uint MmsysErrBadDeviceId = 2;
    public const uint MmsysErrNoDriver = 6;

    public delegate void WaveInProc(IntPtr hwi, uint uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2);

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct WaveFormatEx
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WaveHdr
    {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public IntPtr lpNext;
        public IntPtr reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WaveInCapsW
    {
        public ushort wMid;
        public ushort wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szPname;
        public uint dwFormats;
        public ushort wChannels;
        public ushort wReserved1;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WaveOutCapsW
    {
        public ushort wMid;
        public ushort wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szPname;
        public uint dwFormats;
        public ushort wChannels;
        public ushort wReserved1;
        public uint dwSupport;
    }

    public static WaveFormatEx CreatePcmFormat(int sampleRate, int channels = 1, int bitsPerSample = 16)
    {
        var blockAlign = (ushort)(channels * (bitsPerSample / 8));
        return new WaveFormatEx
        {
            wFormatTag = WaveFormatPcm,
            nChannels = (ushort)channels,
            nSamplesPerSec = (uint)sampleRate,
            nAvgBytesPerSec = (uint)(sampleRate * blockAlign),
            nBlockAlign = blockAlign,
            wBitsPerSample = (ushort)bitsPerSample,
            cbSize = 0,
        };
    }

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveInGetNumDevs();

    [DllImport("winmm.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    public static extern uint waveInGetDevCapsW(UIntPtr uDeviceID, out WaveInCapsW pwic, uint cbwic);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveInOpen(out IntPtr phwi, uint uDeviceID, ref WaveFormatEx pwfx,
        WaveInProc dwCallback, IntPtr dwInstance, uint fdwOpen);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveInPrepareHeader(IntPtr hwi, IntPtr pwh, uint cbwh);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveInUnprepareHeader(IntPtr hwi, IntPtr pwh, uint cbwh);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveInAddBuffer(IntPtr hwi, IntPtr pwh, uint cbwh);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveInStart(IntPtr hwi);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveInStop(IntPtr hwi);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveInReset(IntPtr hwi);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveInClose(IntPtr hwi);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveOutGetNumDevs();

    [DllImport("winmm.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    public static extern uint waveOutGetDevCapsW(UIntPtr uDeviceID, out WaveOutCapsW pwoc, uint cbwoc);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveOutOpen(out IntPtr phwo, uint uDeviceID, ref WaveFormatEx pwfx,
        IntPtr dwCallback, IntPtr dwInstance, uint fdwOpen);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveOutPrepareHeader(IntPtr hwo, IntPtr pwh, uint cbwh);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveOutUnprepareHeader(IntPtr hwo, IntPtr pwh, uint cbwh);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveOutWrite(IntPtr hwo, IntPtr pwh, uint cbwh);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveOutReset(IntPtr hwo);

    [DllImport("winmm.dll", ExactSpelling = true)]
    public static extern uint waveOutClose(IntPtr hwo);

    public static Exception ToException(uint mmResult, string what)
    {
        if (mmResult == MmsysErrAllocated)
            return new InvalidOperationException($"The microphone is busy ({what}).") { HResult = unchecked((int)0x8889000A) };
        if (mmResult is MmsysErrBadDeviceId or MmsysErrNoDriver)
            return new InvalidOperationException($"No audio device is available ({what}).");
        return new InvalidOperationException($"Windows audio error {mmResult} ({what}).");
    }
}

// MARK: - Device enumeration

internal static class WindowsAudioDevices
{
    public static IReadOnlyList<TalkAudioRoute> ListOutputs()
    {
        var list = new List<TalkAudioRoute>
        {
            new("default", "System Default", TalkRouteKind.Speaker, IsActive: true, IsDefault: true),
        };
        try
        {
            var count = WinMm.waveOutGetNumDevs();
            var size = (uint)Marshal.SizeOf<WinMm.WaveOutCapsW>();
            for (uint i = 0; i < count; i++)
            {
                if (WinMm.waveOutGetDevCapsW((UIntPtr)i, out var caps, size) == WinMm.MmsysErrNoError
                    && !string.IsNullOrWhiteSpace(caps.szPname))
                {
                    var name = caps.szPname.Trim();
                    list.Add(new TalkAudioRoute($"out-{i}", name, GuessKind(name), IsActive: false));
                }
            }
        }
        catch (Exception ex)
        {
            AppLog.Note("voice", $"waveOut enumeration failed: {ex.GetType().Name}");
        }
        return list;
    }

    public static IReadOnlyList<TalkAudioRoute> ListInputs()
    {
        var list = new List<TalkAudioRoute>();
        try
        {
            var count = WinMm.waveInGetNumDevs();
            var size = (uint)Marshal.SizeOf<WinMm.WaveInCapsW>();
            for (uint i = 0; i < count; i++)
            {
                if (WinMm.waveInGetDevCapsW((UIntPtr)i, out var caps, size) == WinMm.MmsysErrNoError
                    && !string.IsNullOrWhiteSpace(caps.szPname))
                {
                    var name = caps.szPname.Trim();
                    list.Add(new TalkAudioRoute($"in-{i}", name, GuessKind(name), IsActive: i == 0, IsDefault: i == 0));
                }
            }
        }
        catch (Exception ex)
        {
            AppLog.Note("voice", $"waveIn enumeration failed: {ex.GetType().Name}");
        }
        return list;
    }

    private static TalkRouteKind GuessKind(string name)
    {
        var lower = name.ToLowerInvariant();
        if (lower.Contains("bluetooth") || lower.Contains("airpods") || lower.Contains("buds") || lower.Contains("hands-free"))
            return TalkRouteKind.Bluetooth;
        if (lower.Contains("headphone") || lower.Contains("headset") || lower.Contains("earphone"))
            return TalkRouteKind.Headphones;
        if (lower.Contains("usb"))
            return TalkRouteKind.Usb;
        return TalkRouteKind.Speaker;
    }
}

// MARK: - Low-level WinMM waveIn PCM capture loop (never calls winmm inside callback)

internal sealed class WinMmWaveInCapture : IDisposable
{
    private const int BufferCount = 4;

    private readonly int _sampleRate;
    private readonly int _chunkSamples;
    private readonly Action<short[], byte[]> _onBuffer;
    private readonly Action<Exception>? _onError;
    private readonly WinMm.WaveInProc _callback; // pinned reference for lifetime of device

    private readonly object _gate = new();
    private IntPtr _handle;
    private byte[][] _buffers = [];
    private GCHandle[] _pins = [];
    private IntPtr[] _headers = [];
    private BlockingCollection<int>? _readyQueue;
    private Thread? _worker;
    private volatile bool _running;
    private bool _disposed;

    public WinMmWaveInCapture(int sampleRate, int chunkMs, Action<short[], byte[]> onBuffer, Action<Exception>? onError = null)
    {
        _sampleRate = sampleRate;
        _chunkSamples = Math.Max(160, sampleRate * chunkMs / 1000);
        _onBuffer = onBuffer;
        _onError = onError;
        _callback = WaveInCallback;
    }

    public void Start()
    {
        lock (_gate)
        {
            if (_running || _disposed) return;
            var format = WinMm.CreatePcmFormat(_sampleRate, channels: 1, bitsPerSample: 16);
            var openRes = WinMm.waveInOpen(out var handle, WinMm.WaveMapper, ref format, _callback, IntPtr.Zero, WinMm.CallbackFunction);
            if (openRes != WinMm.MmsysErrNoError) throw WinMm.ToException(openRes, "waveInOpen");

            _handle = handle;
            var byteLen = _chunkSamples * sizeof(short);
            var hdrSize = (uint)Marshal.SizeOf<WinMm.WaveHdr>();
            _buffers = new byte[BufferCount][];
            _pins = new GCHandle[BufferCount];
            _headers = new IntPtr[BufferCount];
            _readyQueue = new BlockingCollection<int>(BufferCount * 4);

            try
            {
                for (var i = 0; i < BufferCount; i++)
                {
                    _buffers[i] = new byte[byteLen];
                    _pins[i] = GCHandle.Alloc(_buffers[i], GCHandleType.Pinned);
                    var hdrPtr = Marshal.AllocHGlobal((int)hdrSize);
                    _headers[i] = hdrPtr;
                    var hdr = new WinMm.WaveHdr
                    {
                        lpData = _pins[i].AddrOfPinnedObject(),
                        dwBufferLength = (uint)byteLen,
                        dwUser = (IntPtr)i,
                    };
                    Marshal.StructureToPtr(hdr, hdrPtr, false);
                    var prep = WinMm.waveInPrepareHeader(_handle, hdrPtr, hdrSize);
                    if (prep != WinMm.MmsysErrNoError) throw WinMm.ToException(prep, "waveInPrepareHeader");
                    var add = WinMm.waveInAddBuffer(_handle, hdrPtr, hdrSize);
                    if (add != WinMm.MmsysErrNoError) throw WinMm.ToException(add, "waveInAddBuffer");
                }
                _running = true;
                _worker = new Thread(PumpLoop) { IsBackground = true, Name = "HermesWaveIn" };
                _worker.Start();
                var startRes = WinMm.waveInStart(_handle);
                if (startRes != WinMm.MmsysErrNoError) throw WinMm.ToException(startRes, "waveInStart");
            }
            catch
            {
                StopLocked();
                throw;
            }
        }
    }

    private void WaveInCallback(IntPtr hwi, uint uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2)
    {
        if (uMsg != WinMm.WimData || !_running || dwParam1 == IntPtr.Zero) return;
        try
        {
            var hdr = Marshal.PtrToStructure<WinMm.WaveHdr>(dwParam1);
            var index = (int)hdr.dwUser;
            _readyQueue?.TryAdd(index);
        }
        catch (Exception) { }
    }

    private void PumpLoop()
    {
        var queue = _readyQueue;
        if (queue == null) return;
        var hdrSize = (uint)Marshal.SizeOf<WinMm.WaveHdr>();
        try
        {
            foreach (var index in queue.GetConsumingEnumerable())
            {
                if (!_running) break;
                if (index < 0 || index >= _headers.Length) continue;
                var hdrPtr = _headers[index];
                if (hdrPtr == IntPtr.Zero) continue;
                var hdr = Marshal.PtrToStructure<WinMm.WaveHdr>(hdrPtr);
                var recorded = (int)Math.Min(hdr.dwBytesRecorded, (uint)_buffers[index].Length);
                if (recorded >= 2)
                {
                    var bytes = new byte[recorded];
                    Buffer.BlockCopy(_buffers[index], 0, bytes, 0, recorded);
                    var samples = new short[recorded / 2];
                    Buffer.BlockCopy(bytes, 0, samples, 0, samples.Length * 2);
                    _onBuffer(samples, bytes);
                }
                if (_running && _handle != IntPtr.Zero)
                {
                    var res = WinMm.waveInAddBuffer(_handle, hdrPtr, hdrSize);
                    if (res != WinMm.MmsysErrNoError && _running)
                    {
                        _onError?.Invoke(WinMm.ToException(res, "waveInAddBuffer"));
                        break;
                    }
                }
            }
        }
        catch (Exception ex) when (_running)
        {
            _onError?.Invoke(ex);
        }
    }

    public void Stop()
    {
        Thread? worker;
        IntPtr handle;
        lock (_gate)
        {
            _running = false;
            try { _readyQueue?.CompleteAdding(); } catch (ObjectDisposedException) { }
            handle = _handle;
            _handle = IntPtr.Zero;
            worker = _worker;
            _worker = null;
        }
        // Halt WinMM callbacks and join the pump thread BEFORE freeing unmanaged WaveHdrs, GCHandles, or the queue.
        if (handle != IntPtr.Zero)
        {
            try { WinMm.waveInStop(handle); } catch (Exception) { }
            try { WinMm.waveInReset(handle); } catch (Exception) { }
        }
        if (worker != null && worker != Thread.CurrentThread)
        {
            try { worker.Join(2000); } catch (Exception) { }
        }
        lock (_gate)
        {
            ReleaseResourcesLocked(handle);
        }
    }

    private void StopLocked()
    {
        _running = false;
        try { _readyQueue?.CompleteAdding(); } catch (ObjectDisposedException) { }
        var handle = _handle;
        _handle = IntPtr.Zero;
        var worker = _worker;
        _worker = null;
        if (handle != IntPtr.Zero)
        {
            try { WinMm.waveInStop(handle); } catch (Exception) { }
            try { WinMm.waveInReset(handle); } catch (Exception) { }
        }
        if (worker != null && worker != Thread.CurrentThread)
        {
            try { worker.Join(2000); } catch (Exception) { }
        }
        ReleaseResourcesLocked(handle);
    }

    private void ReleaseResourcesLocked(IntPtr handle)
    {
        var hdrSize = (uint)Marshal.SizeOf<WinMm.WaveHdr>();
        for (var i = 0; i < _headers.Length; i++)
        {
            if (_headers[i] != IntPtr.Zero)
            {
                if (handle != IntPtr.Zero)
                    try { WinMm.waveInUnprepareHeader(handle, _headers[i], hdrSize); } catch (Exception) { }
                Marshal.FreeHGlobal(_headers[i]);
                _headers[i] = IntPtr.Zero;
            }
        }
        if (handle != IntPtr.Zero)
        {
            try { WinMm.waveInClose(handle); } catch (Exception) { }
        }
        for (var i = 0; i < _pins.Length; i++)
        {
            if (_pins[i].IsAllocated) _pins[i].Free();
        }
        _headers = [];
        _pins = [];
        _buffers = [];
        _readyQueue?.Dispose();
        _readyQueue = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
    }
}

// MARK: - Low-level WinMM waveOut PCM streaming player (24 kHz live voice & connected chime)

internal sealed class WinMmWaveOutPlayer : IDisposable
{
    private readonly int _sampleRate;
    private readonly int _channels;
    private readonly object _gate = new();
    private readonly List<(IntPtr Header, GCHandle Pin)> _inFlight = [];
    private IntPtr _handle;
    private bool _disposed;

    public WinMmWaveOutPlayer(int sampleRate = 24000, int channels = 1)
    {
        _sampleRate = sampleRate;
        _channels = channels;
    }

    public void Write(byte[] pcmBytes)
    {
        if (pcmBytes.Length == 0 || _disposed) return;
        lock (_gate)
        {
            if (_disposed) return;
            EnsureOpenLocked();
            ReclaimDoneLocked();
            var pin = GCHandle.Alloc(pcmBytes, GCHandleType.Pinned);
            var hdrSize = (uint)Marshal.SizeOf<WinMm.WaveHdr>();
            var hdrPtr = Marshal.AllocHGlobal((int)hdrSize);
            var hdr = new WinMm.WaveHdr
            {
                lpData = pin.AddrOfPinnedObject(),
                dwBufferLength = (uint)pcmBytes.Length,
            };
            Marshal.StructureToPtr(hdr, hdrPtr, false);
            var prep = WinMm.waveOutPrepareHeader(_handle, hdrPtr, hdrSize);
            if (prep != WinMm.MmsysErrNoError)
            {
                Marshal.FreeHGlobal(hdrPtr);
                pin.Free();
                return;
            }
            var write = WinMm.waveOutWrite(_handle, hdrPtr, hdrSize);
            if (write != WinMm.MmsysErrNoError)
            {
                WinMm.waveOutUnprepareHeader(_handle, hdrPtr, hdrSize);
                Marshal.FreeHGlobal(hdrPtr);
                pin.Free();
                return;
            }
            _inFlight.Add((hdrPtr, pin));
        }
    }

    public void Flush()
    {
        lock (_gate)
        {
            if (_handle == IntPtr.Zero) return;
            try { WinMm.waveOutReset(_handle); } catch (Exception) { }
            ReleaseAllLocked();
        }
    }

    private void EnsureOpenLocked()
    {
        if (_handle != IntPtr.Zero) return;
        var format = WinMm.CreatePcmFormat(_sampleRate, _channels, 16);
        var res = WinMm.waveOutOpen(out var handle, WinMm.WaveMapper, ref format, IntPtr.Zero, IntPtr.Zero, 0);
        if (res != WinMm.MmsysErrNoError) throw WinMm.ToException(res, "waveOutOpen");
        _handle = handle;
    }

    private void ReclaimDoneLocked()
    {
        if (_handle == IntPtr.Zero || _inFlight.Count == 0) return;
        var hdrSize = (uint)Marshal.SizeOf<WinMm.WaveHdr>();
        for (var i = _inFlight.Count - 1; i >= 0; i--)
        {
            var (hdrPtr, pin) = _inFlight[i];
            var hdr = Marshal.PtrToStructure<WinMm.WaveHdr>(hdrPtr);
            if ((hdr.dwFlags & WinMm.WhdrDone) != 0)
            {
                WinMm.waveOutUnprepareHeader(_handle, hdrPtr, hdrSize);
                Marshal.FreeHGlobal(hdrPtr);
                if (pin.IsAllocated) pin.Free();
                _inFlight.RemoveAt(i);
            }
        }
    }

    private void ReleaseAllLocked()
    {
        var hdrSize = (uint)Marshal.SizeOf<WinMm.WaveHdr>();
        foreach (var (hdrPtr, pin) in _inFlight)
        {
            if (_handle != IntPtr.Zero)
                try { WinMm.waveOutUnprepareHeader(_handle, hdrPtr, hdrSize); } catch (Exception) { }
            Marshal.FreeHGlobal(hdrPtr);
            if (pin.IsAllocated) pin.Free();
        }
        _inFlight.Clear();
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            if (_handle != IntPtr.Zero)
            {
                try { WinMm.waveOutReset(_handle); } catch (Exception) { }
                ReleaseAllLocked();
                try { WinMm.waveOutClose(_handle); } catch (Exception) { }
                _handle = IntPtr.Zero;
            }
        }
    }
}

// MARK: - Voice Memo Recorder (IMemoAudioInput + IMemoAudioFormat -> 24 kHz 16-bit mono WAV)

public sealed class WindowsMemoAudioInput : IMemoAudioInput, IMemoAudioFormat
{
    public string Mime => "audio/wav";
    public string Extension => "wav";

    public MemoMicPermission Permission
    {
        get
        {
            try { return WinMm.waveInGetNumDevs() > 0 ? MemoMicPermission.Granted : MemoMicPermission.Denied; }
            catch (Exception) { return MemoMicPermission.Granted; }
        }
    }

    public Task<bool> RequestPermissionAsync() => Task.FromResult(Permission == MemoMicPermission.Granted);

    public IMemoAudioTake Create(string file) => new WindowsMemoAudioTake(file);
}

internal sealed class WindowsMemoAudioTake : IMemoAudioTake
{
    private readonly string _file;
    private readonly object _gate = new();
    private FileStream? _stream;
    private WinMmWaveInCapture? _capture;
    private Timer? _limitTimer;
    private int _dataBytes;
    private float _powerDb = -160f;
    private bool _stopped;

    public WindowsMemoAudioTake(string file) => _file = file;

    public event Action<IMemoAudioTake, bool>? Finished;
    public event Action<IMemoAudioTake>? EncodeError;

    public bool Prepare()
    {
        lock (_gate)
        {
            if (_stopped) return false;
            try
            {
                var dir = Path.GetDirectoryName(_file);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                _stream?.Dispose();
                _stream = new FileStream(_file, FileMode.Create, FileAccess.ReadWrite, FileShare.Read);
                TalkWave.WriteWavHeader(_stream, MemoRecorder.SampleRate, MemoRecorder.Channels, 16, 0);
                _dataBytes = 0;
                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }
    }

    public bool Record(double seconds)
    {
        lock (_gate)
        {
            if (_stopped) return false;
            if (_stream == null && !Prepare()) return false;
            try
            {
                _capture?.Dispose();
                _capture = new WinMmWaveInCapture(MemoRecorder.SampleRate, 50, OnPcm, OnCaptureError);
                _capture.Start();
                if (seconds > 0 && double.IsFinite(seconds))
                {
                    _limitTimer?.Dispose();
                    _limitTimer = new Timer(_ => OnLimitReached(), null, TimeSpan.FromSeconds(seconds), Timeout.InfiniteTimeSpan);
                }
                return true;
            }
            catch (Exception ex)
            {
                AppLog.Note("memo", $"waveIn start failed: {ex.Message}");
                return false;
            }
        }
    }

    public float AveragePower() => Volatile.Read(ref _powerDb);

    public void Stop()
    {
        WinMmWaveInCapture? cap;
        lock (_gate)
        {
            if (_stopped) return;
            _stopped = true;
            _limitTimer?.Dispose();
            _limitTimer = null;
            cap = _capture;
            _capture = null;
        }
        cap?.Dispose();
        lock (_gate)
        {
            FinalizeFileLocked();
        }
    }

    private void OnPcm(short[] samples, byte[] bytes)
    {
        var db = (float)TalkLevel.Db(TalkLevel.Rms(samples));
        Volatile.Write(ref _powerDb, db);
        lock (_gate)
        {
            if (_stopped || _stream == null) return;
            try
            {
                _stream.Write(bytes, 0, bytes.Length);
                _dataBytes += bytes.Length;
            }
            catch (Exception)
            {
                _stopped = true;
                EncodeError?.Invoke(this);
            }
        }
    }

    private void OnCaptureError(Exception ex)
    {
        AppLog.Note("memo", $"capture error: {ex.Message}");
        Stop();
        EncodeError?.Invoke(this);
    }

    private void OnLimitReached()
    {
        Stop();
        Finished?.Invoke(this, true);
    }

    private void FinalizeFileLocked()
    {
        if (_stream == null) return;
        try { TalkWave.PatchWavHeader(_stream, _dataBytes); }
        catch (Exception) { }
        finally
        {
            _stream.Dispose();
            _stream = null;
        }
    }
}

// MARK: - Voice Memo Playback (IMemoAudioOutput + IMemoAudioTrack over WinRT MediaPlayer)

public sealed class WindowsMemoAudioOutput : IMemoAudioOutput
{
    public async Task<IMemoAudioTrack> OpenAsync(string file)
    {
        if (!File.Exists(file)) throw new FileNotFoundException("Audio file not found.", file);
        var track = new WindowsMemoAudioTrack(file);
        await track.OpenAsync();
        return track;
    }
}

internal sealed class WindowsMemoAudioTrack : IMemoAudioTrack
{
    private readonly string _file;
    private readonly MediaPlayer _player;
    private double _duration;
    private double _rate = 1.0;
    private bool _disposed;

    public WindowsMemoAudioTrack(string file)
    {
        _file = file;
        _player = new MediaPlayer
        {
            AudioCategory = MediaPlayerAudioCategory.Speech,
            AutoPlay = false,
        };
        _player.MediaEnded += OnMediaEnded;
        _player.MediaFailed += OnMediaFailed;
    }

    public event Action<IMemoAudioTrack, bool>? Finished;
    public event Action<IMemoAudioTrack>? DecodeError;

    public double Duration
    {
        get
        {
            if (_disposed) return _duration;
            var natural = _player.PlaybackSession.NaturalDuration.TotalSeconds;
            if (natural > 0 && double.IsFinite(natural)) _duration = natural;
            return _duration;
        }
    }

    public double CurrentTime
    {
        get => _disposed ? 0 : _player.PlaybackSession.Position.TotalSeconds;
        set
        {
            if (_disposed) return;
            var clamped = Math.Max(0, Duration > 0 ? Math.Min(value, Duration) : value);
            _player.PlaybackSession.Position = TimeSpan.FromSeconds(clamped);
        }
    }

    public double Rate
    {
        get => _rate;
        set
        {
            _rate = Math.Clamp(value, 0.5, 4.0);
            if (!_disposed) _player.PlaybackSession.PlaybackRate = _rate;
        }
    }

    public async Task OpenAsync()
    {
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Opened(MediaPlayer _, object __) => tcs.TrySetResult();
        void Failed(MediaPlayer _, MediaPlayerFailedEventArgs e) =>
            tcs.TrySetException(new InvalidDataException(string.IsNullOrEmpty(e.ErrorMessage) ? "Audio failed to open." : e.ErrorMessage));

        _player.MediaOpened += Opened;
        _player.MediaFailed += Failed;
        try
        {
            _player.Source = MediaSource.CreateFromUri(new Uri(_file));
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            using (cts.Token.Register(() => tcs.TrySetException(new TimeoutException("Timed out opening audio file."))))
                await tcs.Task;
            var natural = _player.PlaybackSession.NaturalDuration.TotalSeconds;
            if (natural > 0 && double.IsFinite(natural)) _duration = natural;
        }
        catch
        {
            Stop();
            throw;
        }
        finally
        {
            if (!_disposed)
            {
                _player.MediaOpened -= Opened;
                _player.MediaFailed -= Failed;
            }
        }
    }

    public bool Play()
    {
        if (_disposed) return false;
        try
        {
            _player.PlaybackSession.PlaybackRate = _rate;
            _player.Play();
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public void Pause()
    {
        if (!_disposed) _player.Pause();
    }

    public void Stop()
    {
        if (_disposed) return;
        _disposed = true;
        _player.MediaEnded -= OnMediaEnded;
        _player.MediaFailed -= OnMediaFailed;
        try
        {
            _player.Pause();
            _player.Source = null;
            _player.Dispose();
        }
        catch (Exception) { }
    }

    private void OnMediaEnded(MediaPlayer sender, object args) => Finished?.Invoke(this, true);
    private void OnMediaFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args) => DecodeError?.Invoke(this);
}

// MARK: - Folder Guard & System Events

public sealed class WindowsMemoFolderGuard : IMemoFolderGuard
{
    public void Protect(string folder)
    {
        try
        {
            if (!Directory.Exists(folder)) return;
            var attrs = File.GetAttributes(folder);
            if ((attrs & FileAttributes.NotContentIndexed) == 0)
                File.SetAttributes(folder, attrs | FileAttributes.NotContentIndexed);
        }
        catch (Exception) { }
    }
}

public sealed class WindowsMemoSystemEvents : IMemoSystemEvents
{
    public event Action<MemoSystemEvent>? Raised;

    public void Raise(MemoSystemEvent ev) => Raised?.Invoke(ev);
}

// MARK: - Windows Dictation Capture (16 kHz mono WAV + live PCM tap)

internal sealed class WindowsDictationCapture : IDictationCapturing
{
    public int SampleRate => 16000;

    public MemoMicPermission Permission
    {
        get
        {
            try { return WinMm.waveInGetNumDevs() > 0 ? MemoMicPermission.Granted : MemoMicPermission.Denied; }
            catch (Exception) { return MemoMicPermission.Granted; }
        }
    }

    public Task<bool> RequestPermissionAsync() => Task.FromResult(Permission == MemoMicPermission.Granted);

    public event Action<double, double>? LevelChanged;
    public event Action<short[]>? PcmCaptured;
    public event Action<DictationCaptureError, string>? Interrupted;

    private readonly object _gate = new();
    private WinMmWaveInCapture? _capture;
    private FileStream? _stream;
    private string? _file;
    private int _dataBytes;
    private double _limit;
    private DateTimeOffset _started;

    public Task StartAsync(double limitSeconds, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        lock (_gate)
        {
            if (_capture != null) throw new DictationCaptureException(DictationCaptureError.Busy, "Dictation is already running.");
            _limit = Math.Max(10, limitSeconds);
            _file = Path.Combine(Path.GetTempPath(), $"hermes-dictation-{Guid.NewGuid():N}.wav");
            _stream = new FileStream(_file, FileMode.Create, FileAccess.ReadWrite, FileShare.Read);
            TalkWave.WriteWavHeader(_stream, SampleRate, 1, 16, 0);
            _dataBytes = 0;
            _started = DateTimeOffset.UtcNow;
            try
            {
                _capture = new WinMmWaveInCapture(SampleRate, 60, OnBuffer, OnError);
                _capture.Start();
            }
            catch (Exception ex)
            {
                CleanupLocked(deleteFile: true);
                throw new DictationCaptureException(DictationCaptureError.Failed, ex.Message);
            }
        }
        return Task.CompletedTask;
    }

    public Task<DictationTake?> StopAsync(bool cancel)
    {
        WinMmWaveInCapture? cap;
        string? file;
        double seconds;
        int dataBytes;
        lock (_gate)
        {
            cap = _capture;
            _capture = null;
            file = _file;
            dataBytes = _dataBytes;
            seconds = (DateTimeOffset.UtcNow - _started).TotalSeconds;
        }
        cap?.Dispose();
        lock (_gate)
        {
            if (_stream != null)
            {
                try { TalkWave.PatchWavHeader(_stream, _dataBytes); } catch (Exception) { }
                _stream.Dispose();
                _stream = null;
                dataBytes = _dataBytes;
            }
            _file = null;
        }
        if (cancel || file == null || dataBytes <= 0)
        {
            TryDelete(file);
            return Task.FromResult<DictationTake?>(null);
        }
        return Task.FromResult<DictationTake?>(new DictationTake(file, "audio/wav", MemoPolicy.TwoDecimals(seconds)));
    }

    private void OnBuffer(short[] samples, byte[] bytes)
    {
        var level = TalkLevel.Level(TalkLevel.Rms(samples));
        double elapsed;
        bool reachedLimit;
        lock (_gate)
        {
            if (_stream == null) return;
            _stream.Write(bytes, 0, bytes.Length);
            _dataBytes += bytes.Length;
            elapsed = (DateTimeOffset.UtcNow - _started).TotalSeconds;
            reachedLimit = elapsed >= _limit;
        }
        PcmCaptured?.Invoke(samples);
        LevelChanged?.Invoke(level, elapsed);
        if (reachedLimit) Interrupted?.Invoke(DictationCaptureError.Limit, "Reached the dictation time limit.");
    }

    private void OnError(Exception ex)
    {
        Interrupted?.Invoke(DictationCaptureError.Failed, ex.Message);
    }

    private void CleanupLocked(bool deleteFile)
    {
        _capture?.Dispose();
        _capture = null;
        _stream?.Dispose();
        _stream = null;
        if (deleteFile) TryDelete(_file);
        _file = null;
    }

    private static void TryDelete(string? path)
    {
        if (string.IsNullOrEmpty(path)) return;
        try { if (File.Exists(path)) File.Delete(path); } catch (Exception) { }
    }

    public void Dispose()
    {
        lock (_gate) CleanupLocked(deleteFile: true);
    }
}

// MARK: - Windows Talk Capture (WinMM 16 kHz mono -> TalkCaptureCore)

internal sealed class WindowsTalkCapture : ITalkCapturing
{
    private readonly TalkCaptureCore _core = new(TalkCaptureCore.DefaultSampleRate);
    private readonly object _gate = new();
    private WinMmWaveInCapture? _capture;

    public WindowsTalkCapture()
    {
        _core.LevelChanged += l => LevelChanged?.Invoke(l);
        _core.SpeechStarted += () => SpeechStarted?.Invoke();
        _core.TakeCompleted += t => TakeCompleted?.Invoke(t);
        _core.BargeInDetected += () => BargeInDetected?.Invoke();
        _core.PcmCaptured += p => PcmCaptured?.Invoke(p);
    }

    public bool IsCapturing { get { lock (_gate) return _capture != null; } }
    public bool IsMuted { get => _core.IsMuted; set => _core.IsMuted = value; }
    public bool BargeInEnabled { get => _core.BargeInEnabled; set => _core.BargeInEnabled = value; }
    public int SampleRate => _core.SampleRate;

    public event Action<double>? LevelChanged;
    public event Action? SpeechStarted;
    public event Action<TalkTake>? TakeCompleted;
    public event Action? BargeInDetected;
    public event Action<short[]>? PcmCaptured;
    public event Action<TalkCaptureError, string>? Failed;

    public Task StartAsync(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        lock (_gate)
        {
            if (_capture != null) return Task.CompletedTask;
            if (WinMm.waveInGetNumDevs() == 0)
                throw new TalkCaptureException(TalkCaptureError.PermissionDenied, "No microphone device was found.");
            _core.Reset();
            var cap = new WinMmWaveInCapture(SampleRate, 50, OnPcm, OnError);
            try
            {
                cap.Start();
                _capture = cap;
            }
            catch (Exception ex)
            {
                cap.Dispose();
                throw new TalkCaptureException(TalkCaptureError.Failed, ex.Message);
            }
        }
        return Task.CompletedTask;
    }

    public TalkTake? FlushNow() => _core.FlushNow();

    public void Stop()
    {
        WinMmWaveInCapture? cap;
        lock (_gate)
        {
            cap = _capture;
            _capture = null;
        }
        cap?.Dispose();
        _core.Reset();
    }

    private void OnPcm(short[] samples, byte[] bytes) => _core.Feed(samples);

    private void OnError(Exception ex)
    {
        Stop();
        Failed?.Invoke(TalkCaptureError.Failed, ex.Message);
    }

    public void Dispose() => Stop();
}

// MARK: - Windows Talk Speaker (Gateway TTS MediaPlayer + local WindowsReadAloudVoice fallback + 24 kHz Live PCM waveOut)

internal sealed class WindowsTalkSpeaker : ITalkSpeaker
{
    private readonly WindowsReadAloudVoice _localVoice = new();
    private readonly WinMmWaveOutPlayer _pcmOut = new(LiveVoiceWire.PcmSampleRate, 1);
    private CancellationTokenSource? _speakCts;
    private MediaPlayer? _activePlayer;

    public bool IsSpeaking { get; private set; }
    public event Action<double>? LevelChanged;

    public async Task<TalkSpeechOutcome> SpeakAsync(string text, Func<string, CancellationToken, Task<SpeechClip>>? gatewaySpeak,
        CancellationToken ct = default)
    {
        Stop();
        var clean = SpeechText.SanitizeForSpeech(text);
        if (clean.Length == 0) return TalkSpeechOutcome.Completed;

        _speakCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var token = _speakCts.Token;
        IsSpeaking = true;
        try
        {
            if (gatewaySpeak != null)
            {
                try
                {
                    var clip = await gatewaySpeak(clean, token);
                    await PlayClipAsync(clip, token);
                    return TalkSpeechOutcome.Completed;
                }
                catch (OperationCanceledException) { return TalkSpeechOutcome.Cancelled; }
                catch (Exception ex)
                {
                    AppLog.Note("voice", $"gateway TTS failed, falling back to local voice: {ex.GetType().Name}");
                }
            }

            var sentences = SpeechText.CutSentences(clean, flush: true).Sentences;
            await _localVoice.SpeakAsync(sentences, () => LevelChanged?.Invoke(0.65), token);
            return TalkSpeechOutcome.Completed;
        }
        catch (OperationCanceledException)
        {
            return TalkSpeechOutcome.Cancelled;
        }
        catch (Exception ex)
        {
            AppLog.Note("voice", $"talk speaker failed: {ex.Message}");
            return TalkSpeechOutcome.Failed;
        }
        finally
        {
            IsSpeaking = false;
            LevelChanged?.Invoke(0);
        }
    }

    private async Task PlayClipAsync(SpeechClip clip, CancellationToken ct)
    {
        var ext = clip.Mime.Contains("wav", StringComparison.OrdinalIgnoreCase) ? "wav"
            : clip.Mime.Contains("ogg", StringComparison.OrdinalIgnoreCase) ? "ogg"
            : clip.Mime.Contains("mp4", StringComparison.OrdinalIgnoreCase) || clip.Mime.Contains("m4a", StringComparison.OrdinalIgnoreCase) ? "m4a"
            : "mp3";
        var temp = Path.Combine(Path.GetTempPath(), $"hermes-tts-{Guid.NewGuid():N}.{ext}");
        await File.WriteAllBytesAsync(temp, clip.Audio, ct);
        var player = new MediaPlayer { AudioCategory = MediaPlayerAudioCategory.Speech, AutoPlay = false };
        _activePlayer = player;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Ended(MediaPlayer _, object __) => done.TrySetResult();
        void Failed(MediaPlayer _, MediaPlayerFailedEventArgs e) => done.TrySetException(new InvalidOperationException(e.ErrorMessage));
        player.MediaEnded += Ended;
        player.MediaFailed += Failed;
        try
        {
            player.Source = MediaSource.CreateFromUri(new Uri(temp));
            player.Play();
            LevelChanged?.Invoke(0.7);
            using (ct.Register(() => done.TrySetCanceled(ct))) await done.Task;
        }
        finally
        {
            player.MediaEnded -= Ended;
            player.MediaFailed -= Failed;
            player.Pause();
            player.Source = null;
            player.Dispose();
            if (ReferenceEquals(_activePlayer, player)) _activePlayer = null;
            try { File.Delete(temp); } catch (Exception) { }
        }
    }

    public void PlayPcmChunk(ReadOnlySpan<byte> pcm24k)
    {
        if (pcm24k.IsEmpty) return;
        var copy = pcm24k.ToArray();
        var samples = new short[copy.Length / 2];
        Buffer.BlockCopy(copy, 0, samples, 0, samples.Length * 2);
        LevelChanged?.Invoke(TalkLevel.Level(TalkLevel.Rms(samples)));
        try { _pcmOut.Write(copy); } catch (Exception) { }
    }

    public void FlushPcm()
    {
        _pcmOut.Flush();
        LevelChanged?.Invoke(0);
    }

    public void Stop()
    {
        _speakCts?.Cancel();
        _speakCts?.Dispose();
        _speakCts = null;
        if (_activePlayer is { } p)
        {
            try { p.Pause(); } catch (Exception) { }
        }
        _pcmOut.Flush();
        IsSpeaking = false;
        LevelChanged?.Invoke(0);
    }

    public void Dispose()
    {
        Stop();
        _pcmOut.Dispose();
    }
}

// MARK: - Windows Live Speech Recognition (with safe fallback when unavailable)

internal sealed class WindowsLiveWordsEngine : ILiveWordsListening
{
    private SpeechRecognizer? _recognizer;
    private string _settled = "";
    private string _pending = "";
    private bool _running;

    public LiveWordsSource Source => LiveWordsSource.Device;

    public bool IsAvailable
    {
        get
        {
            try { return SpeechRecognizer.SupportedTopicLanguages.Count > 0; }
            catch (Exception) { return false; }
        }
    }

    public event Action<LiveWordsText>? Changed;

    public async Task<bool> StartAsync(CancellationToken ct = default)
    {
        Cancel();
        _settled = "";
        _pending = "";
        try
        {
            var rec = new SpeechRecognizer();
            await rec.CompileConstraintsAsync().AsTask(ct);
            rec.HypothesisGenerated += OnHypothesis;
            rec.ContinuousRecognitionSession.ResultGenerated += OnResult;
            await rec.ContinuousRecognitionSession.StartAsync().AsTask(ct);
            _recognizer = rec;
            _running = true;
            return true;
        }
        catch (Exception ex)
        {
            AppLog.Note("voice", $"Windows speech recognizer unavailable, using gateway STT fallback: {ex.GetType().Name}");
            Cancel();
            return false;
        }
    }

    public void FeedPcm(ReadOnlySpan<short> pcm, int sampleRate) { }

    public async Task<string> FinishAsync(CancellationToken ct = default)
    {
        _running = false;
        if (_recognizer is { } rec)
        {
            _recognizer = null;
            rec.HypothesisGenerated -= OnHypothesis;
            rec.ContinuousRecognitionSession.ResultGenerated -= OnResult;
            try { await rec.ContinuousRecognitionSession.StopAsync().AsTask(ct); } catch (Exception) { }
            rec.Dispose();
        }
        return new LiveWordsText(_settled, _pending).Text;
    }

    public void Cancel()
    {
        _running = false;
        if (_recognizer is { } rec)
        {
            _recognizer = null;
            rec.HypothesisGenerated -= OnHypothesis;
            rec.ContinuousRecognitionSession.ResultGenerated -= OnResult;
            try { _ = rec.ContinuousRecognitionSession.CancelAsync(); } catch (Exception) { }
            rec.Dispose();
        }
        _settled = "";
        _pending = "";
    }

    private void OnHypothesis(SpeechRecognizer sender, SpeechRecognitionHypothesisGeneratedEventArgs args)
    {
        if (!_running) return;
        _pending = args.Hypothesis?.Text ?? "";
        Changed?.Invoke(new LiveWordsText(_settled, _pending));
    }

    private void OnResult(SpeechContinuousRecognitionSession sender, SpeechContinuousRecognitionResultGeneratedEventArgs args)
    {
        if (!_running) return;
        var text = args.Result?.Text?.Trim() ?? "";
        if (text.Length > 0)
        {
            _settled = GatewayWordsWire.Merge(_settled, text);
            _pending = "";
            Changed?.Invoke(new LiveWordsText(_settled, _pending));
        }
    }
}

// MARK: - Live Voice WebSocket Transport (GPT Live & Grok Live)

internal sealed class WindowsLiveVoiceTransport : ILiveVoiceTransport
{
    private ClientWebSocket? _ws;
    private CancellationTokenSource? _rxCts;
    private TalkEngine _engine = TalkEngine.GptLive;
    private readonly SemaphoreSlim _sendGate = new(1, 1);

    public event Action<LiveServerEvent>? EventReceived;

    public async Task ConnectAsync(TalkEngine engine, VoiceLease? gptLease, GrokLiveSession? grokSession, string instructions,
        CancellationToken ct = default)
    {
        await CloseAsync(ct);
        _engine = engine;
        var ws = new ClientWebSocket();
        Uri endpoint;
        string voice;
        if (engine == TalkEngine.GrokLive)
        {
            if (grokSession == null) throw new LiveVoiceException("Missing Grok Live session.", fatal: true);
            endpoint = grokSession.WebSocketUrl;
            voice = grokSession.Voice;
            ws.Options.SetRequestHeader("Authorization", $"Bearer {grokSession.ClientSecret}");
        }
        else
        {
            if (gptLease == null) throw new LiveVoiceException("Missing GPT Live lease.", fatal: true);
            endpoint = gptLease.Endpoint ?? new Uri($"wss://api.openai.com/v1/realtime?model={Uri.EscapeDataString(gptLease.Model ?? "gpt-4o-realtime-preview")}");
            voice = gptLease.Voice ?? LiveVoices.DefaultGptVoice;
            ws.Options.SetRequestHeader("Authorization", $"Bearer {gptLease.Token}");
            ws.Options.SetRequestHeader("OpenAI-Beta", "realtime=v1");
        }

        await ws.ConnectAsync(endpoint, ct);
        _ws = ws;
        _rxCts = new CancellationTokenSource();
        var setup = engine == TalkEngine.GrokLive
            ? GrokLiveWire.SessionUpdate(voice, instructions)
            : LiveVoiceWire.SessionUpdate(voice, instructions);
        await SendControlAsync(setup, ct);
        _ = ReceiveLoopAsync(ws, _rxCts.Token);
    }

    public async Task SendAudioAsync(ReadOnlyMemory<byte> pcm24k, CancellationToken ct = default)
    {
        if (pcm24k.IsEmpty) return;
        foreach (var chunk in LiveVoiceWire.ChunkPcm(pcm24k.Span))
        {
            var json = _engine == TalkEngine.GrokLive
                ? GrokLiveWire.AudioAppend(chunk)
                : LiveVoiceWire.AudioAppend(chunk);
            await SendControlAsync(json, ct);
        }
    }

    public async Task SendControlAsync(string json, CancellationToken ct = default)
    {
        var ws = _ws;
        if (ws == null || ws.State != WebSocketState.Open) return;
        await _sendGate.WaitAsync(ct);
        try
        {
            if (ws.State == WebSocketState.Open)
                await ws.SendAsync(Encoding.UTF8.GetBytes(json), WebSocketMessageType.Text, endOfMessage: true, ct);
        }
        finally
        {
            _sendGate.Release();
        }
    }

    private async Task ReceiveLoopAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        try
        {
            while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
            {
                using var ms = new MemoryStream();
                WebSocketReceiveResult result;
                do
                {
                    result = await ws.ReceiveAsync(buffer, ct);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        EventReceived?.Invoke(new LiveServerEvent.Closed(result.CloseStatusDescription));
                        return;
                    }
                    ms.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);

                if (result.MessageType == WebSocketMessageType.Text)
                {
                    var text = Encoding.UTF8.GetString(ms.ToArray());
                    var ev = _engine == TalkEngine.GrokLive
                        ? GrokLiveWire.ParseEvent(text)
                        : LiveVoiceWire.ParseEvent(text);
                    if (ev != null) EventReceived?.Invoke(ev);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            EventReceived?.Invoke(new LiveServerEvent.Closed(VoiceReport.Scrub(ex.Message)));
        }
    }

    public async Task CloseAsync(CancellationToken ct = default)
    {
        _rxCts?.Cancel();
        _rxCts?.Dispose();
        _rxCts = null;
        if (_ws is { } ws)
        {
            _ws = null;
            try
            {
                if (ws.State == WebSocketState.Open)
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "done", ct);
            }
            catch (Exception) { }
            finally { ws.Dispose(); }
        }
    }

    public async ValueTask DisposeAsync()
    {
        await CloseAsync();
        _sendGate.Dispose();
    }
}
