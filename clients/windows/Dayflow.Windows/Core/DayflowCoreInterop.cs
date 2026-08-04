using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Dayflow.Windows.Core;

/// <summary>
/// Small, ownership-safe C ABI wrapper. The account root key is pinned only for
/// the synchronous call and is never logged or serialized into relay requests.
/// </summary>
public static class DayflowCoreInterop
{
    public sealed record DayflowCaptureDecision(bool Allowed, string Reason);

    public static string ExportRecoveryKit(ReadOnlySpan<byte> accountRootKey, string passphrase)
    {
        if (accountRootKey.Length != 32 || string.IsNullOrWhiteSpace(passphrase)) throw new ArgumentException("A root key and recovery passphrase are required.");
        var rootKey = accountRootKey.ToArray();
        var passphraseBytes = Encoding.UTF8.GetBytes(passphrase + "\0");
        var rootHandle = GCHandle.Alloc(rootKey, GCHandleType.Pinned);
        var passphraseHandle = GCHandle.Alloc(passphraseBytes, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_export_recovery_kit_json(
                rootHandle.AddrOfPinnedObject(),
                (nuint)rootKey.Length,
                passphraseHandle.AddrOfPinnedObject());
            return ReadSuccessfulJson(result);
        }
        finally
        {
            FreeOwnedString(result);
            passphraseHandle.Free();
            rootHandle.Free();
        }
    }

    public static string ExportRecoveryKit(DayflowWindowsAccountKeyRing keyRing, string passphrase)
    {
        if (string.IsNullOrWhiteSpace(passphrase)) throw new ArgumentException("A recovery passphrase is required.");
        var keyRingBytes = Encoding.UTF8.GetBytes(keyRing.ToJson() + "\0");
        var passphraseBytes = Encoding.UTF8.GetBytes(passphrase + "\0");
        var keyRingHandle = GCHandle.Alloc(keyRingBytes, GCHandleType.Pinned);
        var passphraseHandle = GCHandle.Alloc(passphraseBytes, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_export_recovery_kit_keyring_json(
                keyRingHandle.AddrOfPinnedObject(),
                passphraseHandle.AddrOfPinnedObject());
            return ReadSuccessfulJson(result);
        }
        finally
        {
            FreeOwnedString(result);
            passphraseHandle.Free();
            keyRingHandle.Free();
        }
    }

    public static byte[] RestoreRecoveryKey(string kitJson, string passphrase)
    {
        var kitBytes = Encoding.UTF8.GetBytes(kitJson + "\0");
        var passphraseBytes = Encoding.UTF8.GetBytes(passphrase + "\0");
        var kitHandle = GCHandle.Alloc(kitBytes, GCHandleType.Pinned);
        var passphraseHandle = GCHandle.Alloc(passphraseBytes, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_restore_recovery_key_json(
                kitHandle.AddrOfPinnedObject(),
                passphraseHandle.AddrOfPinnedObject());
            using var document = JsonDocument.Parse(ReadSuccessfulJson(result));
            var rootKey = Convert.FromBase64String(document.RootElement.GetProperty("root_key").GetString()!);
            if (rootKey.Length != 32) throw new InvalidOperationException("Dayflow core returned an invalid recovery key.");
            return rootKey;
        }
        finally
        {
            FreeOwnedString(result);
            passphraseHandle.Free();
            kitHandle.Free();
        }
    }

    public static DayflowWindowsAccountKeyRing RestoreRecoveryKeyRing(string kitJson, string passphrase)
    {
        var kitBytes = Encoding.UTF8.GetBytes(kitJson + "\0");
        var passphraseBytes = Encoding.UTF8.GetBytes(passphrase + "\0");
        var kitHandle = GCHandle.Alloc(kitBytes, GCHandleType.Pinned);
        var passphraseHandle = GCHandle.Alloc(passphraseBytes, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_restore_recovery_keyring_json(
                kitHandle.AddrOfPinnedObject(),
                passphraseHandle.AddrOfPinnedObject());
            return DayflowWindowsAccountKeyRing.FromJson(ReadSuccessfulJson(result));
        }
        finally
        {
            FreeOwnedString(result);
            passphraseHandle.Free();
            kitHandle.Free();
        }
    }

    public static byte[] GenerateAccountRootKey()
    {
        var result = NativeMethods.dayflow_core_generate_account_root_key_json();
        var json = ReadOwnedStringAndFree(result);
        using var document = JsonDocument.Parse(json);
        var key = Convert.FromBase64String(document.RootElement.GetProperty("root_key").GetString()!);
        if (key.Length != 32) throw new InvalidOperationException("Dayflow core returned an invalid account root key.");
        return key;
    }

