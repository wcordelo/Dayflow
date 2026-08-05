using Windows.Graphics.Capture;
using WinRT.Interop;
using Dayflow.Windows.Core;

namespace Dayflow.Windows.Capture;

public enum WindowsCaptureState
{
    Idle,
    Unsupported,
    AwaitingPicker,
    Selected,
    Running,
    Stopped,
    PermissionRevoked,
    PrivacyPaused,
}

public sealed record WindowsCaptureStatus(WindowsCaptureState State, string Detail);

public sealed record WindowsCaptureStatusFields(
    string CapturePermission,
    string CaptureSession,
    string CapturePaused,
    string DerivedSync)
{
    public const string CapturePermissionKey = "capture_permission";
    public const string CaptureSessionKey = "capture_session";
    public const string CapturePausedKey = "capture_paused";
    public const string DerivedSyncKey = "derived_sync";

    public IReadOnlyDictionary<string, string> AsDictionary() => new Dictionary<string, string>
    {
        [CapturePermissionKey] = CapturePermission,
        [CaptureSessionKey] = CaptureSession,
        [CapturePausedKey] = CapturePaused,
        [DerivedSyncKey] = DerivedSync,
    };
}

/// <summary>
/// Owns Windows.Graphics.Capture consent and lifecycle. The frame pipeline is
/// injected so the picker/session contract can be tested without requiring a
/// GPU in unit tests. The production pipeline passes metadata samples to local
/// derivation, never to the relay.
/// </summary>
public sealed class WindowsCaptureAdapter
{
    private readonly Microsoft.UI.Xaml.Window _owner;
    private GraphicsCaptureItem? _item;
    private IWindowsFramePipeline? _pipeline;
    private bool _userPaused;
    private bool _sharedCapturePaused;
    private bool _deviceLocked;
    private bool _sleeping;
    private bool _privateContext;
    private bool _drmContent;
    private long _captureGeneration;
    private string? _applicationId;
    private string? _windowTitle;
    private IReadOnlyCollection<string> _blockedApplicationIds = Array.Empty<string>();
    private IReadOnlyCollection<string> _blockedWindowTitleFragments = Array.Empty<string>();
    private DateTimeOffset? _lastDerivedSampleAt;
    private DateTimeOffset? _lastForegroundContextAt;

    public WindowsCaptureAdapter(Microsoft.UI.Xaml.Window owner, IWindowsFramePipeline? pipeline = null)
    {
        _owner = owner;
        _pipeline = pipeline;
    }

    public WindowsCaptureStatus Status { get; private set; } =
        new(WindowsCaptureState.Idle, "Choose a window or display to begin.");

    /// <summary>
    /// Prevents a second picker from being opened while the first picker or a
    /// capture session is still active. This is intentionally derived from
    /// the status rather than from the shell button so programmatic callers
    /// get the same single-session guarantee.
    /// </summary>
    public bool CanStart => Status.State is not (WindowsCaptureState.AwaitingPicker or WindowsCaptureState.Running);

    public WindowsCaptureStatusFields StatusFields(string derivedSync) =>
        StatusFields(Status, _sharedCapturePaused, derivedSync);

    public static WindowsCaptureStatusFields StatusFields(
        WindowsCaptureStatus status,
        bool sharedCapturePaused,
        string derivedSync)
    {
        var permission = status.State switch
        {
            WindowsCaptureState.AwaitingPicker => "awaiting_consent",
            WindowsCaptureState.Selected or WindowsCaptureState.Running => "granted",
            WindowsCaptureState.PermissionRevoked => "revoked",
            WindowsCaptureState.Unsupported => "unavailable",
            _ => "not_active",
        };
        var session = status.State switch
        {
            WindowsCaptureState.Idle => "idle",
            WindowsCaptureState.Unsupported => "unavailable",
            WindowsCaptureState.AwaitingPicker => "awaiting_picker",
            WindowsCaptureState.Selected => "selected",
            WindowsCaptureState.Running => "running",
            WindowsCaptureState.Stopped => "stopped",
            WindowsCaptureState.PermissionRevoked => "permission_revoked",
            WindowsCaptureState.PrivacyPaused => "privacy_paused",
            _ => "unknown",
        };
        return new WindowsCaptureStatusFields(
            permission,
            session,
            sharedCapturePaused || status.State == WindowsCaptureState.PrivacyPaused
                ? "paused"
                : "not_paused",
            string.IsNullOrWhiteSpace(derivedSync) ? "unknown" : derivedSync);
    }

    public event EventHandler<WindowsCaptureStatus>? StatusChanged;

