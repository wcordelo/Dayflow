using Microsoft.Win32;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Dayflow.Windows.Capture;
using Dayflow.Windows.Core;

namespace Dayflow.Windows;

public sealed partial class MainWindow : Window
{
    private readonly WindowsCaptureDevice? _captureDevice;
    private readonly WindowsGraphicsCaptureFramePipeline? _capturePipeline;
    private readonly WindowsCaptureAdapter _captureAdapter;
    private readonly DayflowWindowsAppModel _appModel;
    private bool _isApplyingState;

    public MainWindow()
    {
        InitializeComponent();

        WindowsCaptureDevice? captureDevice = null;
        WindowsGraphicsCaptureFramePipeline? capturePipeline = null;
        try
        {
            captureDevice = new WindowsCaptureDevice();
            capturePipeline = new WindowsGraphicsCaptureFramePipeline(captureDevice.Direct3DDevice);
        }
        catch
        {
            captureDevice?.Dispose();
        }

        _captureDevice = captureDevice;
        _capturePipeline = capturePipeline;
        _captureAdapter = new WindowsCaptureAdapter(this, capturePipeline);
        _captureAdapter.StatusChanged += CaptureAdapter_StatusChanged;
        _captureAdapter.SampleArrived += CaptureAdapter_SampleArrived;
        _appModel = new DayflowWindowsAppModel();
        _appModel.StateChanged += AppModel_StateChanged;
        Activated += MainWindow_Activated;
        SystemEvents.SessionSwitch += SystemEvents_SessionSwitch;
        SystemEvents.PowerModeChanged += SystemEvents_PowerModeChanged;
        ApplyAppModelState();
        UpdateStatus(_captureAdapter.Status);
        Closed += (_, _) =>
        {
            SystemEvents.SessionSwitch -= SystemEvents_SessionSwitch;
            SystemEvents.PowerModeChanged -= SystemEvents_PowerModeChanged;
            Activated -= MainWindow_Activated;
            _captureAdapter.Stop();
            _capturePipeline?.Dispose();
            _captureDevice?.Dispose();
        };
    }

    private async void StartCapture_Click(object sender, RoutedEventArgs e)
    {
        if (!_appModel.CanCapture)
        {
            CaptureDetailText.Text = "Dayflow cannot access its local secure workspace yet.";
            return;
        }
        await _captureAdapter.StartAsync();
    }

    private void StopCapture_Click(object sender, RoutedEventArgs e)
    {
        _captureAdapter.Stop();
    }

    private void SaveJournal_Click(object sender, RoutedEventArgs e)
    {
        _appModel.SetJournalFields(JournalDayTextBox.Text, JournalBodyTextBox.Text);
        _appModel.AddJournalEntry();
        ApplyAppModelState();
    }

    private void SavePriority_Click(object sender, RoutedEventArgs e)
    {
        _appModel.SetPriorityFields(PriorityDayTextBox.Text, PriorityTextTextBox.Text);
        _appModel.AddPriority();
        ApplyAppModelState();
    }

    private void SaveReflection_Click(object sender, RoutedEventArgs e)
    {
        _appModel.SetReflectionFields(ReflectionDayTextBox.Text, ReflectionBodyTextBox.Text);
        _appModel.AddReflection();
        ApplyAppModelState();
    }

    private void SaveSharedSetting_Click(object sender, RoutedEventArgs e)
    {
        _appModel.SetSharedSettingFields(SharedSettingKeyTextBox.Text, SharedSettingValueTextBox.Text);
        _appModel.SaveSharedSetting();
        ApplyAppModelState();
    }

    private async void Sync_Click(object sender, RoutedEventArgs e)
    {
        ReadAppModelFields();
        try { await _appModel.SyncAsync(); }
        catch (Exception error) { SyncStatusText.Text = error.Message; }
    }

