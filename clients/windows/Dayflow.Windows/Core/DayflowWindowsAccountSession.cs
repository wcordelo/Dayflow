using System.Text.Json;
using System.Linq;
using Dayflow.Windows.Capture;

namespace Dayflow.Windows.Core;

public sealed record DayflowWindowsAccountSession(
    string AccountId,
    string Token,
    string AuthUrl,
    string Email,
    string RelayUrl,
    string DisplayName);

/// <summary>
/// App-facing Windows coordinator. Credentials are held in the DPAPI-backed
/// key store, while capture only contributes throttled metadata-only events to
/// the same account-scoped encrypted outbox used by the sync session.
/// </summary>
public sealed class DayflowWindowsAppModel
{
    private const string ActiveSessionAccount = "active-session";
    private const string ActiveSessionName = "account-session-v1";
    private readonly DayflowWindowsKeyStore _keyStore;
    private readonly DayflowAIProviderStore _providerStore;
    private readonly DayflowWindowsSyncSession _syncSession;
    private readonly DayflowWindowsPushNotifications _pushNotifications;
    private long _lastCaptureEventTimestamp;
    private readonly object _syncGate = new();
    private Task? _syncTask;
    private string? _registeredPushToken;

    public DayflowWindowsAppModel(
        DayflowWindowsKeyStore? keyStore = null,
        DayflowWindowsSyncSession? syncSession = null)
    {
        _keyStore = keyStore ?? new DayflowWindowsKeyStore();
        _providerStore = new DayflowAIProviderStore(_keyStore);
        _syncSession = syncSession ?? new DayflowWindowsSyncSession(_keyStore);
        _pushNotifications = new DayflowWindowsPushNotifications(SyncForPushWakeAsync);
        LoadSession();
        if (string.IsNullOrWhiteSpace(AccountId)) PrepareLocalWorkspace();
    }

    public string AccountId { get; private set; } = "";
    public string Token { get; private set; } = "";
    public string AuthUrl { get; private set; } = "";
    public string Email { get; private set; } = "";
    public string VerificationCode { get; private set; } = "";
    public string? AuthMessage { get; private set; }
    public string RelayUrl { get; private set; } = "";
    public string DisplayName { get; private set; } = "This Windows device";
    public string Status { get; private set; } = "Not connected";
    public bool CanCapture => _syncSession.HasLocalAccountKey(ActiveWorkspaceId());
    public IReadOnlyList<DayflowWindowsRelayDevice> Devices { get; private set; } = Array.Empty<DayflowWindowsRelayDevice>();
    public DayflowWindowsProjection Projection { get; private set; } = DayflowWindowsProjection.Empty;
    public int PendingEventCount { get; private set; }
    public DayflowWindowsSyncHealth SyncHealth { get; private set; } = DayflowWindowsSyncHealth.Initial;
    public string SyncHealthSummary => SyncHealth.Summary(PendingEventCount);
    public string JournalDay { get; private set; } = "";
    public string JournalBody { get; private set; } = "";
    public string? JournalMessage { get; private set; }
    public string PriorityDay { get; private set; } = "";
    public string PriorityText { get; private set; } = "";
    public string? PriorityMessage { get; private set; }
    public string ReflectionDay { get; private set; } = "";
    public string ReflectionBody { get; private set; } = "";
    public string? ReflectionMessage { get; private set; }
    public string SharedSettingKey { get; private set; } = "dayflow.capture.paused";
    public string SharedSettingValue { get; private set; } = "false";
    public string? SharedSettingMessage { get; private set; }
    public string ChatQuestion { get; private set; } = "";
    public string? ChatAnswer { get; private set; }
    public string? ChatMessage { get; private set; }
    public bool IsChatting { get; private set; }
    public string RecoveryKitText { get; private set; } = "";
    public string? RecoveryMessage { get; private set; }
    public string ProviderId { get; private set; } = DayflowAIProviderIds.Local;
    public string ProviderEndpoint { get; private set; } = "http://127.0.0.1:11434";
    public string ProviderModelId { get; private set; } = "llama3.2";
    public string ProviderApiKey { get; private set; } = "";
    public string? ProviderMessage { get; private set; }
    public bool IsRotatingKey { get; private set; }
    public string? RotationMessage { get; private set; }

    public event EventHandler? StateChanged;