    public async Task StartAsync()
    {
        if (!CanStart)
        {
            return;
        }
        if (_sharedCapturePaused)
        {
            SetStatus(new(WindowsCaptureState.PrivacyPaused, "Capture is paused by a shared Dayflow privacy setting."));
            return;
        }

        var generation = ++_captureGeneration;
        if (!GraphicsCaptureSession.IsSupported())
        {
            SetStatus(new(WindowsCaptureState.Unsupported, "Windows.Graphics.Capture is not supported on this device."));
            return;
        }

        SetStatus(new(WindowsCaptureState.AwaitingPicker, "Select a display or application window in the system picker."));
        var picker = new GraphicsCapturePicker();
        var hwnd = WindowNative.GetWindowHandle(_owner);
        InitializeWithWindow.Initialize(picker, hwnd);
        GraphicsCaptureItem? item;
        try
        {
            item = await picker.PickSingleItemAsync();
        }
        catch (OperationCanceledException)
        {
            if (generation == _captureGeneration)
            {
                SetStatus(new(WindowsCaptureState.Stopped, "Capture selection was cancelled."));
            }
            return;
        }
        catch (Exception error)
        {
            if (generation == _captureGeneration)
            {
                SetStatus(new(WindowsCaptureState.PermissionRevoked, $"Capture selection failed: {error.Message}"));
            }
            return;
        }

        // Stop() can be called while the system picker is visible. Windows
        // does not expose a cancellation token for PickSingleItemAsync, so a
        // generation check prevents a late picker result from starting a new
        // session after the user has already stopped capture.
        if (generation != _captureGeneration || Status.State != WindowsCaptureState.AwaitingPicker)
        {
            return;
        }
        if (item is null)
        {
            SetStatus(new(WindowsCaptureState.Stopped, "Capture was cancelled before a window or display was selected."));
            return;
        }

        _item = item;
        item.Closed += CaptureItem_Closed;
        _lastDerivedSampleAt = null;
        _lastForegroundContextAt = null;
        if (_pipeline is null)
        {
            item.Closed -= CaptureItem_Closed;
            _item = null;
            SetStatus(new(WindowsCaptureState.Selected, "Selection received, but the local GPU capture pipeline is unavailable."));
            return;
        }

        try
        {
            await _pipeline.StartAsync(item, OnFrameArrived);
            if (generation != _captureGeneration)
            {
                _pipeline.Stop();
                item.Closed -= CaptureItem_Closed;
                _item = null;
                return;
            }
            SetStatus(new(WindowsCaptureState.Running, "Capture is active. Windows shows the system capture border."));
        }
        catch (OperationCanceledException)
        {
            item.Closed -= CaptureItem_Closed;
            _item = null;
            SetStatus(new(WindowsCaptureState.Stopped, "Capture stopped."));
        }
        catch (Exception error)
        {
            item.Closed -= CaptureItem_Closed;
            _item = null;
            SetStatus(new(WindowsCaptureState.PermissionRevoked, $"Capture could not start: {error.Message}"));
        }
    }

    public void Stop()
    {
        ++_captureGeneration;
        _pipeline?.Stop();
        if (_item is not null)
        {
            _item.Closed -= CaptureItem_Closed;
        }
        _item = null;
        _lastDerivedSampleAt = null;
        _lastForegroundContextAt = null;
        SetStatus(new(WindowsCaptureState.Stopped, "Capture stopped. Local derived data remains on this device."));
    }

    /// <summary>
    /// Called by the WinUI host when Windows locks the session or suspends the
    /// device. Clearing the flags later never restarts capture; the user must
    /// make a new picker/consent choice after a protected lifecycle transition.
    /// </summary>
    public void UpdateSystemLifecycle(bool deviceLocked, bool sleeping)
    {
        _deviceLocked = deviceLocked;
        _sleeping = sleeping;
        if (deviceLocked)
        {
            StopForPrivacy("Capture paused because Windows locked the session.");
        }
        else if (sleeping)
        {
            StopForPrivacy("Capture paused because Windows suspended the device.");
        }
    }

    /// <summary>
    /// Applies the decrypted cross-device capture pause setting. Clearing it
    /// only permits a future explicit picker action; it never starts capture.
    /// </summary>
    public void UpdateSharedCapturePause(string? value)
    {
        var paused = SharedCapturePauseEnabled(value);
        if (_sharedCapturePaused == paused)
        {
            return;
        }

        _sharedCapturePaused = paused;
        if (paused)
        {
            StopForPrivacy("Capture is paused by a shared Dayflow privacy setting.");
        }
    }

    public void UpdatePrivacyPreferences(
        IReadOnlyCollection<string>? blockedApplicationIds,
        IReadOnlyCollection<string>? blockedWindowTitleFragments)
    {
        _blockedApplicationIds = blockedApplicationIds ?? Array.Empty<string>();
        _blockedWindowTitleFragments = blockedWindowTitleFragments ?? Array.Empty<string>();
    }

    public static bool SharedCapturePauseEnabled(string? value)
        => DayflowWindowsCapturePolicy.SharedCapturePauseEnabled(value);

