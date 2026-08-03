using System.Text.Json;
using Dayflow.Windows.Capture;
using Dayflow.Windows.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Dayflow.Windows.Tests;

[TestClass]
public sealed class DayflowCoreInteropTests
{
    [TestMethod]
    public void EnvelopeShapeMatchesTheRustWireContract()
    {
        Assert.IsTrue(DayflowEventEnvelope.HasValidEncryptedFieldShape(
            new string('A', 32),
            new string('A', 24)));
        Assert.IsTrue(DayflowEventEnvelope.HasValidEncryptedFieldShape(
            new string('_', 31) + "-",
            new string('_', 21) + "w"));
        Assert.IsFalse(DayflowEventEnvelope.HasValidEncryptedFieldShape(
            "bm9uY2U",
            "Y2lwaGVydGV4dA"));
    }

    [TestMethod]
    public void CAbiSealsAndProjectsAnEvent()
    {
        var rootKey = Enumerable.Repeat((byte)7, 32).ToArray();
        const string payload = "{\"kind\":\"JournalUpsert\",\"value\":{\"id\":\"windows-binding-smoke\",\"day\":\"2026-08-01\",\"body\":\"Rust binding smoke test\"}}";

        var envelope = DayflowCoreInterop.Seal(
            payload,
            "windows-binding-smoke-event",
            "windows-binding-smoke-device",
            logicalClock: 1,
            rootKey);

        Assert.AreEqual(DayflowEventEnvelope.CurrentSchemaVersion, envelope.SchemaVersion);
        Assert.AreEqual(1u, envelope.KeyVersion);
        var projection = DayflowCoreInterop.Project(new[] { envelope }, rootKey);

        StringAssert.Contains(projection, "windows-binding-smoke");
        StringAssert.Contains(projection, "Rust binding smoke test");
    }

    [TestMethod]
    public void CAbiAppliesTheSharedPrivacyDecision()
    {
        var decision = DayflowCoreInterop.CaptureDecision(
            permissionGranted: true,
            userPaused: false,
            deviceLocked: false,
            sleeping: false,
            privateContext: true,
            drmContent: false);

        Assert.IsFalse(decision.Allowed);
        Assert.AreEqual("private_context", decision.Reason);
    }

    [TestMethod]
    public void CAbiUsesTheFourAmLogicalDayBoundary()
    {
        Assert.AreEqual("1969-12-31", DayflowCoreInterop.LogicalDayKey(14_399, 0));
        Assert.AreEqual("1970-01-01", DayflowCoreInterop.LogicalDayKey(14_400, 0));
    }

    [TestMethod]
    public void CAbiCanonicalRequestMatchesTheWireVector()
    {
        var request = DayflowCoreInterop.CanonicalDeviceRequest(
            "post",
            "/v1/sync/events?cursor=abc",
            System.Text.Encoding.UTF8.GetBytes("{\"hello\":\"opaque\"}"),
            1_723_456_789,
            "0123456789abcdef0123456789abcdef",
            "mac-device");

        Assert.AreEqual(
            "dayflow:v1:1723456789:POST:/v1/sync/events?cursor=abc:" +
            "b7e6d00fedcbdee445a53f6b804273eeb7a62879a6891f7bdc4f9b238675a4f4:" +
            "0123456789abcdef0123456789abcdef:mac-device",
            request);
    }

    [TestMethod]
    public void SharedCapturePauseParsingFailsClosed()
    {
        Assert.IsFalse(DayflowWindowsCapturePolicy.SharedCapturePauseEnabled(null));
        Assert.IsFalse(DayflowWindowsCapturePolicy.SharedCapturePauseEnabled(" false "));
        Assert.IsTrue(DayflowWindowsCapturePolicy.SharedCapturePauseEnabled("TRUE"));
        Assert.IsTrue(DayflowWindowsCapturePolicy.SharedCapturePauseEnabled("unexpected"));
    }

    [TestMethod]
    public void SharedSettingContractRejectsMalformedDatedKeys()
    {
        Assert.IsTrue(DayflowWindowsSharedSettingContract.IsAllowedKey("day_goal:2026-02-28"));
        Assert.IsTrue(DayflowWindowsSharedSettingContract.IsAllowedKey("daily_standup:2026-08-01"));
        Assert.IsFalse(DayflowWindowsSharedSettingContract.IsAllowedKey("day_goal:2026-02-29"));
        Assert.IsFalse(DayflowWindowsSharedSettingContract.IsAllowedKey("daily_standup:not-a-date"));
        Assert.IsFalse(DayflowWindowsSharedSettingContract.IsAllowedKey("dayflow.provider.api_key"));
    }

