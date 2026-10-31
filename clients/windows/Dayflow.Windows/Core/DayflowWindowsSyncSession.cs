using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Dayflow.Windows.Core;

public sealed record DayflowWindowsSyncOutcome(string Status, int Pushed, int Pulled, int NotificationHints = 0);

/// <summary>
/// Complete Windows local-first sync lifecycle. Capture can continue while
/// this session is offline; local SQLite remains the source for the next retry.
/// </summary>
public sealed class DayflowWindowsSyncSession
{
    public const string LocalWorkspaceId = "local-workspace-v1";
    private readonly DayflowWindowsKeyStore _keyStore;
    private readonly string _localDirectory;

    public DayflowWindowsSyncSession(DayflowWindowsKeyStore? keyStore = null)
    {
        _keyStore = keyStore ?? new DayflowWindowsKeyStore();
        _localDirectory = DayflowWindowsStorage.SyncDirectory;
    }

    public void EnsureLocalWorkspace()
    {
        if (_keyStore.LoadAccountKeyRing(LocalWorkspaceId) is null)
            _keyStore.StoreAccountKeyRing(LocalWorkspaceId, DayflowWindowsAccountKeyRing.FromRootKey(DayflowCoreInterop.GenerateAccountRootKey()));
        _keyStore.GetOrCreateDeviceId(LocalWorkspaceId);
    }