    /// <summary>
    /// Host lifecycle and foreground-context observers call this before the
    /// next frame. The Rust privacy policy is fail-closed and no frame sample
    /// is emitted while a protected context is active.
    /// </summary>
    public void UpdatePrivacyContext(
        bool userPaused,
        bool deviceLocked,
        bool sleeping,
        bool privateContext,
        bool drmContent,
        string? applicationId = null,
        string? windowTitle = null,
        IReadOnlyCollection<string>? blockedApplicationIds = null,
        IReadOnlyCollection<string>? blockedWindowTitleFragments = null)
    {
        _userPaused = userPaused;
        _deviceLocked = deviceLocked;
        _sleeping = sleeping;
        _privateContext = privateContext;
        _drmContent = drmContent;
        _applicationId = applicationId;
        _windowTitle = windowTitle;
        _blockedApplicationIds = blockedApplicationIds ?? Array.Empty<string>();
        _blockedWindowTitleFragments = blockedWindowTitleFragments ?? Array.Empty<string>();
        if (userPaused || deviceLocked || sleeping || privateContext || drmContent)
        {
            StopForPrivacy("Capture is paused by Dayflow privacy rules.");
        }
    }

    private void OnFrameArrived(WindowsCaptureSample sample)
    {
        if (_lastForegroundContextAt is not { } lastForegroundAt
            || sample.CapturedAt - lastForegroundAt >= TimeSpan.FromSeconds(1))
        {
            var foreground = WindowsForegroundContext.Read();
            _applicationId = foreground.ApplicationId ?? _applicationId;
            _windowTitle = foreground.WindowTitle ?? _windowTitle ?? _item?.DisplayName;
            _privateContext = foreground.PrivateContext;
            _drmContent = foreground.DrmContent;
            _lastForegroundContextAt = sample.CapturedAt;
        }

        DayflowCoreInterop.DayflowCaptureDecision decision;
        try
        {
            decision = DayflowCoreInterop.CaptureDecision(
                    permissionGranted: true,
                    userPaused: _userPaused || _sharedCapturePaused,
                    deviceLocked: _deviceLocked,
                    sleeping: _sleeping,
                    privateContext: _privateContext,
                    drmContent: _drmContent,
                    applicationId: _applicationId,
                    windowTitle: _windowTitle,
                    blockedApplicationIds: _blockedApplicationIds,
                    blockedWindowTitleFragments: _blockedWindowTitleFragments);
        }
        catch (Exception error)
        {
            StopForPrivacy($"Capture paused because the privacy decision failed: {error.Message}");
            return;
        }
        if (!decision.Allowed)
        {
            StopForPrivacy($"Capture paused: {decision.Reason}.");
            return;
        }
        var now = sample.CapturedAt;
        if (_lastDerivedSampleAt is { } lastDerivedAt
            && now - lastDerivedAt < TimeSpan.FromMinutes(1))
        {
            return;
        }
        _lastDerivedSampleAt = now;
        // The pipeline releases the GPU frame before this callback returns. A
        // downstream local derivation worker can turn this metadata into a
        // throttled Rust event; raw pixels never enter the sync client or
        // persistence.
        // Carry only the already privacy-approved foreground identity into
        // local derivation. The frame pipeline has released the GPU frame;
        // raw pixels never enter the event writer.
        SampleArrived?.Invoke(this, sample with
        {
            ApplicationId = _applicationId,
            WindowTitle = _windowTitle,
        });
    }

    public event EventHandler<WindowsCaptureSample>? SampleArrived;

    private void SetStatus(WindowsCaptureStatus status)
    {
        Status = status;
        StatusChanged?.Invoke(this, status);
    }

    private void StopForPrivacy(string detail)
    {
        ++_captureGeneration;
        _pipeline?.Stop();
        if (_item is not null)
        {
            _item.Closed -= CaptureItem_Closed;
        }
        _item = null;
        _lastDerivedSampleAt = null;
        _lastForegroundContextAt = null;
        SetStatus(new(WindowsCaptureState.PrivacyPaused, detail));
    }

    private void CaptureItem_Closed(GraphicsCaptureItem sender, object args)
    {
        ++_captureGeneration;
        _pipeline?.Stop();
        if (ReferenceEquals(_item, sender))
        {
            _item = null;
        }
        _lastDerivedSampleAt = null;
        _lastForegroundContextAt = null;
        SetStatus(new(WindowsCaptureState.Stopped, "The selected window or display closed. Choose a capture source again."));
    }
}

public interface IWindowsFramePipeline
{
    Task StartAsync(GraphicsCaptureItem item, Action<WindowsCaptureSample> onFrame);
    void Stop();
}

public sealed record WindowsCaptureSample(
    DateTimeOffset CapturedAt,
    int Width,
    int Height,
    string? ApplicationId = null,
    string? WindowTitle = null);
