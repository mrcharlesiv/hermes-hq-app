using System.Diagnostics;
using Hermes.Core.Heads;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Heads;

/// Smooth 60fps animated bot face driven by `BotMoods`, `FaceLoop.SoftSamples`, `FaceJelly`, and `MatrixAct`
/// (`App/Heads/HeadView.swift`). Automatically renders a clean, deterministic static frame with zero timers when
/// system Reduced Motion is active or `Automation.Enabled` is true.
public sealed partial class AnimatedHeadFace : Grid
{
    private const double BridgeDuration = 0.22;
    private const double OnceBridgeDuration = 0.12;
    private const double SettleDuration = 0.30;

    private readonly DispatcherQueue? _queue = DispatcherQueue.GetForCurrentThread();
    private Head _head;
    private double _side;
    private bool? _dark;
    private bool _pageUnknown;
    private string? _profile;
    private BotMood? _posedMood;
    private bool _working;

    private HeadDrawing.LayeredHead? _layered;
    private string _drawnKey = "";
    private bool _isLoaded;
    private bool _renderingHooked;

    // Active animation tracks
    private BotMood? _activeMood;
    private FaceLoop? _loop;
    private List<FaceSample>? _samples;
    private List<FaceJelly>? _wobble;
    private MatrixAct? _matrixAct;
    private List<MatrixActFrame>? _matrixFrames;
    private MatrixActPose? _lastMatrixPose;
    private double _actBegin;
    private bool _actOnce;

    // Smooth C² quintic bridge / settle state
    private FaceBody _currentBody = FaceBody.Rest;
    private FaceEyes _currentEyes = FaceEyes.Rest;
    private FaceJelly _currentJelly = FaceJelly.Rest;
    private double _currentGlintOpacity;

    private bool _bridging;
    private double _bridgeBegin;
    private double _bridgeDuration;
    private FaceBody _bridgeFromBody;
    private FaceEyes _bridgeFromEyes;
    private FaceJelly _bridgeFromJelly;
    private double _bridgeFromGlintOpacity;

    private bool _settling;
    private double _settleBegin;
    private FaceBody _settleFromBody;
    private FaceEyes _settleFromEyes;
    private FaceJelly _settleFromJelly;
    private double _settleFromGlintOpacity;

    public AnimatedHeadFace(Head head, double side, bool? dark = null, bool pageUnknown = false)
    {
        _head = head;
        _side = side;
        _dark = dark;
        _pageUnknown = pageUnknown;
        Width = Height = side;
        IsHitTestVisible = false;

        ActualThemeChanged += (_, _) => RebuildLayers();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        RebuildLayers();
    }

    /// True when system animations are disabled or deterministic UI automation is running.
    public static bool IsStillMode
    {
        get
        {
            if (Automation.Enabled) return true;
            try { return !new Windows.UI.ViewManagement.UISettings().AnimationsEnabled; }
            catch { return false; }
        }
    }

    public Head Head
    {
        get => _head;
        set
        {
            if (_head == value) return;
            _head = value;
            _drawnKey = "";
            RebuildLayers();
            SyncMood();
        }
    }

    public string? Profile
    {
        get => _profile;
        set
        {
            var next = string.IsNullOrEmpty(value) ? null : value;
            if (_profile == next) return;
            _profile = next;
            SyncMood();
        }
    }

    public BotMood? PosedMood
    {
        get => _posedMood;
        set
        {
            if (_posedMood == value) return;
            _posedMood = value;
            SyncMood();
        }
    }

    public bool Working
    {
        get => _working;
        set
        {
            if (_working == value) return;
            _working = value;
            SyncMood();
        }
    }

    private BotMood? EffectiveMood =>
        _posedMood
        ?? (!string.IsNullOrEmpty(_profile) ? BotMoods.Shared.MoodFor(_profile) : null)
        ?? (_working ? BotMood.Thinking : null);

    private bool? EffectiveDark => _pageUnknown ? null : _dark ?? ActualTheme == ElementTheme.Dark;
    private new double Scale => XamlRoot?.RasterizationScale ?? 2.0;