    public string? CurrentDeviceId => System.Text.Encoding.UTF8.GetString(
        _keyStore.GetOrCreateDeviceId(string.IsNullOrWhiteSpace(AccountId)
            ? DayflowWindowsSyncSession.LocalWorkspaceId
            : AccountId));

    public void SetAccountFields(string accountId, string token, string relayUrl, string displayName)
    {
        AccountId = accountId;
        Token = token;
        RelayUrl = relayUrl;
        DisplayName = displayName;
    }

    public void SetAuthFields(string authUrl, string email, string verificationCode)
    {
        AuthUrl = authUrl;
        Email = email;
        VerificationCode = verificationCode;
    }

    public void SetProviderFields(string providerId, string endpoint, string modelId, string apiKey)
    {
        ProviderId = providerId;
        ProviderEndpoint = endpoint;
        ProviderModelId = modelId;
        ProviderApiKey = apiKey;
    }

    public Task SyncAsync(CancellationToken cancellationToken = default)
    {
        lock (_syncGate)
        {
            if (_syncTask is { IsCompleted: false }) return _syncTask;
            _syncTask = SyncCoreAsync(cancellationToken);
            return _syncTask;
        }
    }

    /// <summary>
    /// Reconnects a persisted account when the window becomes active. Empty or
    /// partial sign-in state remains completely local and causes no request.
    /// </summary>
    public Task SyncIfConfiguredAsync(CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(AccountId)
            || string.IsNullOrWhiteSpace(Token)
            || string.IsNullOrWhiteSpace(RelayUrl)
            || string.IsNullOrWhiteSpace(DisplayName))
        {
            return Task.CompletedTask;
        }
        return SyncAsync(cancellationToken);
    }

    /// <summary>
    /// Runs the same coalesced encrypted sync used by foreground activation.
    /// A Windows push is only a wake signal; the relay cursor and local
    /// encrypted event log remain the source of truth.
    /// </summary>
    public Task SyncForPushWakeAsync(CancellationToken cancellationToken = default) =>
        SyncIfConfiguredAsync(cancellationToken);

    private async Task SyncCoreAsync(CancellationToken cancellationToken)
    {
        var session = ValidateSession();
        _keyStore.StoreText(ActiveSessionAccount, ActiveSessionName, JsonSerializer.Serialize(session));
        LoadProvider();
        SetStatus("Syncing encrypted events…");
        try
        {
            var result = await _syncSession.SyncAsync(
                session.AccountId,
                session.Token,
                session.RelayUrl,
                session.DisplayName,
                cancellationToken: cancellationToken);
            if (!IsCurrentSession(session)) return;
            Devices = await _syncSession.ListDevicesAsync(session.Token, session.RelayUrl, cancellationToken);
            if (!IsCurrentSession(session)) return;
            if (string.IsNullOrWhiteSpace(JournalDay)) JournalDay = DefaultLogicalDay();
            if (result.Status == "waiting_for_approval")
            {
                // A pending device has no account key yet. Do not call
                // ProjectLocal until an approved device delivers its wrapped
                // key; preserve the existing local projection while waiting.
                SyncHealth = _syncSession.SyncHealth(session.AccountId);
                SetStatus("Waiting for device approval");
                return;
            }
            Projection = DayflowWindowsProjection.FromJson(_syncSession.ProjectLocal(session.AccountId));
            PendingEventCount = _syncSession.PendingEventCount(session.AccountId);
            SyncHealth = _syncSession.SyncHealth(session.AccountId);
            await TryRegisterPushChannelAsync(session, cancellationToken);
            SetStatus($"Synced {result.Pushed} sent, {result.Pulled} received, {result.NotificationHints} wake hints consumed");
        }
        catch (Exception error)
        {
            if (IsCurrentSession(session))
            {
                SyncHealth = _syncSession.SyncHealth(session.AccountId);
            }
            if (IsCurrentSession(session)) SetStatus(error.Message);
            throw;
        }
    }

    public async Task RequestSignInCodeAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            await new DayflowWindowsAuthClient().RequestCodeAsync(Email, AuthUrl, cancellationToken);
            AuthMessage = "Sign-in code sent. Check your email.";
            Notify();
        }
        catch (Exception error)
        {
            AuthMessage = error.Message;
            Notify();
            throw;
        }
    }

    public async Task VerifySignInCodeAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var result = await new DayflowWindowsAuthClient().VerifyCodeAsync(Email, VerificationCode, DisplayName, AuthUrl, cancellationToken);
            AccountId = result.AccountId;
            Email = result.Email;
            Token = result.Token;
            AuthMessage = "Signed in. Connecting this device…";
            Notify();
            await SyncAsync(cancellationToken);
        }
        catch (Exception error)
        {
            AuthMessage = error.Message;
            Notify();
            throw;
        }
    }

    public async Task RefreshDevicesAsync(CancellationToken cancellationToken = default)
    {
        var session = ValidateSession();
        try
        {
            Devices = await _syncSession.ListDevicesAsync(session.Token, session.RelayUrl, cancellationToken);
            SetStatus("Device list refreshed");
        }
        catch (Exception error)
        {
            SetStatus(error.Message);
            throw;
        }
    }

    public async Task ApproveDeviceAsync(string deviceId, CancellationToken cancellationToken = default)
    {
        var session = ValidateSession();
        await _syncSession.ApproveDeviceAsync(session.AccountId, session.Token, session.RelayUrl, deviceId, cancellationToken: cancellationToken);
        await RefreshDevicesAsync(cancellationToken);
    }

    public async Task RevokeDeviceAsync(string deviceId, CancellationToken cancellationToken = default)
    {
        var session = ValidateSession();
        if (deviceId == CurrentDeviceId) throw new InvalidOperationException("This Windows device cannot revoke itself.");
        await _syncSession.RevokeDeviceAsync(session.AccountId, session.Token, session.RelayUrl, deviceId, cancellationToken);
        await RefreshDevicesAsync(cancellationToken);
    }

    public async Task RotateEncryptionKeyAsync(CancellationToken cancellationToken = default)
    {
        var session = ValidateSession();
        if (IsRotatingKey) return;
        IsRotatingKey = true;
        RotationMessage = null;
        SetStatus("Rotating encrypted account key…");
        try
        {
            var version = await _syncSession.RotateEncryptionKeyAsync(
                session.AccountId,
                session.Token,
                session.RelayUrl,
                cancellationToken);
            Devices = await _syncSession.ListDevicesAsync(session.Token, session.RelayUrl, cancellationToken);
            RotationMessage = "All approved devices received the new key. Previous versions remain available for replay.";
            SetStatus($"Encrypted key rotated to version {version}.");
        }
        catch (Exception error)
        {
            RotationMessage = "No local key change was committed. Fix the issue and try again.";
            SetStatus(error.Message);
            throw;
        }
        finally
        {
            IsRotatingKey = false;
            Notify();
        }
    }

    public void SaveProvider()
    {
        try
        {
            var workspace = ActiveWorkspaceId();
            _providerStore.Save(
                workspace,
                new DayflowAIProviderConfiguration(ProviderId, ProviderEndpoint, ProviderModelId),
                ProviderApiKey);
            ProviderMessage = "Provider settings saved on this device.";
        }
        catch (Exception error)
        {
            ProviderMessage = error.Message;
        }
        Notify();
    }

    public void SetJournalFields(string day, string body)
    {
        JournalDay = day;
        JournalBody = body;
    }

    public void SetPriorityFields(string day, string text)
    {
        PriorityDay = day;
        PriorityText = text;
    }

    public void SetReflectionFields(string day, string body)
    {
        ReflectionDay = day;
        ReflectionBody = body;
    }

    public void SetSharedSettingFields(string key, string value)
    {
        SharedSettingKey = key;
        SharedSettingValue = value;
    }

    public void SetChatQuestion(string question) => ChatQuestion = question;

    public void SetRecoveryKitText(string kitJson) => RecoveryKitText = kitJson;

    public async Task AskChatAsync(CancellationToken cancellationToken = default)
    {
        IsChatting = true;
        ChatAnswer = null;
        ChatMessage = null;
        Notify();
        try
        {
            var configuration = new DayflowAIProviderConfiguration(ProviderId, ProviderEndpoint, ProviderModelId);
            ChatAnswer = await new DayflowWindowsAIChatClient().AnswerAsync(
                configuration,
                ProviderApiKey,
                ChatQuestion,
                Projection.ChatContext,
                cancellationToken);
            ChatMessage = $"Answered from local Dayflow context via {ProviderId}.";
        }
        catch (Exception error)
        {
            ChatMessage = error.Message;
        }
        finally
        {
            IsChatting = false;
            Notify();
        }
    }

    public string? ExportRecoveryKit(string passphrase)
    {
        if (string.IsNullOrWhiteSpace(AccountId))
        {
            RecoveryMessage = "Connect a Dayflow account before exporting a recovery kit.";
            Notify();
            return null;
        }
        try
        {
            RecoveryKitText = _syncSession.ExportRecoveryKit(AccountId, passphrase);
            RecoveryMessage = "Recovery kit prepared. Keep it and its passphrase separate.";
            return RecoveryKitText;
        }
        catch (Exception error)
        {
            RecoveryMessage = error.Message;
            return null;
        }
        finally
        {
            Notify();
        }
    }

    public void RestoreRecoveryKit(string kitJson, string passphrase)
    {
        if (string.IsNullOrWhiteSpace(AccountId))
        {
            RecoveryMessage = "Enter or connect the Dayflow account before restoring a recovery kit.";
            Notify();
            return;
        }
        try
        {
            _syncSession.RestoreRecoveryKit(AccountId, kitJson, passphrase);
            RecoveryMessage = "Recovery key restored. Review approved devices before syncing.";
        }
        catch (Exception error)
        {
            RecoveryMessage = error.Message;
        }
        Notify();
    }

    public void AddJournalEntry()
    {
        try
        {
            var workspace = ActiveWorkspaceId();
            _syncSession.EnqueueJournal(workspace, JournalDay, JournalBody);
            Projection = DayflowWindowsProjection.FromJson(_syncSession.ProjectLocal(workspace));
            PendingEventCount = _syncSession.PendingEventCount(workspace);
            JournalBody = "";
            JournalMessage = "Saved locally. It will sync as an encrypted event when you connect.";
        }
        catch (Exception error)
        {
            JournalMessage = error.Message;
        }
        Notify();
    }

    public void AddPriority()
    {
        try
        {
            var workspace = ActiveWorkspaceId();
            var day = string.IsNullOrWhiteSpace(PriorityDay) ? JournalDay : PriorityDay;
            var rank = Projection.Priorities.Values
                .Where(priority => priority.Day == day)
                .Select(priority => priority.Rank)
                .DefaultIfEmpty(-1)
                .Max() + 1;
            _syncSession.EnqueuePriority(workspace, day, PriorityText, rank);
            Projection = DayflowWindowsProjection.FromJson(_syncSession.ProjectLocal(workspace));
            PendingEventCount = _syncSession.PendingEventCount(workspace);
            PriorityText = "";
            PriorityMessage = "Priority saved locally. It will sync as an encrypted event when you connect.";
        }
        catch (Exception error)
        {
            PriorityMessage = error.Message;
        }
        Notify();
    }

    public void AddReflection()
    {
        try
        {
            var workspace = ActiveWorkspaceId();
            var day = string.IsNullOrWhiteSpace(ReflectionDay) ? JournalDay : ReflectionDay;
            _syncSession.EnqueueReflection(workspace, day, ReflectionBody);
            Projection = DayflowWindowsProjection.FromJson(_syncSession.ProjectLocal(workspace));
            PendingEventCount = _syncSession.PendingEventCount(workspace);
            ReflectionBody = "";
            ReflectionMessage = "Reflection saved locally. It will sync as an encrypted event when you connect.";
        }
        catch (Exception error)
        {
            ReflectionMessage = error.Message;
        }
        Notify();
    }

    public void DeleteTimelineCard(string id) => DeleteRecord(
        id,
        message => JournalMessage = message);

    public void DeleteJournalEntry(string id) => DeleteRecord(
        id,
        message => JournalMessage = message);

    public void DeletePriority(string id) => DeleteRecord(
        id,
        message => PriorityMessage = message);

    public void DeleteReflection(string id) => DeleteRecord(
        id,
        message => ReflectionMessage = message);

    public void SaveSharedSetting()
    {
        try
        {
            var workspace = ActiveWorkspaceId();
            _syncSession.EnqueueSetting(workspace, SharedSettingKey, SharedSettingValue);
            Projection = DayflowWindowsProjection.FromJson(_syncSession.ProjectLocal(workspace));
            PendingEventCount = _syncSession.PendingEventCount(workspace);
            SharedSettingMessage = "Shared setting saved locally. Provider secrets remain device-only.";
        }
        catch (Exception error)
        {
            SharedSettingMessage = error.Message;
        }
        Notify();
    }

    private void DeleteRecord(string id, Action<string> setMessage)
    {
        try
        {
            var workspace = ActiveWorkspaceId();
            _syncSession.EnqueueTombstone(workspace, id);
            Projection = DayflowWindowsProjection.FromJson(_syncSession.ProjectLocal(workspace));
            PendingEventCount = _syncSession.PendingEventCount(workspace);
            setMessage("Deleted locally. The deletion will sync as an encrypted event.");
        }
        catch (Exception error)
        {
            setMessage($"Delete failed: {error.Message}");
        }
        Notify();
    }

    public void RecordCaptureSample(WindowsCaptureSample sample)
    {
        var timestamp = sample.CapturedAt.ToUnixTimeSeconds();
        if (timestamp - _lastCaptureEventTimestamp < 60) return;
        _lastCaptureEventTimestamp = timestamp;
        var offsetMinutes = (int)TimeZoneInfo.Local.GetUtcOffset(sample.CapturedAt).TotalMinutes;
        var day = DayflowCoreInterop.LogicalDayKey(timestamp, offsetMinutes);
        var description = DayflowWindowsCapturePolicy.MetadataOnlyDescription(sample.ApplicationId);
        var workspace = ActiveWorkspaceId();
        _syncSession.EnqueueCaptureDerived(
            workspace,
            $"{timestamp}-{sample.Width}x{sample.Height}",
            day,
            timestamp,
            timestamp,
            description.Title,
            description.Summary,
            "activity_capture",
            "windows_graphics_capture",
            "privacy_gated_foreground_metadata");
        Projection = DayflowWindowsProjection.FromJson(_syncSession.ProjectLocal(workspace));
        PendingEventCount = _syncSession.PendingEventCount(workspace);
        Notify();
    }

    public async Task SignOutAsync(CancellationToken cancellationToken = default)
    {
        var accountId = AccountId;
        var token = Token;
        var relayUrl = RelayUrl;
        if (_registeredPushToken is not null
            && !string.IsNullOrWhiteSpace(accountId)
            && !string.IsNullOrWhiteSpace(token)
            && !string.IsNullOrWhiteSpace(relayUrl))
        {
            try
            {
                await _syncSession.UnregisterPushTokenAsync(accountId, token, relayUrl, cancellationToken);
            }
            catch (Exception error)
            {
                System.Diagnostics.Debug.WriteLine($"[DayflowWindows] Push token removal deferred: {error.Message}");
            }
        }
        _pushNotifications.Close();
        _registeredPushToken = null;
        ClearSession();
    }

    public void SignOut() => _ = SignOutAsync();

    private void ClearSession()
    {
        _keyStore.Delete(ActiveSessionAccount, ActiveSessionName);
        AccountId = "";
        Token = "";
        RelayUrl = "";
        Devices = Array.Empty<DayflowWindowsRelayDevice>();
        AuthUrl = "";
        Email = "";
        VerificationCode = "";
        AuthMessage = null;
        Projection = DayflowWindowsProjection.Empty;
        PendingEventCount = 0;
        SyncHealth = DayflowWindowsSyncHealth.Initial;
        JournalDay = "";
        JournalBody = "";
        JournalMessage = null;
        PriorityDay = "";
        PriorityText = "";
        PriorityMessage = null;
        ReflectionDay = "";
        ReflectionBody = "";
        ReflectionMessage = null;
        SharedSettingKey = "dayflow.capture.paused";
        SharedSettingValue = "false";
        SharedSettingMessage = null;
        ChatQuestion = "";
        ChatAnswer = null;
        ChatMessage = null;
        RecoveryKitText = "";
        RecoveryMessage = null;
        IsRotatingKey = false;
        RotationMessage = null;
        _lastCaptureEventTimestamp = 0;
        PrepareLocalWorkspace();
    }

    private async Task TryRegisterPushChannelAsync(
        DayflowWindowsAccountSession session,
        CancellationToken cancellationToken)
    {
        if (_pushNotifications.HasChannel && _registeredPushToken is not null) return;

        try
        {
            var pushToken = await _pushNotifications.RequestChannelUriAsync();
            if (!IsCurrentSession(session)) return;
            await _syncSession.RegisterPushTokenAsync(
                session.AccountId,
                session.Token,
                session.RelayUrl,
                pushToken,
                cancellationToken);
            _registeredPushToken = pushToken;
        }
        catch (Exception error)
        {
            // WNS requires a packaged/identity-enabled Windows release and
            // provider credentials. Local encrypted sync remains useful when
            // that optional wake transport is unavailable.
            System.Diagnostics.Debug.WriteLine($"[DayflowWindows] Push channel unavailable: {error.Message}");
        }
    }

    private string ActiveWorkspaceId()
    {
        if (!string.IsNullOrWhiteSpace(AccountId)
            && !string.IsNullOrWhiteSpace(Token)
            && _keyStore.HasAccountKeyAdmission(AccountId)
            && _syncSession.HasLocalAccountKey(AccountId))
        {
            return AccountId.Trim();
        }
        return DayflowWindowsSyncSession.LocalWorkspaceId;
    }

    private void PrepareLocalWorkspace()
    {
        try
        {
            _syncSession.EnsureLocalWorkspace();
            var workspace = DayflowWindowsSyncSession.LocalWorkspaceId;
            Projection = DayflowWindowsProjection.FromJson(_syncSession.ProjectLocal(workspace));
            PendingEventCount = _syncSession.PendingEventCount(workspace);
            SyncHealth = _syncSession.SyncHealth(workspace);
            JournalDay = DefaultLogicalDay();
            LoadProvider();
            SetStatus("Local workspace · offline");
        }
        catch (Exception error)
        {
            Projection = DayflowWindowsProjection.Empty;
            PendingEventCount = 0;
            SetStatus($"Local workspace is unavailable: {error.Message}");
        }
    }

    private DayflowWindowsAccountSession ValidateSession()
    {
        var account = AccountId.Trim();
        var token = Token.Trim();
        var relay = RelayUrl.Trim();
        var name = DisplayName.Trim();
        if (account.Length == 0 || token.Length == 0 || name.Length == 0) throw new InvalidOperationException("A Dayflow account, session token, and device name are required.");
        if (!Uri.TryCreate(relay, UriKind.Absolute, out var uri)
            || !DayflowWindowsEndpointPolicy.IsAllowed(uri))
            throw new InvalidOperationException("The sync relay must use HTTPS, or loopback HTTP for local development.");
        AccountId = account;
        Token = token;
        RelayUrl = relay;
        DisplayName = name;
        return new DayflowWindowsAccountSession(account, token, AuthUrl.Trim(), Email.Trim().ToLowerInvariant(), relay, name);
    }

    private bool IsCurrentSession(DayflowWindowsAccountSession session) =>
        string.Equals(AccountId, session.AccountId, StringComparison.Ordinal)
        && string.Equals(Token, session.Token, StringComparison.Ordinal);

    private void LoadSession()
    {
        var json = _keyStore.LoadText(ActiveSessionAccount, ActiveSessionName);
        if (!string.IsNullOrWhiteSpace(json))
        {
            try
            {
                var session = JsonSerializer.Deserialize<DayflowWindowsAccountSession>(json);
                if (session is not null)
                {
                    SetAccountFields(session.AccountId, session.Token, session.RelayUrl, session.DisplayName);
                    AuthUrl = session.AuthUrl;
                    Email = session.Email;
                    SetStatus("Ready to sync");
                    JournalDay = DefaultLogicalDay();
                    _syncSession.EnsureLocalWorkspace();
                    var workspace = ActiveWorkspaceId();
                    try
                    {
                        Projection = DayflowWindowsProjection.FromJson(_syncSession.ProjectLocal(workspace));
                        PendingEventCount = _syncSession.PendingEventCount(workspace);
                        SyncHealth = _syncSession.SyncHealth(workspace);
                    }
                    catch (InvalidOperationException) { Projection = DayflowWindowsProjection.Empty; }
                    LoadProvider();
                }
            }
            catch (JsonException) { }
        }
    }

    private void LoadProvider()
    {
        var workspace = ActiveWorkspaceId();
        var configuration = _providerStore.Load(workspace);
        if (configuration is null) return;
        ProviderId = configuration.ProviderId;
        ProviderEndpoint = configuration.Endpoint;
        ProviderModelId = configuration.ModelId;
        ProviderApiKey = _providerStore.LoadApiKey(workspace) ?? "";
    }

    private void SetStatus(string value)
    {
        Status = value;
        Notify();
    }

    private void Notify() => StateChanged?.Invoke(this, EventArgs.Empty);

    private static string DefaultLogicalDay()
    {
        var now = DateTimeOffset.Now;
        return (now.Hour < 4 ? now.Date.AddDays(-1) : now.Date).ToString("yyyy-MM-dd");
    }
}