    public static string GenerateDeviceKeyMaterial()
    {
        var result = NativeMethods.dayflow_core_generate_device_keypair_json();
        return ReadOwnedStringAndFree(result);
    }

    public static bool CaptureAllowed(
        bool permissionGranted,
        bool userPaused,
        bool deviceLocked,
        bool sleeping,
        bool privateContext,
        bool drmContent) => NativeMethods.dayflow_core_capture_allowed(
            permissionGranted,
            userPaused,
            deviceLocked,
            sleeping,
            privateContext,
            drmContent);

    public static string LogicalDayKey(long timestampUnix, int timezoneOffsetMinutes, byte boundaryHour = 4)
    {
        var result = NativeMethods.dayflow_core_logical_day_key(timestampUnix, timezoneOffsetMinutes, boundaryHour);
        var json = ReadOwnedStringAndFree(result);
        using var document = JsonDocument.Parse(json);
        return document.RootElement.GetProperty("day").GetString()
            ?? throw new InvalidOperationException("Dayflow core returned an empty logical day.");
    }

    public static DayflowCaptureDecision CaptureDecision(
        bool permissionGranted,
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
        var contextJson = JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["permission_granted"] = permissionGranted,
            ["user_paused"] = userPaused,
            ["device_locked"] = deviceLocked,
            ["sleeping"] = sleeping,
            ["private_context"] = privateContext,
            ["drm_content"] = drmContent,
            ["application_id"] = applicationId,
            ["window_title"] = windowTitle,
        });
        var policyJson = JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["ignore_private_context"] = true,
            ["pause_on_drm"] = true,
            ["blocked_application_ids"] = blockedApplicationIds ?? Array.Empty<string>(),
            ["blocked_window_title_fragments"] = blockedWindowTitleFragments ?? Array.Empty<string>(),
        });
        var contextBytes = Encoding.UTF8.GetBytes(contextJson + "\0");
        var policyBytes = Encoding.UTF8.GetBytes(policyJson + "\0");
        var contextHandle = GCHandle.Alloc(contextBytes, GCHandleType.Pinned);
        var policyHandle = GCHandle.Alloc(policyBytes, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_capture_decision_json(
                contextHandle.AddrOfPinnedObject(),
                policyHandle.AddrOfPinnedObject());
            using var document = JsonDocument.Parse(ReadSuccessfulJson(result));
            return new DayflowCaptureDecision(
                document.RootElement.GetProperty("allowed").GetBoolean(),
                document.RootElement.GetProperty("reason").GetString() ?? "unknown");
        }
        finally
        {
            FreeOwnedString(result);
            policyHandle.Free();
            contextHandle.Free();
        }
    }

    public static DayflowEventEnvelope Seal(
        string payloadJson,
        string eventId,
        string deviceId,
        ulong logicalClock,
        ReadOnlySpan<byte> accountRootKey)
    {
        if (accountRootKey.Length != 32 || string.IsNullOrWhiteSpace(payloadJson)
            || string.IsNullOrWhiteSpace(eventId) || string.IsNullOrWhiteSpace(deviceId) || logicalClock == 0)
        {
            throw new ArgumentException("A payload, event metadata, and a 32-byte account key are required.");
        }

        var payload = Encoding.UTF8.GetBytes(payloadJson + "\0");
        var eventIdBytes = Encoding.UTF8.GetBytes(eventId + "\0");
        var deviceIdBytes = Encoding.UTF8.GetBytes(deviceId + "\0");
        var rootKey = accountRootKey.ToArray();
        var payloadHandle = GCHandle.Alloc(payload, GCHandleType.Pinned);
        var eventIdHandle = GCHandle.Alloc(eventIdBytes, GCHandleType.Pinned);
        var deviceIdHandle = GCHandle.Alloc(deviceIdBytes, GCHandleType.Pinned);
        var rootHandle = GCHandle.Alloc(rootKey, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_seal_json(
                payloadHandle.AddrOfPinnedObject(),
                eventIdHandle.AddrOfPinnedObject(),
                deviceIdHandle.AddrOfPinnedObject(),
                logicalClock,
                rootHandle.AddrOfPinnedObject(),
                (nuint)rootKey.Length);
            var json = ReadSuccessfulJson(result);
            var envelope = JsonSerializer.Deserialize<DayflowEventEnvelope>(json)
                ?? throw new InvalidOperationException("Dayflow core returned an invalid event envelope.");
            return envelope;
        }
        finally
        {
            FreeOwnedString(result);
            rootHandle.Free();
            deviceIdHandle.Free();
            eventIdHandle.Free();
            payloadHandle.Free();
        }
    }

    public static DayflowEventEnvelope Seal(
        string payloadJson,
        string eventId,
        string deviceId,
        ulong logicalClock,
        uint keyVersion,
        ReadOnlySpan<byte> accountRootKey)
    {
        if (accountRootKey.Length != 32 || keyVersion == 0 || string.IsNullOrWhiteSpace(payloadJson)
            || string.IsNullOrWhiteSpace(eventId) || string.IsNullOrWhiteSpace(deviceId) || logicalClock == 0)
        {
            throw new ArgumentException("A payload, event metadata, key version, and a 32-byte account key are required.");
        }

        var payload = Encoding.UTF8.GetBytes(payloadJson + "\0");
        var eventIdBytes = Encoding.UTF8.GetBytes(eventId + "\0");
        var deviceIdBytes = Encoding.UTF8.GetBytes(deviceId + "\0");
        var rootKey = accountRootKey.ToArray();
        var payloadHandle = GCHandle.Alloc(payload, GCHandleType.Pinned);
        var eventIdHandle = GCHandle.Alloc(eventIdBytes, GCHandleType.Pinned);
        var deviceIdHandle = GCHandle.Alloc(deviceIdBytes, GCHandleType.Pinned);
        var rootHandle = GCHandle.Alloc(rootKey, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_seal_key_version_json(
                payloadHandle.AddrOfPinnedObject(),
                eventIdHandle.AddrOfPinnedObject(),
                deviceIdHandle.AddrOfPinnedObject(),
                logicalClock,
                keyVersion,
                rootHandle.AddrOfPinnedObject(),
                (nuint)rootKey.Length);
            return JsonSerializer.Deserialize<DayflowEventEnvelope>(ReadSuccessfulJson(result))
                ?? throw new InvalidOperationException("Dayflow core returned an invalid event envelope.");
        }
        finally
        {
            FreeOwnedString(result);
            rootHandle.Free();
            deviceIdHandle.Free();
            eventIdHandle.Free();
            payloadHandle.Free();
        }
    }

    public static string Project(IReadOnlyList<DayflowEventEnvelope> envelopes, ReadOnlySpan<byte> accountRootKey)
    {
        if (accountRootKey.Length != 32)
        {
            throw new ArgumentException("The account root key must be 32 bytes.", nameof(accountRootKey));
        }

        var json = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelopes) + "\0");
        var rootKey = accountRootKey.ToArray();
        var jsonHandle = GCHandle.Alloc(json, GCHandleType.Pinned);
        var rootKeyHandle = GCHandle.Alloc(rootKey, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_project_json(
                jsonHandle.AddrOfPinnedObject(),
                rootKeyHandle.AddrOfPinnedObject(),
                (nuint)rootKey.Length);
            if (result == IntPtr.Zero)
            {
                throw new InvalidOperationException("Dayflow core returned a null result.");
            }
            var projection = ReadSuccessfulJson(result);
            return projection;
        }
        finally
        {
            if (result != IntPtr.Zero)
            {
                NativeMethods.dayflow_core_free_string(result);
            }
            rootKeyHandle.Free();
            jsonHandle.Free();
        }
    }

    public static string Project(
        IReadOnlyList<DayflowEventEnvelope> envelopes,
        DayflowWindowsAccountKeyRing keyRing)
    {
        var json = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelopes) + "\0");
        var keyRingJson = Encoding.UTF8.GetBytes(keyRing.ToJson() + "\0");
        var jsonHandle = GCHandle.Alloc(json, GCHandleType.Pinned);
        var keyRingHandle = GCHandle.Alloc(keyRingJson, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_project_keyring_json(
                jsonHandle.AddrOfPinnedObject(),
                keyRingHandle.AddrOfPinnedObject());
            var projection = ReadSuccessfulJson(result);
            return projection;
        }
        finally
        {
            FreeOwnedString(result);
            keyRingHandle.Free();
            jsonHandle.Free();
        }
    }

    public static IReadOnlyList<DayflowEventEnvelope> Rekey(
        IReadOnlyList<DayflowEventEnvelope> envelopes,
        DayflowWindowsAccountKeyRing sourceKeyRing,
        DayflowWindowsAccountKeyRing destinationKeyRing)
    {
        var envelopeJson = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelopes) + "\0");
        var sourceJson = Encoding.UTF8.GetBytes(sourceKeyRing.ToJson() + "\0");
        var destinationJson = Encoding.UTF8.GetBytes(destinationKeyRing.ToJson() + "\0");
        var envelopeHandle = GCHandle.Alloc(envelopeJson, GCHandleType.Pinned);
        var sourceHandle = GCHandle.Alloc(sourceJson, GCHandleType.Pinned);
        var destinationHandle = GCHandle.Alloc(destinationJson, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_rekey_envelopes_json(
                envelopeHandle.AddrOfPinnedObject(),
                sourceHandle.AddrOfPinnedObject(),
                destinationHandle.AddrOfPinnedObject());
            var value = ReadSuccessfulJson(result);
            return JsonSerializer.Deserialize<DayflowEventEnvelope[]>(value)
                ?? throw new InvalidOperationException("Dayflow core returned an invalid rekey result.");
        }
        finally
        {
            FreeOwnedString(result);
            destinationHandle.Free();
            sourceHandle.Free();
            envelopeHandle.Free();
        }
    }

    public static string Version()
    {
        var pointer = NativeMethods.dayflow_core_version();
        if (pointer == IntPtr.Zero)
        {
            throw new InvalidOperationException("Dayflow core returned a null version.");
        }
        try
        {
            return Marshal.PtrToStringUTF8(pointer) ?? "unknown";
        }
        finally
        {
            NativeMethods.dayflow_core_free_string(pointer);
        }
    }

    public static string WrapAccountKey(
        ReadOnlySpan<byte> accountRootKey,
        string recipientDeviceId,
        ReadOnlySpan<byte> recipientPublicKey)
    {
        if (accountRootKey.Length != 32 || recipientPublicKey.Length != 32)
        {
            throw new ArgumentException("Account and recipient keys must be 32 bytes.");
        }
        if (string.IsNullOrWhiteSpace(recipientDeviceId))
        {
            throw new ArgumentException("A recipient device ID is required.", nameof(recipientDeviceId));
        }

        var deviceId = Encoding.UTF8.GetBytes(recipientDeviceId + "\0");
        var rootKey = accountRootKey.ToArray();
        var publicKey = recipientPublicKey.ToArray();
        var deviceHandle = GCHandle.Alloc(deviceId, GCHandleType.Pinned);
        var rootHandle = GCHandle.Alloc(rootKey, GCHandleType.Pinned);
        var publicHandle = GCHandle.Alloc(publicKey, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_wrap_account_key_json(
                rootHandle.AddrOfPinnedObject(),
                (nuint)rootKey.Length,
                deviceHandle.AddrOfPinnedObject(),
                publicHandle.AddrOfPinnedObject(),
                (nuint)publicKey.Length);
            return ReadSuccessfulJson(result);
        }
        finally
        {
            FreeOwnedString(result);
            publicHandle.Free();
            rootHandle.Free();
            deviceHandle.Free();
        }
    }

    public static string WrapAccountKey(
        ReadOnlySpan<byte> accountRootKey,
        uint keyVersion,
        string recipientDeviceId,
        ReadOnlySpan<byte> recipientPublicKey)
    {
        if (accountRootKey.Length != 32 || recipientPublicKey.Length != 32 || keyVersion == 0)
        {
            throw new ArgumentException("Account, recipient, and versioned keys must be valid.");
        }
        if (string.IsNullOrWhiteSpace(recipientDeviceId))
        {
            throw new ArgumentException("A recipient device ID is required.", nameof(recipientDeviceId));
        }

        var deviceId = Encoding.UTF8.GetBytes(recipientDeviceId + "\0");
        var rootKey = accountRootKey.ToArray();
        var publicKey = recipientPublicKey.ToArray();
        var deviceHandle = GCHandle.Alloc(deviceId, GCHandleType.Pinned);
        var rootHandle = GCHandle.Alloc(rootKey, GCHandleType.Pinned);
        var publicHandle = GCHandle.Alloc(publicKey, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_wrap_account_key_versioned_json(
                rootHandle.AddrOfPinnedObject(),
                (nuint)rootKey.Length,
                keyVersion,
                deviceHandle.AddrOfPinnedObject(),
                publicHandle.AddrOfPinnedObject(),
                (nuint)publicKey.Length);
            return ReadSuccessfulJson(result);
        }
        finally
        {
            FreeOwnedString(result);
            publicHandle.Free();
            rootHandle.Free();
            deviceHandle.Free();
        }
    }

    public static string UnwrapAccountKey(string wrappedKeyJson, ReadOnlySpan<byte> privateKey)
    {
        if (string.IsNullOrWhiteSpace(wrappedKeyJson) || privateKey.Length != 32)
        {
            throw new ArgumentException("A wrapped key and a 32-byte private key are required.");
        }

        var wrappedKey = Encoding.UTF8.GetBytes(wrappedKeyJson + "\0");
        var privateKeyBytes = privateKey.ToArray();
        var wrappedHandle = GCHandle.Alloc(wrappedKey, GCHandleType.Pinned);
        var privateHandle = GCHandle.Alloc(privateKeyBytes, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_unwrap_account_key_json(
                wrappedHandle.AddrOfPinnedObject(),
                privateHandle.AddrOfPinnedObject(),
                (nuint)privateKeyBytes.Length);
            return ReadSuccessfulJson(result);
        }
        finally
        {
            FreeOwnedString(result);
            privateHandle.Free();
            wrappedHandle.Free();
        }
    }

    public static string GenerateDeviceSigningKeyMaterial()
    {
        var result = NativeMethods.dayflow_core_generate_device_signing_keypair_json();
        return ReadOwnedStringAndFree(result);
    }

    public static string SignRequest(string message, ReadOnlySpan<byte> privateKey)
    {
        if (string.IsNullOrWhiteSpace(message) || privateKey.Length != 32)
        {
            throw new ArgumentException("A request message and a 32-byte signing key are required.");
        }

        var messageBytes = Encoding.UTF8.GetBytes(message + "\0");
        var keyBytes = privateKey.ToArray();
        var messageHandle = GCHandle.Alloc(messageBytes, GCHandleType.Pinned);
        var keyHandle = GCHandle.Alloc(keyBytes, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_sign_request_json(
                messageHandle.AddrOfPinnedObject(),
                keyHandle.AddrOfPinnedObject(),
                (nuint)keyBytes.Length);
            return ReadSuccessfulJson(result);
        }
        finally
        {
            FreeOwnedString(result);
            keyHandle.Free();
            messageHandle.Free();
        }
    }

    public static string CanonicalDeviceRequest(
        string method,
        string pathWithQuery,
        ReadOnlySpan<byte> body,
        long timestamp,
        string nonce,
        string deviceId)
    {
        var methodBytes = Encoding.UTF8.GetBytes(method + "\0");
        var pathBytes = Encoding.UTF8.GetBytes(pathWithQuery + "\0");
        var nonceBytes = Encoding.UTF8.GetBytes(nonce + "\0");
        var deviceIdBytes = Encoding.UTF8.GetBytes(deviceId + "\0");
        var bodyBytes = body.ToArray();
        var methodHandle = GCHandle.Alloc(methodBytes, GCHandleType.Pinned);
        var pathHandle = GCHandle.Alloc(pathBytes, GCHandleType.Pinned);
        var nonceHandle = GCHandle.Alloc(nonceBytes, GCHandleType.Pinned);
        var deviceIdHandle = GCHandle.Alloc(deviceIdBytes, GCHandleType.Pinned);
        var bodyHandle = bodyBytes.Length == 0
            ? default
            : GCHandle.Alloc(bodyBytes, GCHandleType.Pinned);
        var result = IntPtr.Zero;
        try
        {
            result = NativeMethods.dayflow_core_canonical_device_request_json(
                methodHandle.AddrOfPinnedObject(),
                pathHandle.AddrOfPinnedObject(),
                bodyHandle.IsAllocated ? bodyHandle.AddrOfPinnedObject() : IntPtr.Zero,
                (nuint)bodyBytes.Length,
                timestamp,
                nonceHandle.AddrOfPinnedObject(),
                deviceIdHandle.AddrOfPinnedObject());
            using var document = JsonDocument.Parse(ReadSuccessfulJson(result));
            return document.RootElement.GetProperty("request").GetString()
                ?? throw new InvalidOperationException("Dayflow core returned an empty request.");
        }
        finally
        {
            FreeOwnedString(result);
            if (bodyHandle.IsAllocated) bodyHandle.Free();
            deviceIdHandle.Free();
            nonceHandle.Free();
            pathHandle.Free();
            methodHandle.Free();
        }
    }

    private static string ReadOwnedStringAndFree(IntPtr result)
    {
        try
        {
            return ReadSuccessfulJson(result);
        }
        finally
        {
            FreeOwnedString(result);
        }
    }

    private static string ReadSuccessfulJson(IntPtr result)
    {
        var value = ReadOwnedString(result);
        using var document = JsonDocument.Parse(value);
        if (document.RootElement.ValueKind == JsonValueKind.Object
            && document.RootElement.TryGetProperty("error", out var error))
        {
            var message = error.ValueKind == JsonValueKind.String ? error.GetString() : error.ToString();
            throw new InvalidOperationException(message ?? "Dayflow core operation failed.");
        }
        return value;
    }

    private static string ReadOwnedString(IntPtr result)
    {
        if (result == IntPtr.Zero)
        {
            throw new InvalidOperationException("Dayflow core returned a null result.");
        }
        return Marshal.PtrToStringUTF8(result)
            ?? throw new InvalidOperationException("Dayflow core returned invalid UTF-8.");
    }

    private static void FreeOwnedString(IntPtr result)
    {
        if (result != IntPtr.Zero)
        {
            NativeMethods.dayflow_core_free_string(result);
        }
    }

    private static class NativeMethods
    {
        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_version();

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_generate_account_root_key_json();

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_generate_device_keypair_json();

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_export_recovery_kit_json(
            IntPtr rootKey,
            nuint rootKeyLength,
            IntPtr passphrase);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_export_recovery_kit_keyring_json(
            IntPtr keyRingJson,
            IntPtr passphrase);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_restore_recovery_key_json(
            IntPtr kitJson,
            IntPtr passphrase);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_restore_recovery_keyring_json(
            IntPtr kitJson,
            IntPtr passphrase);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.I1)]
        internal static extern bool dayflow_core_capture_allowed(
            [MarshalAs(UnmanagedType.I1)] bool permissionGranted,
            [MarshalAs(UnmanagedType.I1)] bool userPaused,
            [MarshalAs(UnmanagedType.I1)] bool deviceLocked,
            [MarshalAs(UnmanagedType.I1)] bool sleeping,
            [MarshalAs(UnmanagedType.I1)] bool privateContext,
            [MarshalAs(UnmanagedType.I1)] bool drmContent);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_capture_decision_json(
            IntPtr contextJson,
            IntPtr policyJson);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_logical_day_key(
            long timestampUnix,
            int timezoneOffsetMinutes,
            byte boundaryHour);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_project_json(
            IntPtr envelopesJson,
            IntPtr rootKey,
            nuint rootKeyLength);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_project_keyring_json(
            IntPtr envelopesJson,
            IntPtr keyRingJson);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_rekey_envelopes_json(
            IntPtr envelopesJson,
            IntPtr sourceKeyRingJson,
            IntPtr destinationKeyRingJson);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_seal_json(
            IntPtr payloadJson,
            IntPtr eventId,
            IntPtr deviceId,
            ulong logicalClock,
            IntPtr rootKey,
            nuint rootKeyLength);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_seal_key_version_json(
            IntPtr payloadJson,
            IntPtr eventId,
            IntPtr deviceId,
            ulong logicalClock,
            uint keyVersion,
            IntPtr rootKey,
            nuint rootKeyLength);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_wrap_account_key_json(
            IntPtr rootKey,
            nuint rootKeyLength,
            IntPtr recipientDeviceId,
            IntPtr recipientPublicKey,
            nuint recipientPublicKeyLength);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_wrap_account_key_versioned_json(
            IntPtr rootKey,
            nuint rootKeyLength,
            uint keyVersion,
            IntPtr recipientDeviceId,
            IntPtr recipientPublicKey,
            nuint recipientPublicKeyLength);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_unwrap_account_key_json(
            IntPtr wrappedKeyJson,
            IntPtr privateKey,
            nuint privateKeyLength);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_generate_device_signing_keypair_json();

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_sign_request_json(
            IntPtr message,
            IntPtr privateKey,
            nuint privateKeyLength);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr dayflow_core_canonical_device_request_json(
            IntPtr method,
            IntPtr pathWithQuery,
            IntPtr body,
            nuint bodyLength,
            long timestamp,
            IntPtr nonce,
            IntPtr deviceId);

        [DllImport("dayflow_core", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void dayflow_core_free_string(IntPtr value);
    }
}