    public bool HasLocalAccountKey(string accountId)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(accountId)) EnsureLocalWorkspace();
            return _keyStore.LoadAccountKeyRing(WorkspaceId(accountId)) is not null;
        }
        catch { return false; }
    }

    public int PendingEventCount(string accountId)
    {
        Directory.CreateDirectory(_localDirectory);
        using var store = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(WorkspaceId(accountId))}.sqlite"));
        return store.PendingCount();
    }

    public DayflowWindowsSyncHealth SyncHealth(string accountId)
    {
        Directory.CreateDirectory(_localDirectory);
        using var store = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(WorkspaceId(accountId))}.sqlite"));
        return store.SyncHealth();
    }

    public void RecordSyncHealth(
        string accountId,
        DayflowWindowsSyncHealthState state,
        string? failureCode = null)
    {
        Directory.CreateDirectory(_localDirectory);
        using var store = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(WorkspaceId(accountId))}.sqlite"));
        store.RecordSyncHealth(state, failureCode);
    }

    /// Links signed-out local records into the account outbox. Rekeying stays
    /// inside Rust; the relay only ever receives destination ciphertext.
    public void LinkLocalWorkspace(string accountId)
    {
        if (string.IsNullOrWhiteSpace(accountId)) throw new ArgumentException("A Dayflow account is required.", nameof(accountId));
        EnsureLocalWorkspace();
        Directory.CreateDirectory(_localDirectory);
        using var localStore = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(LocalWorkspaceId)}.sqlite"));
        var linkedAccount = localStore.LinkedAccountId();
        if (linkedAccount is not null && !string.Equals(linkedAccount, accountId, StringComparison.Ordinal))
            throw new InvalidOperationException("This local workspace is already linked to another Dayflow account.");
        var sourceRing = _keyStore.LoadAccountKeyRing(LocalWorkspaceId)
            ?? throw new InvalidOperationException("The local workspace key-ring is not initialized.");
        var destinationRing = _keyStore.LoadAccountKeyRing(accountId)
            ?? throw new InvalidOperationException("The account key-ring is not initialized.");
        using var destinationStore = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(accountId)}.sqlite"));
        var localEnvelopes = localStore.All();
        foreach (var envelope in localEnvelopes)
        {
            var sourceKey = sourceRing.KeyData(envelope.KeyVersion);
            var destinationKey = destinationRing.KeyData(envelope.KeyVersion);
            var candidate = sourceKey is not null
                && destinationKey is not null
                && CryptographicOperations.FixedTimeEquals(sourceKey, destinationKey)
                ? envelope
                : DayflowCoreInterop.Rekey(new[] { envelope }, sourceRing, destinationRing).Single();

            if (destinationStore.Find(envelope.EventId) is { } existing)
            {
                if (!existing.Equals(candidate))
                {
                    var sourceProjection = DayflowCoreInterop.Project(new[] { envelope }, sourceRing);
                    var destinationProjection = DayflowCoreInterop.Project(new[] { existing }, destinationRing);
                    if (!string.Equals(sourceProjection, destinationProjection, StringComparison.Ordinal))
                        throw new InvalidOperationException($"The account workspace already contains a different envelope for event {envelope.EventId}.");
                }
            }
            else
            {
                destinationStore.Enqueue(candidate);
            }
        }
        if (localEnvelopes.Count > 0)
        {
            destinationStore.EnsureLogicalClockAtLeast(localEnvelopes.Max(envelope => envelope.LogicalClock));
        }
        // Keep local ciphertext and its local key-ring; source mirror untouched
        // makes a crash at any point retryable because secure-store and SQLite
        // commits cannot be atomic.
        localStore.SetLinkedAccountId(accountId);
    }

    public async Task<DayflowWindowsSyncOutcome> SyncAsync(
        string accountId,
        string token,
        string relayUrl,
        string displayName,
        bool recoveryMode = false,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(accountId) || string.IsNullOrWhiteSpace(token))
            throw new ArgumentException("A signed-in Dayflow account is required.");

        Directory.CreateDirectory(_localDirectory);
        var deviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        var deviceMaterial = LoadOrCreateMaterial(accountId, "device", DayflowCoreInterop.GenerateDeviceKeyMaterial);
        var signingMaterial = LoadOrCreateMaterial(accountId, "signing", DayflowCoreInterop.GenerateDeviceSigningKeyMaterial);
        using var store = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(accountId)}.sqlite"));
        try
        {
        var client = new DayflowWindowsSyncClient(relayUrl);
        var recoveryRegistration = recoveryMode || IsRecoveryRestorePending(accountId);
        var registration = await client.RegisterAsync(
            deviceId,
            deviceMaterial.PublicKey,
            signingMaterial.PublicKey,
            displayName,
            token,
            recoveryRegistration,
            cancellationToken);
        if (!string.Equals(registration.Status, "approved", StringComparison.Ordinal))
        {
            store.RecordSyncHealth(DayflowWindowsSyncHealthState.WaitingForApproval);
            return new("waiting_for_approval", 0, 0);
        }
        var keyRing = _keyStore.LoadAccountKeyRing(accountId);
        if (registration.KeyBootstrapRequired)
        {
            if (keyRing is null)
            {
                keyRing = DayflowWindowsAccountKeyRing.FromRootKey(DayflowCoreInterop.GenerateAccountRootKey());
                _keyStore.StoreAccountKeyRing(accountId, keyRing);
            }
            // Preserve the relay's explicit first-device admission after the
            // one-time bootstrap grant is consumed by the first event push.
            _keyStore.MarkAccountKeyAdmitted(accountId);
        }
        var wrappedKeys = await client.WrappedKeysAsync(deviceId, token, signingMaterial.PrivateKey, cancellationToken);
        if (keyRing is not null && !registration.KeyBootstrapRequired && !recoveryRegistration && !_keyStore.HasAccountKeyAdmission(accountId) && wrappedKeys.Length == 0)
            throw new InvalidOperationException("This local account key was not admitted by the sync relay. Restore a recovery kit or receive an approved device key before syncing.");
        foreach (var wrapped in wrappedKeys)
        {
            var wrappedJson = Convert.FromBase64String(wrapped.WrappedAccountKey);
            using var wrappedDocument = JsonDocument.Parse(wrappedJson);
            var authenticatedVersion = wrappedDocument.RootElement.TryGetProperty("key_version", out var versionElement)
                ? versionElement.GetUInt32()
                : 1u;
            var recipientDeviceId = wrappedDocument.RootElement.TryGetProperty("recipient_device_id", out var recipientElement)
                ? recipientElement.GetString()
                : null;
            if (wrapped.DeviceId != deviceId || authenticatedVersion != wrapped.KeyVersion || recipientDeviceId != deviceId)
                throw new InvalidOperationException("The relay returned a wrapped account key for a different device or key version.");
            var restored = DayflowCoreInterop.UnwrapAccountKey(
                Encoding.UTF8.GetString(wrappedJson), deviceMaterial.PrivateKey);
            using var json = JsonDocument.Parse(restored);
            var restoredRootKey = Convert.FromBase64String(json.RootElement.GetProperty("root_key").GetString()!);
            if (keyRing is null)
            {
                keyRing = DayflowWindowsAccountKeyRing.FromSingleVersion(authenticatedVersion, restoredRootKey);
            }
            else if (keyRing.KeyData(authenticatedVersion) is { } existingKey)
            {
                if (!CryptographicOperations.FixedTimeEquals(existingKey, restoredRootKey))
                    throw new InvalidOperationException("The relay returned a different account key for an existing key version.");
            }
            else
            {
                keyRing = keyRing.Add(
                    restoredRootKey,
                    authenticatedVersion,
                    authenticatedVersion > keyRing.ActiveKeyVersion);
            }
            _keyStore.StoreAccountKeyRing(accountId, keyRing);
            _keyStore.MarkAccountKeyAdmitted(accountId);
        }
        if (keyRing is null)
        {
            throw new InvalidOperationException(
                "The encrypted account key was not delivered. Restore a Dayflow recovery kit or approve this device from an existing device.");
        }
        var resolvedKeyRing = keyRing ?? throw new InvalidOperationException("The account key-ring is not initialized.");
        if (recoveryRegistration) _keyStore.MarkAccountKeyAdmitted(accountId);

        LinkLocalWorkspace(accountId);

        var pushed = 0;
        while (true)
        {
            var pending = store.Pending();
            if (pending.Count == 0) break;
            var response = await client.PushAsync(deviceId, token, signingMaterial.PrivateKey, pending, cancellationToken);
            var acknowledged = response.AcceptedEventIds.Concat(response.DuplicateEventIds).ToArray();
            pushed += store.Acknowledge(acknowledged);
            if (acknowledged.Length == 0) break;
        }

        var cursor = store.Cursor();
        var pulled = 0;
        while (true)
        {
            var response = await client.PullAsync(deviceId, token, signingMaterial.PrivateKey, cursor, cancellationToken);
            var envelopes = response.Events.Select(item => item.Envelope).ToArray();
            // Authenticate each relay envelope through Rust before SQLite
            // persistence. This also catches a changed ciphertext for an
            // event ID that was already delivered.
            foreach (var envelope in envelopes)
            {
                _ = DayflowCoreInterop.Project(new[] { envelope }, resolvedKeyRing);
            }
            pulled += store.Merge(envelopes);
            cursor = response.Cursor;
            store.SetCursor(cursor);
            if (response.Events.Length == 0) break;
        }
        var notificationHintCount = 0;
        try
        {
            var hints = await client.PullNotificationHintsAsync(
                deviceId,
                token,
                signingMaterial.PrivateKey,
                store.NotificationCursor(),
                cancellationToken);
            notificationHintCount = hints.Hints.Length;
            store.SetNotificationCursor(hints.Cursor);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error)
        {
            // Hints are advisory wake signals. Keep encrypted event sync
            // successful and retry the unchanged hint cursor next time.
            System.Diagnostics.Debug.WriteLine($"[DayflowWindows] Notification hints unavailable: {error.Message}");
        }
        _ = DayflowCoreInterop.Project(store.All(), resolvedKeyRing);
        store.RecordSyncHealth(DayflowWindowsSyncHealthState.Synced);
        // Keep recovery registration enabled until the complete encrypted
        // sync succeeds. A later network, projection, or local-write failure
        // must remain retryable as a recovery restore.
        if (recoveryRegistration) ClearRecoveryRestorePending(accountId);
        return new("synced", pushed, pulled, notificationHintCount);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error)
        {
            try { store.RecordSyncHealth(DayflowWindowsSyncHealthState.Failed, SyncFailureCode(error)); }
            catch { /* Preserve the original sync failure if local diagnostics cannot be written. */ }
            throw;
        }
    }

    public async Task<IReadOnlyList<DayflowWindowsRelayDevice>> ListDevicesAsync(
        string token,
        string relayUrl,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(token)) throw new ArgumentException("A signed-in Dayflow account is required.", nameof(token));
        return await new DayflowWindowsSyncClient(relayUrl).ListAsync(token, cancellationToken);
    }

    public async Task<DayflowWindowsPushRegistrationResult> RegisterPushTokenAsync(
        string accountId,
        string token,
        string relayUrl,
        string pushToken,
        CancellationToken cancellationToken = default)
    {
        var signingMaterial = LoadOrCreateMaterial(accountId, "signing", DayflowCoreInterop.GenerateDeviceSigningKeyMaterial);
        var deviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        return await new DayflowWindowsSyncClient(relayUrl).RegisterPushTokenAsync(
            deviceId,
            token,
            signingMaterial.PrivateKey,
            pushToken,
            cancellationToken);
    }

    public async Task<DayflowWindowsPushRegistrationResult> UnregisterPushTokenAsync(
        string accountId,
        string token,
        string relayUrl,
        CancellationToken cancellationToken = default)
    {
        var signingMaterial = LoadOrCreateMaterial(accountId, "signing", DayflowCoreInterop.GenerateDeviceSigningKeyMaterial);
        var deviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        return await new DayflowWindowsSyncClient(relayUrl).UnregisterPushTokenAsync(
            deviceId,
            token,
            signingMaterial.PrivateKey,
            cancellationToken);
    }

    public async Task<DayflowWindowsRelayDevice> ApproveDeviceAsync(
        string accountId,
        string token,
        string relayUrl,
        string targetDeviceId,
        uint? keyVersion = null,
        CancellationToken cancellationToken = default)
    {
        var keyRing = _keyStore.LoadAccountKeyRing(accountId)
            ?? throw new InvalidOperationException("The account key-ring is not initialized.");
        var client = new DayflowWindowsSyncClient(relayUrl);
        var target = (await client.ListAsync(token, cancellationToken)).FirstOrDefault(device => device.DeviceId == targetDeviceId)
            ?? throw new InvalidOperationException("The target device is not registered.");
        var targetPublicKey = Convert.FromBase64String(target.PublicKey);
        var approverDeviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        var signingMaterial = LoadOrCreateMaterial(accountId, "signing", DayflowCoreInterop.GenerateDeviceSigningKeyMaterial);
        var versions = keyVersion is uint selected
            ? new[] { selected }
            : keyRing.Versions();
        if (versions.Count == 0) throw new InvalidOperationException("No account key versions are retained on this device.");
        DayflowWindowsRelayDevice? approved = null;
        foreach (var version in versions)
        {
            var rootKey = keyRing.KeyData(version)
                ?? throw new InvalidOperationException("The requested account key version is not retained on this device.");
            var wrappedJson = DayflowCoreInterop.WrapAccountKey(rootKey, version, targetDeviceId, targetPublicKey);
            approved = await client.ApproveAsync(
                targetDeviceId,
                token,
                approverDeviceId,
                signingMaterial.PrivateKey,
                version,
                wrappedJson,
                cancellationToken);
        }
        return approved ?? throw new InvalidOperationException("The device approval did not return a device.");
    }

    /// <summary>
    /// Delivers a new account key to every approved peer before activating it
    /// locally. The retained key-ring continues to decrypt historical events.
    /// </summary>
    public async Task<uint> RotateEncryptionKeyAsync(
        string accountId,
        string token,
        string relayUrl,
        CancellationToken cancellationToken = default)
    {
        var currentKeyRing = _keyStore.LoadAccountKeyRing(accountId)
            ?? throw new InvalidOperationException("The account key-ring is not initialized.");
        var signingMaterial = LoadOrCreateMaterial(accountId, "signing", DayflowCoreInterop.GenerateDeviceSigningKeyMaterial);
        var actorDeviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        var pendingKeyRing = _keyStore.LoadPendingAccountKeyRing(accountId);
        DayflowWindowsAccountKeyRing candidateKeyRing;
        if (pendingKeyRing is not null && pendingKeyRing.ActiveKeyVersion > currentKeyRing.ActiveKeyVersion)
        {
            candidateKeyRing = pendingKeyRing;
        }
        else
        {
            _keyStore.ClearPendingAccountKeyRing(accountId);
            var currentVersion = currentKeyRing.Versions().Max();
            if (currentVersion == uint.MaxValue)
                throw new InvalidOperationException("The account key version limit has been reached.");

            var nextVersion = currentVersion + 1;
            var nextRootKey = DayflowCoreInterop.GenerateAccountRootKey();
            candidateKeyRing = currentKeyRing.Add(nextRootKey, nextVersion, active: true);
            _keyStore.StorePendingAccountKeyRing(accountId, candidateKeyRing);
        }
        var nextVersionToDeliver = candidateKeyRing.ActiveKeyVersion;
        var nextRootKeyToDeliver = candidateKeyRing.KeyData(nextVersionToDeliver)
            ?? throw new InvalidOperationException("The pending account key-ring is invalid.");
        var client = new DayflowWindowsSyncClient(relayUrl);
        var peers = (await client.ListAsync(token, cancellationToken))
            .Where(device => device.Status == "approved" && device.DeviceId != actorDeviceId)
            .ToArray();

        foreach (var peer in peers)
        {
            var peerPublicKey = Convert.FromBase64String(peer.PublicKey);
            var wrappedJson = DayflowCoreInterop.WrapAccountKey(
                nextRootKeyToDeliver,
                nextVersionToDeliver,
                peer.DeviceId,
                peerPublicKey);
            _ = await client.ApproveAsync(
                peer.DeviceId,
                token,
                actorDeviceId,
                signingMaterial.PrivateKey,
                nextVersionToDeliver,
                wrappedJson,
                cancellationToken);
        }

        _keyStore.StoreAccountKeyRing(accountId, candidateKeyRing);
        _keyStore.ClearPendingAccountKeyRing(accountId);
        return nextVersionToDeliver;
    }

    public async Task<DayflowWindowsRelayDevice> RevokeDeviceAsync(
        string accountId,
        string token,
        string relayUrl,
        string targetDeviceId,
        CancellationToken cancellationToken = default)
    {
        var approverDeviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        var signingMaterial = LoadOrCreateMaterial(accountId, "signing", DayflowCoreInterop.GenerateDeviceSigningKeyMaterial);
        return await new DayflowWindowsSyncClient(relayUrl).RevokeAsync(
            targetDeviceId,
            token,
            approverDeviceId,
            signingMaterial.PrivateKey,
            cancellationToken);
    }

    public void EnqueueSealedEvent(
        string accountId,
        string payloadJson,
        string eventId,
        string deviceId,
        ulong logicalClock,
        byte[] accountRootKey,
        uint keyVersion = 1)
    {
        var workspace = WorkspaceId(accountId);
        Directory.CreateDirectory(_localDirectory);
        using var store = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(workspace)}.sqlite"));
        store.Enqueue(DayflowCoreInterop.Seal(payloadJson, eventId, deviceId, logicalClock, keyVersion, accountRootKey));
    }

    public void EnqueueCaptureDerived(
        string accountId,
        string captureId,
        string day,
        long startTimestamp,
        long endTimestamp,
        string title,
        string summary,
        string category,
        string source = "windows_graphics_capture",
        string derivationMode = "privacy_gated_local_context_v1")
    {
        if (string.IsNullOrWhiteSpace(captureId) || string.IsNullOrWhiteSpace(day)) throw new ArgumentException("Capture identity and logical day are required.");
        if (string.IsNullOrWhiteSpace(source) || string.IsNullOrWhiteSpace(derivationMode)) throw new ArgumentException("Capture provenance is required.");
        // Capture remains local until the account key was explicitly
        // admitted. Do not trust a stale caller-provided account ID to bypass
        // the approval boundary.
        var workspace = CaptureWorkspaceId(accountId);
        var keyRing = _keyStore.LoadAccountKeyRing(workspace)
            ?? throw new InvalidOperationException("The account key-ring is not initialized.");
        var rootKey = keyRing.KeyData(keyRing.ActiveKeyVersion)
            ?? throw new InvalidOperationException("The active account key is not initialized.");
        var deviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        Directory.CreateDirectory(_localDirectory);
        using var store = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(workspace)}.sqlite"));
        var payload = JsonSerializer.Serialize(new
        {
            kind = "CaptureDerived",
            value = new
            {
                id = $"{deviceId}:capture:{captureId}",
                day,
                start_timestamp = startTimestamp,
                end_timestamp = endTimestamp,
                title,
                summary,
                category,
                source,
                derivation_mode = derivationMode,
            },
        });
        store.Enqueue(DayflowCoreInterop.Seal(
            payload,
            $"{deviceId}:capture:{captureId}",
            deviceId,
            store.NextLogicalClock(),
            keyRing.ActiveKeyVersion,
            rootKey));
    }

    public void EnqueueJournal(string accountId, string day, string body)
    {
        var normalizedBody = body.Trim();
        if (string.IsNullOrWhiteSpace(day) || string.IsNullOrWhiteSpace(normalizedBody))
            throw new ArgumentException("A logical day and journal body are required.");
        var workspace = WorkspaceId(accountId);
        var keyRing = _keyStore.LoadAccountKeyRing(workspace)
            ?? throw new InvalidOperationException("The account key-ring is not initialized.");
        var rootKey = keyRing.KeyData(keyRing.ActiveKeyVersion)
            ?? throw new InvalidOperationException("The active account key is not initialized.");
        var deviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        Directory.CreateDirectory(_localDirectory);
        using var store = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(workspace)}.sqlite"));
        var eventId = $"{deviceId}:journal:{Guid.NewGuid():N}";
        var aggregateId = $"mac:v1:journal:{day}";
        var payload = JsonSerializer.Serialize(new
        {
            kind = "JournalUpsert",
            value = new { id = aggregateId, day, body = normalizedBody },
        });
        store.Enqueue(DayflowCoreInterop.Seal(
            payload,
            eventId,
            deviceId,
            store.NextLogicalClock(),
            keyRing.ActiveKeyVersion,
            rootKey));
    }

    public void EnqueuePriority(
        string accountId,
        string day,
        string text,
        int rank,
        string status = "open",
        string? stableId = null)
    {
        var normalizedDay = day.Trim();
        var normalizedText = text.Trim();
        var normalizedStatus = string.IsNullOrWhiteSpace(status) ? "open" : status.Trim();
        if (string.IsNullOrWhiteSpace(normalizedDay) || string.IsNullOrWhiteSpace(normalizedText))
            throw new ArgumentException("A logical day and priority text are required.");
        if (rank < 0) throw new ArgumentOutOfRangeException(nameof(rank));
        var deviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        var aggregateId = string.IsNullOrWhiteSpace(stableId)
            ? $"dayflow:v1:priority:{Guid.NewGuid():N}"
            : stableId.Trim();
        var payload = JsonSerializer.Serialize(new
        {
            kind = "PriorityUpsert",
            value = new
            {
                id = aggregateId,
                day = normalizedDay,
                rank,
                text = normalizedText,
                status = normalizedStatus,
            },
        });
        EnqueuePayload(accountId, payload, $"{deviceId}:priority:{Guid.NewGuid():N}");
    }

    public void EnqueueReflection(string accountId, string day, string body)
    {
        var normalizedDay = day.Trim();
        var normalizedBody = body.Trim();
        if (string.IsNullOrWhiteSpace(normalizedDay) || string.IsNullOrWhiteSpace(normalizedBody))
            throw new ArgumentException("A logical day and reflection body are required.");
        var deviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        var payload = JsonSerializer.Serialize(new
        {
            kind = "ReflectionUpsert",
            value = new
            {
                id = $"mac:v1:reflection:{normalizedDay}",
                day = normalizedDay,
                body = normalizedBody,
            },
        });
        EnqueuePayload(accountId, payload, $"{deviceId}:reflection:{Guid.NewGuid():N}");
    }

    /// Append a deletion operation for a stable projection aggregate. The
    /// tombstone is encrypted and replayed like every other user edit.
    public void EnqueueTombstone(string accountId, string targetId)
    {
        var normalizedTargetId = targetId.Trim();
        if (string.IsNullOrWhiteSpace(normalizedTargetId))
            throw new ArgumentException("A tombstone target is required.", nameof(targetId));
        var deviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        var payload = JsonSerializer.Serialize(new
        {
            kind = "Tombstone",
            value = new { target_id = normalizedTargetId },
        });
        EnqueuePayload(accountId, payload, $"{deviceId}:tombstone:{Guid.NewGuid():N}");
    }

    public void EnqueueSetting(string accountId, string key, string value)
    {
        var normalizedKey = key.Trim();
        var normalizedValue = value.Trim();
        if (string.IsNullOrWhiteSpace(normalizedKey)
            || !DayflowWindowsSharedSettingContract.IsAllowedKey(normalizedKey))
            throw new ArgumentException("Only non-secret Dayflow settings can be shared.");
        if (normalizedKey == "dayflow.capture.paused"
            && normalizedValue != "true"
            && normalizedValue != "false")
            throw new ArgumentException("Capture pause must be true or false.");
        var deviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        var payload = JsonSerializer.Serialize(new
        {
            kind = "SettingUpsert",
            value = new
            {
                key = normalizedKey,
                value = normalizedValue,
            },
        });
        EnqueuePayload(accountId, payload, $"{deviceId}:setting:{Guid.NewGuid():N}");
    }

    private void EnqueuePayload(string accountId, string payload, string eventId)
    {
        var workspace = WorkspaceId(accountId);
        var keyRing = _keyStore.LoadAccountKeyRing(workspace)
            ?? throw new InvalidOperationException("The account key-ring is not initialized.");
        var rootKey = keyRing.KeyData(keyRing.ActiveKeyVersion)
            ?? throw new InvalidOperationException("The active account key is not initialized.");
        var deviceId = Encoding.UTF8.GetString(_keyStore.GetOrCreateDeviceId(LocalWorkspaceId));
        Directory.CreateDirectory(_localDirectory);
        using var store = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(workspace)}.sqlite"));
        store.Enqueue(DayflowCoreInterop.Seal(
            payload,
            eventId,
            deviceId,
            store.NextLogicalClock(),
            keyRing.ActiveKeyVersion,
            rootKey));
    }

    public string ProjectLocal(string accountId)
    {
        var workspace = WorkspaceId(accountId);
        var keyRing = _keyStore.LoadAccountKeyRing(workspace)
            ?? throw new InvalidOperationException("The account key-ring is not initialized.");
        Directory.CreateDirectory(_localDirectory);
        using var store = new DayflowLocalSyncStore(Path.Combine(_localDirectory, $"{Hash(workspace)}.sqlite"));
        return DayflowCoreInterop.Project(store.All(), keyRing);
    }

    public string ExportRecoveryKit(string accountId, string passphrase)
    {
        var keyRing = _keyStore.LoadAccountKeyRing(accountId)
            ?? throw new InvalidOperationException("The account key-ring is not initialized.");
        return DayflowCoreInterop.ExportRecoveryKit(keyRing, passphrase);
    }

    public void RestoreRecoveryKit(string accountId, string kitJson, string passphrase)
    {
        DayflowWindowsAccountKeyRing keyRing;
        try
        {
            keyRing = DayflowCoreInterop.RestoreRecoveryKeyRing(kitJson, passphrase);
        }
        catch
        {
            keyRing = DayflowWindowsAccountKeyRing.FromRootKey(
                DayflowCoreInterop.RestoreRecoveryKey(kitJson, passphrase));
        }
        _keyStore.StoreAccountKeyRing(accountId, keyRing);
        MarkRecoveryRestorePending(accountId);
    }

    private static string RecoveryRestorePendingKey(string accountId) => $"dayflow.recovery-restore-pending.{Hash(accountId)}";

    private bool IsRecoveryRestorePending(string accountId) =>
        string.Equals(
            _keyStore.LoadText(accountId, RecoveryRestorePendingKey(accountId)),
            "true",
            StringComparison.Ordinal);

    private void MarkRecoveryRestorePending(string accountId) =>
        _keyStore.StoreText(accountId, RecoveryRestorePendingKey(accountId), "true");

    private void ClearRecoveryRestorePending(string accountId) =>
        _keyStore.Delete(accountId, RecoveryRestorePendingKey(accountId));

    private (byte[] PrivateKey, byte[] PublicKey) LoadOrCreateMaterial(
        string accountId,
        string prefix,
        Func<string> generator)
    {
        var privateKey = _keyStore.Load(accountId, $"{prefix}-private-v1");
        var publicKey = _keyStore.Load(accountId, $"{prefix}-public-v1");
        if (privateKey is { Length: 32 } && publicKey is { Length: 32 }) return (privateKey, publicKey);
        using var json = JsonDocument.Parse(generator());
        privateKey = Convert.FromBase64String(json.RootElement.GetProperty("private_key").GetString()!);
        publicKey = Convert.FromBase64String(json.RootElement.GetProperty("public_key").GetString()!);
        _keyStore.Store(accountId, $"{prefix}-private-v1", privateKey);
        _keyStore.Store(accountId, $"{prefix}-public-v1", publicKey);
        return (privateKey, publicKey);
    }

    private static string Hash(string accountId) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(accountId))).ToLowerInvariant();

    private static string SyncFailureCode(Exception error) => error switch
    {
        DayflowWindowsRelayException relay when relay.RelayStatusCode is 401 or 403 => "authentication",
        DayflowWindowsRelayException relay when relay.RelayStatusCode == 409 => "admission",
        DayflowWindowsRelayException relay when relay.RelayStatusCode >= 500 => "relay_server",
        DayflowWindowsRelayException => "invalid_response",
        Microsoft.Data.Sqlite.SqliteException => "local_storage",
        JsonException => "invalid_response",
        IOException => "relay_server",
        _ => "unknown",
    };

    private string CaptureWorkspaceId(string accountId)
    {
        var normalized = accountId?.Trim() ?? string.Empty;
        return !string.IsNullOrWhiteSpace(normalized)
            && _keyStore.HasAccountKeyAdmission(normalized)
            ? normalized
            : LocalWorkspaceId;
    }

    private static string WorkspaceId(string accountId) => string.IsNullOrWhiteSpace(accountId)
        ? LocalWorkspaceId
        : accountId.Trim();
}