    [TestMethod]
    public void NativeStatusFieldsKeepCaptureAndDerivedSyncStateExplicit()
    {
        var fields = WindowsCaptureAdapter.StatusFields(
            new WindowsCaptureStatus(WindowsCaptureState.Running, "Capture is active."),
            sharedCapturePaused: false,
            derivedSync: "Last synced just now");

        Assert.AreEqual("granted", fields.CapturePermission);
        Assert.AreEqual("running", fields.CaptureSession);
        Assert.AreEqual("not_paused", fields.CapturePaused);
        Assert.AreEqual("Last synced just now", fields.DerivedSync);
        Assert.AreEqual("granted", fields.AsDictionary()[WindowsCaptureStatusFields.CapturePermissionKey]);

        var paused = WindowsCaptureAdapter.StatusFields(
            new WindowsCaptureStatus(WindowsCaptureState.PrivacyPaused, "Privacy pause"),
            sharedCapturePaused: true,
            derivedSync: "");
        Assert.AreEqual("not_active", paused.CapturePermission);
        Assert.AreEqual("paused", paused.CapturePaused);
        Assert.AreEqual("unknown", paused.DerivedSync);
    }

    [TestMethod]
    public void MetadataOnlyCaptureDescriptionDoesNotSyncWindowTitles()
    {
        var description = DayflowWindowsCapturePolicy.MetadataOnlyDescription("Notes.exe");

        StringAssert.Contains(description.Title, "Notes.exe");
        StringAssert.Contains(description.Summary, "Raw pixels were released before event creation.");
        Assert.IsFalse(description.Title.Contains("Quarterly planning", StringComparison.Ordinal));
        Assert.IsFalse(description.Summary.Contains("Quarterly planning", StringComparison.Ordinal));

        var generic = DayflowWindowsCapturePolicy.MetadataOnlyDescription(null);
        Assert.AreEqual("Activity observed locally", generic.Title);
    }

    [TestMethod]
    public void WindowsPushWakeAcceptsOnlyTheContentFreeAvailabilitySignal()
    {
        Assert.IsTrue(DayflowWindowsPushNotifications.AcceptsSyncAvailablePayload(
            "{\"kind\":\"sync_available\"}"));
        Assert.IsFalse(DayflowWindowsPushNotifications.AcceptsSyncAvailablePayload(
            "{\"kind\":\"sync_available\",\"journal\":\"private\"}"));
        Assert.IsFalse(DayflowWindowsPushNotifications.AcceptsSyncAvailablePayload(
            "{\"kind\":\"journal_content\"}"));
        Assert.IsFalse(DayflowWindowsPushNotifications.AcceptsSyncAvailablePayload(
            "not-json"));
    }

    [TestMethod]
    public void SharedEndpointPolicyRejectsCredentialAndQueryBearingRelayUrls()
    {
        Assert.IsTrue(DayflowAIProviderConfiguration.IsSafeEndpoint(new Uri("https://relay.dayflow.app")));
        Assert.IsTrue(DayflowAIProviderConfiguration.IsSafeEndpoint(new Uri("http://127.0.0.1:8787")));
        Assert.IsFalse(DayflowAIProviderConfiguration.IsSafeEndpoint(new Uri("https://user:secret@relay.dayflow.app")));
        Assert.IsFalse(DayflowAIProviderConfiguration.IsSafeEndpoint(new Uri("https://relay.dayflow.app?token=secret")));
        Assert.IsFalse(DayflowAIProviderConfiguration.IsSafeEndpoint(new Uri("https://relay.dayflow.app/#token")));
    }

    [TestMethod]
    public void DpapiKeyStoreRoundTripsAndCleansUpAnAtomicWrite()
    {
        var store = new DayflowWindowsKeyStore();
        var accountId = $"windows-key-store-test-{Guid.NewGuid():N}";
        const string name = "atomic-write-test";
        var value = Enumerable.Range(1, 32).Select(index => (byte)index).ToArray();

        try
        {
            store.Store(accountId, name, value);
            CollectionAssert.AreEqual(value, store.Load(accountId, name));
        }
        finally
        {
            store.Delete(accountId, name);
            Assert.IsNull(store.Load(accountId, name));
        }
    }