    private static double NowSeconds() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _isLoaded = true;
        BotMoods.Shared.Changed -= OnMoodChanged;
        BotMoods.Shared.Changed += OnMoodChanged;
        RebuildLayers();
        SyncMood();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _isLoaded = false;
        BotMoods.Shared.Changed -= OnMoodChanged;
        StopRendering();
    }

    private void OnMoodChanged(string profile)
    {
        if (_profile == null || !string.Equals(_profile, profile, StringComparison.Ordinal)) return;
        if (_queue == null || _queue.HasThreadAccess) SyncMood();
        else _queue.TryEnqueue(SyncMood);
    }

    private void RebuildLayers()
    {
        var dark = EffectiveDark;
        var scale = Scale;
        var key = HeadPicture.Key(_head, _side, dark) + "|" + scale;
        if (key == _drawnKey && _layered != null) return;
        _drawnKey = key;
        _lastMatrixPose = null;
        _layered = HeadDrawing.DrawLayered(_head, _side, scale, dark);
        Children.Clear();
        Children.Add(_layered.Root);
        if (IsStillMode) ApplyStillFrame(EffectiveMood);
        else ApplyPose(_currentBody, _currentEyes, _currentJelly, null, _currentGlintOpacity);
    }

    private void SyncMood()
    {
        if (_layered == null) RebuildLayers();
        var mood = EffectiveMood;
        if (IsStillMode)
        {
            StopRendering();
            _activeMood = mood;
            _settling = false;
            _bridging = false;
            ApplyStillFrame(mood);
            return;
        }
        if (!_isLoaded)
        {
            _activeMood = null;
            return;
        }

        var now = NowSeconds();
        if (mood == null)
        {
            if (_activeMood != null && !IsAtRest())
            {
                _activeMood = null;
                _bridging = false;
                _settling = true;
                _settleBegin = now;
                _settleFromBody = _currentBody;
                _settleFromEyes = _currentEyes;
                _settleFromJelly = _currentJelly;
                _settleFromGlintOpacity = _currentGlintOpacity;
                StartRendering();
            }
            else if (!_settling)
            {
                _activeMood = null;
                StopRendering();
                ApplyRest();
            }
            return;
        }

        if (_activeMood == mood && _samples != null) return;

        var wasMoving = _activeMood != null || _settling;
        _activeMood = mood;
        _settling = false;

        var m = mood.Value;
        var facing = _head.Theme == HeadTheme.Matrix ? MatrixHead.ShownFacing : 1;
        var seed = (_profile?.GetHashCode(StringComparison.Ordinal) ?? _head.Seed) ^ (int)m * 31;
        var loop = new FaceLoop(m, facing, seed);
        _loop = loop;
        _actOnce = m.IsOnce();
        _samples = loop.SoftSamples(_actOnce, rate: 60);
        _wobble = FaceJelly.Follow(_samples, loop.Period, _actOnce);

        if (_head.Theme == HeadTheme.Matrix)
        {
            var design = MatrixDesign.Of(_head);
            _matrixAct = MatrixAct.Make(m, design);
            _matrixFrames = _matrixAct.SampleFrames(loop, rate: 60);
        }
        else
        {
            _matrixAct = null;
            _matrixFrames = null;
        }

        var since = _posedMood == null && _profile != null ? BotMoods.Shared.Since(_profile) : null;
        _actBegin = since ?? now;

        if (wasMoving || !IsAtRest())
        {
            _bridging = true;
            _bridgeBegin = now;
            _bridgeDuration = _actOnce ? OnceBridgeDuration : BridgeDuration;
            _bridgeFromBody = _currentBody;
            _bridgeFromEyes = _currentEyes;
            _bridgeFromJelly = _currentJelly;
            _bridgeFromGlintOpacity = _currentGlintOpacity;
        }
        else
        {
            _bridging = false;
        }

        StartRendering();
    }

    private bool IsAtRest() =>
        Math.Abs(_currentBody.X) < 1e-4 && Math.Abs(_currentBody.Y) < 1e-4
        && Math.Abs(_currentBody.Roll) < 1e-3 && Math.Abs(_currentBody.Turn) < 1e-3
        && Math.Abs(_currentBody.Tip) < 1e-3 && Math.Abs(_currentBody.Squash) < 1e-4
        && Math.Abs(_currentJelly.Squash) < 1e-4 && Math.Abs(_currentJelly.Lean) < 1e-4
        && _currentGlintOpacity < 1e-3;

    private void StartRendering()
    {
        if (_renderingHooked) return;
        _renderingHooked = true;
        CompositionTarget.Rendering += OnRendering;
    }

    private void StopRendering()
    {
        if (!_renderingHooked) return;
        _renderingHooked = false;
        CompositionTarget.Rendering -= OnRendering;
    }

    private void OnRendering(object? sender, object e)
    {
        if (!_isLoaded || IsStillMode || _layered == null)
        {
            StopRendering();
            return;
        }

        var now = NowSeconds();

        if (_settling)
        {
            var u = (now - _settleBegin) / SettleDuration;
            if (u >= 1.0)
            {
                _settling = false;
                StopRendering();
                ApplyRest();
                return;
            }
            var k = FaceBody.Quintic(u);
            var b = _settleFromBody.MixedShortest(FaceBody.Rest, k);
            var ey = _settleFromEyes.Mixed(FaceEyes.Rest, k);
            var j = new FaceJelly(_settleFromJelly.Squash * (1.0 - k), _settleFromJelly.Lean * (1.0 - k));
            var gOpacity = _settleFromGlintOpacity * (1.0 - k);
            ApplyPose(b, ey, j, MatrixGlintFrame.For(b), gOpacity);
            return;
        }

        if (_activeMood == null || _loop == null || _samples == null || _wobble == null)
        {
            StopRendering();
            return;
        }

        var elapsed = Math.Max(0.0, now - _actBegin);
        var (body, eyes) = FaceLoop.Interpolated(_samples, elapsed, _loop.Period, _actOnce);
        var jelly = FaceJelly.Interpolated(_wobble, _samples, elapsed, _loop.Period, _actOnce);
        var glintOpacity = _head.Theme == HeadTheme.Matrix ? 1.0 : 0.0;
        MatrixGlintFrame? glint = _head.Theme == HeadTheme.Matrix ? MatrixGlintFrame.For(body) : null;

        if (_head.Theme == HeadTheme.Matrix && _matrixFrames is { Count: > 0 } mFrames)
        {
            var u = _actOnce ? Math.Clamp(elapsed, 0, _loop.Period) : elapsed % _loop.Period;
            if (u < 0) u += _loop.Period;
            var idx = Math.Clamp((int)(u / Math.Max(_loop.Period, 1e-6) * (mFrames.Count - 1)), 0, mFrames.Count - 1);
            var frame = mFrames[idx];
            jelly = frame.Elastic;
            glint = frame.Glint;
            ApplyMatrixPose(frame.Pose);
        }

        if (_bridging)
        {
            var u = (now - _bridgeBegin) / _bridgeDuration;
            if (u >= 1.0)
            {
                _bridging = false;
            }
            else
            {
                var k = FaceBody.Quintic(u);
                body = _bridgeFromBody.MixedShortest(body, k);
                eyes = _bridgeFromEyes.Mixed(eyes, k);
                jelly = new FaceJelly(
                    _bridgeFromJelly.Squash + (jelly.Squash - _bridgeFromJelly.Squash) * k,
                    _bridgeFromJelly.Lean + (jelly.Lean - _bridgeFromJelly.Lean) * k);
                glintOpacity = _bridgeFromGlintOpacity + (glintOpacity - _bridgeFromGlintOpacity) * k;
            }
        }

        ApplyPose(body, eyes, jelly, glint, glintOpacity);

        if (_actOnce && elapsed >= _loop.Period)
        {
            _activeMood = null;
            _bridging = false;
            _settling = false;
            StopRendering();
            ApplyRest();
        }
    }

    private void ApplyStillFrame(BotMood? mood)
    {
        if (_layered == null) return;
        _currentBody = FaceBody.Rest;
        _currentJelly = FaceJelly.Rest;
        _currentGlintOpacity = 0;

        if (mood is { } m)
        {
            if (_head.Theme == HeadTheme.Matrix)
            {
                var act = MatrixAct.Make(m, MatrixDesign.Of(_head));
                ApplyMatrixPose(act.Still);
                _currentEyes = FaceEyes.Rest;
            }
            else
            {
                _currentEyes = FaceRoutines.Still(m, 1);
            }
        }
        else
        {
            if (_head.Theme == HeadTheme.Matrix) ApplyMatrixPose(MatrixActPose.Look);
            _currentEyes = FaceEyes.Rest;
        }
        ApplyPose(_currentBody, _currentEyes, _currentJelly, null, 0);
    }

    private void ApplyRest()
    {
        _currentBody = FaceBody.Rest;
        _currentEyes = FaceEyes.Rest;
        _currentJelly = FaceJelly.Rest;
        _currentGlintOpacity = 0;
        if (_head.Theme == HeadTheme.Matrix) ApplyMatrixPose(MatrixActPose.Look);
        ApplyPose(FaceBody.Rest, FaceEyes.Rest, FaceJelly.Rest, null, 0);
    }

    private void ApplyMatrixPose(MatrixActPose pose)
    {
        if (_layered?.MatrixImage is not { } image) return;
        if (_lastMatrixPose == pose) return;
        _lastMatrixPose = pose;
        var dark = EffectiveDark == true;
        var pixels = Math.Max(16, (int)Math.Ceiling(_side * Scale));
        var markup = MatrixActSvg.Svg(_head, _side, dark, pose);
        image.Source = HeadDrawing.SvgSource(markup, pixels);
    }

    private void ApplyPose(FaceBody body, FaceEyes eyes, FaceJelly jelly, MatrixGlintFrame? glint, double glintOpacity)
    {
        _currentBody = body;
        _currentEyes = eyes;
        _currentJelly = jelly;
        _currentGlintOpacity = glintOpacity;

        if (_layered is not { } layered) return;
        var isMatrix = _head.Theme == HeadTheme.Matrix;
        var squash = body.Squash + jelly.Squash * (isMatrix ? 1.0 : 0.85);
        var lean = jelly.Lean * (isMatrix ? 1.0 : 0.9);
        var turnRad = body.Turn * Math.PI / 180.0;
        var tipRad = body.Tip * Math.PI / 180.0;

        var scaleX = Math.Clamp((1.0 + squash) * (0.92 + 0.08 * Math.Cos(turnRad)), 0.78, 1.28);
        var scaleY = Math.Clamp((1.0 - squash) * (0.94 + 0.06 * Math.Cos(tipRad)), 0.78, 1.28);

        var bt = layered.BodyTransform;
        bt.TranslateX = body.X * 1024.0;
        bt.TranslateY = body.Y * 1024.0;
        bt.ScaleX = scaleX;
        bt.ScaleY = scaleY;
        bt.SkewX = Math.Clamp(-lean * (180.0 / Math.PI) * 0.65, -18.0, 18.0);
        bt.Rotation = body.Roll;

        if (layered.EyesTransform is { } et)
        {
            et.TranslateX = eyes.X * 56.0 + body.Turn * 2.1;
            et.TranslateY = eyes.Y * 42.0 + body.Tip * 1.8;
            var lidScale = Math.Clamp((1.0 - eyes.Lids * 0.86) * (1.0 + eyes.Wide * 0.16), 0.14, 1.22);
            et.ScaleX = Math.Clamp(0.9 + 0.1 * Math.Cos(turnRad), 0.82, 1.08);
            et.ScaleY = lidScale;
            et.Rotation = eyes.Tilt * 8.0;
        }

        if (layered.GlintOverlay is { } overlay && layered.GlintTransform is { } gt)
        {
            overlay.Opacity = Math.Clamp(glintOpacity, 0.0, 1.0);
            if (glint is { } g)
            {
                gt.TranslateX = g.StartX * 1024.0 - 280.0;
                gt.TranslateY = g.StartY * 1024.0 - 280.0;
            }
        }
    }
}