    private async void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated) return;
        try { await _appModel.SyncIfConfiguredAsync(); }
        catch (Exception error) { SyncStatusText.Text = error.Message; }
    }

    private async void SendSignInCode_Click(object sender, RoutedEventArgs e)
    {
        ReadAuthFields();
        try { await _appModel.RequestSignInCodeAsync(); }
        catch (Exception error) { AuthMessageText.Text = error.Message; }
    }

    private async void VerifySignInCode_Click(object sender, RoutedEventArgs e)
    {
        ReadAuthFields();
        ReadAppModelFields();
        try { await _appModel.VerifySignInCodeAsync(); }
        catch (Exception error) { AuthMessageText.Text = error.Message; }
    }

    private async void RefreshDevices_Click(object sender, RoutedEventArgs e)
    {
        ReadAppModelFields();
        try { await _appModel.RefreshDevicesAsync(); }
        catch (Exception error) { SyncStatusText.Text = error.Message; }
    }

    private async void RotateEncryptionKey_Click(object sender, RoutedEventArgs e)
    {
        ReadAppModelFields();
        try { await _appModel.RotateEncryptionKeyAsync(); }
        catch (Exception error) { SyncStatusText.Text = error.Message; }
        ApplyAppModelState();
    }

    private async void SignOut_Click(object sender, RoutedEventArgs e)
    {
        // Capture emits account-scoped derived events. Stop the native
        // Windows.Graphics.Capture session before clearing the account.
        _captureAdapter.Stop();
        await _appModel.SignOutAsync();
        ApplyAppModelState();
    }

    private void SaveProvider_Click(object sender, RoutedEventArgs e)
    {
        ReadProviderFields();
        _appModel.SaveProvider();
        ApplyAppModelState();
    }

    private void SavePrivacy_Click(object sender, RoutedEventArgs e)
    {
        _appModel.SetPrivacyFields(
            BlockedApplicationsTextBox.Text,
            BlockedWindowTitlesTextBox.Text);
        _appModel.SavePrivacyPreferences();
        ApplyAppModelState();
    }

    private void SharedCapturePauseToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_isApplyingState) return;
        _appModel.SetSharedSettingFields(
            "dayflow.capture.paused",
            SharedCapturePauseToggle.IsOn ? "true" : "false");
        _appModel.SaveSharedSetting();
        ApplyAppModelState();
    }

    private void ProductNavigation_SelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item
            || item.Tag is not string tag)
        {
            return;
        }

        TodayPage.Visibility = tag == "today" ? Visibility.Visible : Visibility.Collapsed;
        TimelinePage.Visibility = tag == "timeline" ? Visibility.Visible : Visibility.Collapsed;
        WeekPage.Visibility = tag == "week" ? Visibility.Visible : Visibility.Collapsed;
        JournalPage.Visibility = tag == "journal" ? Visibility.Visible : Visibility.Collapsed;
        ChatPage.Visibility = tag == "chat" ? Visibility.Visible : Visibility.Collapsed;
        SettingsPage.Visibility = tag == "settings" ? Visibility.Visible : Visibility.Collapsed;
        AccountPage.Visibility = tag == "account" ? Visibility.Visible : Visibility.Collapsed;
        RecoveryPage.Visibility = tag == "recovery" ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void AskChat_Click(object sender, RoutedEventArgs e)
    {
        ReadProviderFields();
        _appModel.SetChatQuestion(ChatQuestionTextBox.Text);
        try { await _appModel.AskChatAsync(); }
        catch (Exception error) { ChatMessageText.Text = error.Message; }
        ApplyAppModelState();
    }

    private void ExportRecoveryKit_Click(object sender, RoutedEventArgs e)
    {
        var kit = _appModel.ExportRecoveryKit(RecoveryPassphraseTextBox.Password);
        if (kit is not null) RecoveryKitTextBox.Text = kit;
        RecoveryPassphraseTextBox.Password = "";
        ApplyAppModelState();
    }

    private void RestoreRecoveryKit_Click(object sender, RoutedEventArgs e)
    {
        _appModel.SetRecoveryKitText(RecoveryKitTextBox.Text);
        _appModel.RestoreRecoveryKit(RecoveryKitTextBox.Text, RecoveryPassphraseTextBox.Password);
        RecoveryPassphraseTextBox.Password = "";
        ApplyAppModelState();
    }

    private void CaptureAdapter_StatusChanged(object? sender, WindowsCaptureStatus status)
    {
        DispatcherQueue.TryEnqueue(() => UpdateStatus(status));
    }

    private void CaptureAdapter_SampleArrived(object? sender, WindowsCaptureSample sample)
    {
        // GraphicsCapture raises callbacks away from the WinUI thread. Queue
        // the already-throttled metadata sample so the account model and its
        // SQLite outbox are never mutated concurrently with button actions.
        DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                _appModel.RecordCaptureSample(sample);
                ApplyAppModelState();
            }
            catch (Exception error)
            {
                SyncStatusText.Text = $"Local capture event was not queued: {error.Message}";
            }
        });
    }

    private void SystemEvents_SessionSwitch(object? sender, SessionSwitchEventArgs args)
    {
        var locked = args.Reason == SessionSwitchReason.SessionLock;
        var unlocked = args.Reason == SessionSwitchReason.SessionUnlock;
        if (!locked && !unlocked) return;
        DispatcherQueue.TryEnqueue(() => _captureAdapter.UpdateSystemLifecycle(locked, sleeping: false));
    }

    private void SystemEvents_PowerModeChanged(object? sender, PowerModeChangedEventArgs args)
    {
        if (args.Mode == PowerModes.Suspend)
        {
            DispatcherQueue.TryEnqueue(() => _captureAdapter.UpdateSystemLifecycle(deviceLocked: false, sleeping: true));
        }
        else if (args.Mode == PowerModes.Resume)
        {
            DispatcherQueue.TryEnqueue(() => _captureAdapter.UpdateSystemLifecycle(deviceLocked: false, sleeping: false));
        }
    }

    private void AppModel_StateChanged(object? sender, EventArgs e)
    {
        DispatcherQueue.TryEnqueue(ApplyAppModelState);
    }

    private void ReadAppModelFields()
    {
        _appModel.SetAccountFields(AccountIdTextBox.Text, _appModel.Token, RelayUrlTextBox.Text, DisplayNameTextBox.Text);
    }

    private void ReadAuthFields()
    {
        _appModel.SetAuthFields(AuthUrlTextBox.Text, EmailTextBox.Text, VerificationCodeTextBox.Text);
    }

    private void ReadProviderFields()
    {
        _appModel.SetProviderFields(ProviderIdTextBox.Text, ProviderEndpointTextBox.Text, ProviderModelTextBox.Text, ProviderApiKeyPasswordBox.Password);
    }

    private void ApplyAppModelState()
    {
        _isApplyingState = true;
        _captureAdapter.UpdateSharedCapturePause(
            _appModel.Projection.Settings.TryGetValue("dayflow.capture.paused", out var sharedPauseValue)
                ? sharedPauseValue
                : null);
        _captureAdapter.UpdatePrivacyPreferences(
            DayflowWindowsCapturePolicy.ParseList(_appModel.BlockedApplicationIds),
            DayflowWindowsCapturePolicy.ParseList(_appModel.BlockedWindowTitleFragments));
        SharedCapturePauseToggle.IsOn = _appModel.SharedSettingValue.Trim().Equals("true", StringComparison.OrdinalIgnoreCase);
        AccountIdTextBox.Text = _appModel.AccountId;
        AuthUrlTextBox.Text = _appModel.AuthUrl;
        EmailTextBox.Text = _appModel.Email;
        VerificationCodeTextBox.Text = _appModel.VerificationCode;
        AuthMessageText.Text = _appModel.AuthMessage ?? "";
        RelayUrlTextBox.Text = _appModel.RelayUrl;
        DisplayNameTextBox.Text = _appModel.DisplayName;
        SyncStatusText.Text = _appModel.Status;
        SyncHealthText.Text = _appModel.SyncHealthSummary;
        UpdateCaptureStatusFields();
        StartCaptureButton.IsEnabled = _appModel.CanCapture && _captureAdapter.CanStart;
        StopCaptureButton.IsEnabled = !_captureAdapter.CanStart;
        RotationMessageText.Text = _appModel.RotationMessage ?? "";
        RotateEncryptionKeyButton.IsEnabled = !_appModel.IsRotatingKey
            && !string.IsNullOrWhiteSpace(_appModel.AccountId)
            && !string.IsNullOrWhiteSpace(_appModel.Token);
        ProviderIdTextBox.Text = _appModel.ProviderId;
        ProviderEndpointTextBox.Text = _appModel.ProviderEndpoint;
        ProviderModelTextBox.Text = _appModel.ProviderModelId;
        ProviderApiKeyPasswordBox.Password = _appModel.ProviderApiKey;
        ProviderMessageText.Text = _appModel.ProviderMessage ?? "";
        BlockedApplicationsTextBox.Text = _appModel.BlockedApplicationIds;
        BlockedWindowTitlesTextBox.Text = _appModel.BlockedWindowTitleFragments;
        PrivacyMessageText.Text = _appModel.PrivacyMessage ?? "";
        var localState = _appModel.PendingEventCount > 0
            ? $"{_appModel.PendingEventCount} encrypted event(s) pending sync"
            : _appModel.AccountId.Length == 0
                ? "stored on this device; connect an account to sync"
                : "projection is up to date with the last sync";
        ProjectionSummaryText.Text = $"{_appModel.Projection.TimelineCardCount} timeline cards · {_appModel.Projection.JournalEntryCount} journal entries · {_appModel.Projection.PriorityCount} priorities · {_appModel.Projection.ReflectionCount} reflections · {_appModel.Projection.Settings.Count} shared settings · Local record state: {localState}";
        WeekSummaryText.Text = $"{_appModel.Projection.TimelineCardCount} cards across {_appModel.Projection.TimelineCards.Values.Select(card => card.Day).Distinct().Count()} logical days · {_appModel.Projection.JournalEntryCount} journal entries · {_appModel.Projection.ReflectionCount} reflections.";
        JournalDayTextBox.Text = _appModel.JournalDay;
        JournalBodyTextBox.Text = _appModel.JournalBody;
        JournalMessageText.Text = _appModel.JournalMessage ?? "";
        PriorityDayTextBox.Text = _appModel.PriorityDay;
        PriorityTextTextBox.Text = _appModel.PriorityText;
        PriorityMessageText.Text = _appModel.PriorityMessage ?? "";
        ReflectionDayTextBox.Text = _appModel.ReflectionDay;
        ReflectionBodyTextBox.Text = _appModel.ReflectionBody;
        ReflectionMessageText.Text = _appModel.ReflectionMessage ?? "";
        SharedSettingKeyTextBox.Text = _appModel.SharedSettingKey;
        SharedSettingValueTextBox.Text = _appModel.SharedSettingValue;
        SharedSettingMessageText.Text = _appModel.SharedSettingMessage ?? "";
        ChatQuestionTextBox.Text = _appModel.ChatQuestion;
        ChatMessageText.Text = _appModel.ChatMessage ?? "";
        ChatAnswerText.Text = _appModel.ChatAnswer ?? "";
        RecoveryKitTextBox.Text = _appModel.RecoveryKitText;
        RecoveryMessageText.Text = _appModel.RecoveryMessage ?? "";
        ChatContextPanel.Children.Clear();
        foreach (var item in _appModel.Projection.ChatContext.Take(5))
        {
            ChatContextPanel.Children.Add(new TextBlock
            {
                Text = $"{item.Kind} · {item.Day}\n{item.Content}",
                TextWrapping = TextWrapping.WrapWholeWords,
                Opacity = 0.8,
            });
        }
        TimelineRecordsPanel.Children.Clear();
        foreach (var card in _appModel.Projection.TimelineCards.Values.OrderByDescending(item => item.Day).ThenByDescending(item => item.Id).Take(10))
        {
            TimelineRecordsPanel.Children.Add(RecordRow(
                card.Title,
                $"{card.Day} · {card.Summary}",
                () => _appModel.DeleteTimelineCard(card.Id)));
        }
        JournalRecordsPanel.Children.Clear();
        foreach (var entry in _appModel.Projection.JournalEntries.Values.OrderByDescending(item => item.Day).ThenByDescending(item => item.Id).Take(10))
        {
            JournalRecordsPanel.Children.Add(RecordRow(
                $"Journal · {entry.Day}",
                entry.Body,
                () => _appModel.DeleteJournalEntry(entry.Id)));
        }
        PriorityRecordsPanel.Children.Clear();
        foreach (var priority in _appModel.Projection.Priorities.Values.OrderBy(item => item.Day).ThenBy(item => item.Rank).Take(10))
        {
            PriorityRecordsPanel.Children.Add(RecordRow(
                $"Priority · {priority.Day}",
                priority.Text,
                () => _appModel.DeletePriority(priority.Id)));
        }
        ReflectionRecordsPanel.Children.Clear();
        foreach (var reflection in _appModel.Projection.Reflections.Values.OrderByDescending(item => item.Day).ThenByDescending(item => item.Id).Take(10))
        {
            ReflectionRecordsPanel.Children.Add(RecordRow(
                $"Reflection · {reflection.Day}",
                reflection.Body,
                () => _appModel.DeleteReflection(reflection.Id)));
        }
        DevicesPanel.Children.Clear();
        foreach (var device in _appModel.Devices)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            row.Children.Add(new TextBlock
            {
                Text = $"{device.DisplayName} · {device.Platform} · {device.Status}",
                VerticalAlignment = VerticalAlignment.Center,
            });
            if (device.Status == "pending")
            {
                var approve = new Button { Content = "Approve" };
                approve.Click += async (_, _) =>
                {
                    try { await _appModel.ApproveDeviceAsync(device.DeviceId); }
                    catch (Exception error) { SyncStatusText.Text = error.Message; }
                };
                row.Children.Add(approve);
            }
            else if (device.DeviceId != _appModel.CurrentDeviceId)
            {
                var revoke = new Button { Content = "Revoke" };
                revoke.Click += async (_, _) =>
                {
                    try { await _appModel.RevokeDeviceAsync(device.DeviceId); }
                    catch (Exception error) { SyncStatusText.Text = error.Message; }
                };
                row.Children.Add(revoke);
            }
            DevicesPanel.Children.Add(row);
        }
        _isApplyingState = false;
    }

    private static StackPanel RecordRow(string title, string detail, Action onDelete)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(new TextBlock { Text = title });
        text.Children.Add(new TextBlock
        {
            Text = detail,
            TextWrapping = TextWrapping.WrapWholeWords,
            Opacity = 0.8,
        });
        row.Children.Add(text);
        var delete = new Button { Content = "Delete" };
        delete.Click += (_, _) => onDelete();
        row.Children.Add(delete);
        return row;
    }

    private void UpdateStatus(WindowsCaptureStatus status)
    {
        CaptureStatusText.Text = status.State switch
        {
            WindowsCaptureState.Unsupported => "Unavailable",
            WindowsCaptureState.AwaitingPicker => "Waiting for your selection",
            WindowsCaptureState.Selected => "Selection ready",
            WindowsCaptureState.Running => "Running",
            WindowsCaptureState.Stopped => "Stopped",
            WindowsCaptureState.PermissionRevoked => "Permission revoked",
            WindowsCaptureState.PrivacyPaused => "Privacy pause",
            _ => "Not running",
        };
        CaptureDetailText.Text = status.Detail;
        UpdateCaptureStatusFields();
        StartCaptureButton.IsEnabled = _appModel.CanCapture && _captureAdapter.CanStart;
        StopCaptureButton.IsEnabled = !_captureAdapter.CanStart;
    }

    private void UpdateCaptureStatusFields()
    {
        var fields = _captureAdapter.StatusFields(_appModel.SyncHealthSummary);
        CapturePermissionText.Text = $"Capture permission: {fields.CapturePermission}";
        CaptureSessionText.Text = $"Capture session: {fields.CaptureSession}";
        CapturePausedText.Text = $"Capture paused: {fields.CapturePaused}";
        DerivedSyncText.Text = $"Derived sync: {fields.DerivedSync}";
    }
}