    [TestMethod]
    public void CAbiRecoveryErrorsDoNotPassThroughAsSuccessfulJson()
    {
        var rootKey = Enumerable.Repeat((byte)9, 32).ToArray();
        const string passphrase = "correct horse battery staple";
        var kit = DayflowCoreInterop.ExportRecoveryKit(rootKey, passphrase);

        CollectionAssert.AreEqual(rootKey, DayflowCoreInterop.RestoreRecoveryKey(kit, passphrase));
        Assert.ThrowsException<InvalidOperationException>(
            () => DayflowCoreInterop.RestoreRecoveryKey(kit, "wrong passphrase"));
    }

    [TestMethod]
    public void CAbiVersionedRecoveryKitRetainsKeyVersionsAndRejectsWrongPassphrase()
    {
        var keyRing = DayflowWindowsAccountKeyRing
            .FromRootKey(Enumerable.Repeat((byte)7, 32).ToArray())
            .Add(Enumerable.Repeat((byte)9, 32).ToArray(), version: 2, active: true);
        const string passphrase = "correct horse battery staple";

        var kit = DayflowCoreInterop.ExportRecoveryKit(keyRing, passphrase);
        var restored = DayflowCoreInterop.RestoreRecoveryKeyRing(kit, passphrase);

        CollectionAssert.AreEqual(keyRing.Versions().ToArray(), restored.Versions().ToArray());
        Assert.AreEqual(2u, restored.ActiveKeyVersion);
        CollectionAssert.AreEqual(keyRing.KeyData(1), restored.KeyData(1));
        CollectionAssert.AreEqual(keyRing.KeyData(2), restored.KeyData(2));
        Assert.ThrowsException<InvalidOperationException>(
            () => DayflowCoreInterop.RestoreRecoveryKeyRing(kit, "wrong passphrase"));
    }

    [TestMethod]
    public void LocalStoreMergeAdvancesClockBeforeTheNextLocalEvent()
    {
        var databasePath = Path.Combine(Path.GetTempPath(), $"dayflow-remote-clock-{Guid.NewGuid():N}.sqlite");
        try
        {
            using var store = new DayflowLocalSyncStore(databasePath);
            var remote = new DayflowEventEnvelope(
                "remote-clock-17",
                "ios-clock-test",
                17,
                DayflowEventEnvelope.CurrentSchemaVersion,
                1,
                new string('A', 32),
                new string('A', 24));

            Assert.AreEqual(1, store.Merge(new[] { remote }));
            Assert.AreEqual(18UL, store.NextLogicalClock());

            var later = remote with
            {
                EventId = "remote-clock-25",
                DeviceId = "android-clock-test",
                LogicalClock = 25,
            };
            Assert.AreEqual(1, store.Merge(new[] { later }));
            Assert.AreEqual(26UL, store.NextLogicalClock());
        }
        finally
        {
            File.Delete(databasePath);
        }
    }

    [TestMethod]
    public void LocalStoreSyncHealthPersistsBoundedStateAcrossReopen()
    {
        var databasePath = Path.Combine(Path.GetTempPath(), $"dayflow-sync-health-{Guid.NewGuid():N}.sqlite");
        try
        {
            using (var store = new DayflowLocalSyncStore(databasePath))
            {
                store.RecordSyncHealth(
                    DayflowWindowsSyncHealthState.Failed,
                    "Relay response included user journal text!",
                    DateTimeOffset.FromUnixTimeSeconds(100));
                var health = store.SyncHealth();
                Assert.AreEqual(DayflowWindowsSyncHealthState.Failed, health.State);
                Assert.AreEqual("relayresponseincludeduserjournaltext", health.FailureCode);
                Assert.IsNull(health.LastSuccessfulSyncAt);
            }

            using (var store = new DayflowLocalSyncStore(databasePath))
            {
                store.RecordSyncHealth(DayflowWindowsSyncHealthState.Synced, at: DateTimeOffset.FromUnixTimeSeconds(200));
                var health = store.SyncHealth();
                Assert.AreEqual(DayflowWindowsSyncHealthState.Synced, health.State);
                Assert.AreEqual(DateTimeOffset.FromUnixTimeSeconds(200), health.LastSyncAt);
                Assert.AreEqual(DateTimeOffset.FromUnixTimeSeconds(200), health.LastSuccessfulSyncAt);
                Assert.IsNull(health.FailureCode);
            }
        }
        finally
        {
            File.Delete(databasePath);
        }
    }
}
