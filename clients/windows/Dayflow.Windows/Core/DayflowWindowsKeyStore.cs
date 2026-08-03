using System.Security.Cryptography;
using System.Text;

namespace Dayflow.Windows.Core;

/// <summary>
/// Windows DPAPI protects the locally stored envelope keys, while the
/// platform's account/user boundary owns the decryption key. Plaintext key
/// bytes are never written to the relay or the local SQLite database.
/// </summary>
public sealed class DayflowWindowsKeyStore
{
    private readonly string _directory = DayflowWindowsStorage.KeysDirectory;

    public byte[]? Load(string accountId, string name)
    {
        var path = PathFor(accountId, name);
        if (!File.Exists(path)) return null;
        try
        {
            var protectedValue = File.ReadAllBytes(path);
            return ProtectedData.Unprotect(protectedValue, null, DataProtectionScope.CurrentUser);
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    public void Store(string accountId, string name, ReadOnlySpan<byte> value)
    {
        Directory.CreateDirectory(_directory);
        var protectedValue = ProtectedData.Protect(value.ToArray(), null, DataProtectionScope.CurrentUser);
        var path = PathFor(accountId, name);
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 4096,
                options: FileOptions.WriteThrough))
            {
                stream.Write(protectedValue);
                stream.Flush(flushToDisk: true);
            }

            if (File.Exists(path))
            {
                File.Replace(temporaryPath, path, destinationBackupFileName: null);
            }
            else
            {
                File.Move(temporaryPath, path);
            }
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    public string? LoadText(string accountId, string name)
    {
        var value = Load(accountId, name);
        return value is null ? null : Encoding.UTF8.GetString(value);
    }

    public void StoreText(string accountId, string name, string value)
    {
        Store(accountId, name, Encoding.UTF8.GetBytes(value));
    }

    public DayflowWindowsAccountKeyRing? LoadAccountKeyRing(string accountId)
    {
        var stored = LoadText(accountId, "account-key-ring-v1");
        if (!string.IsNullOrWhiteSpace(stored))
        {
            return DayflowWindowsAccountKeyRing.FromJson(stored);
        }
        var rootKey = Load(accountId, "root-key-v1");
        return rootKey is null ? null : DayflowWindowsAccountKeyRing.FromRootKey(rootKey);
    }

    public void StoreAccountKeyRing(string accountId, DayflowWindowsAccountKeyRing keyRing)
    {
        StoreText(accountId, "account-key-ring-v1", keyRing.ToJson());
        var versionOne = keyRing.KeyData(1);
        if (versionOne is not null) Store(accountId, "root-key-v1", versionOne);
    }

    /// <summary>True after this device has received an explicitly admitted account key.</summary>
    public bool HasAccountKeyAdmission(string accountId)
    {
        var marker = Load(accountId, "account-key-admitted-v1");
        return marker is { Length: 1 } && marker[0] == 1;
    }

    public void MarkAccountKeyAdmitted(string accountId) =>
        Store(accountId, "account-key-admitted-v1", new byte[] { 1 });

    public DayflowWindowsAccountKeyRing? LoadPendingAccountKeyRing(string accountId)
    {
        var stored = LoadText(accountId, "account-key-ring-pending-v1");
        return string.IsNullOrWhiteSpace(stored)
            ? null
            : DayflowWindowsAccountKeyRing.FromJson(stored);
    }

    public void StorePendingAccountKeyRing(string accountId, DayflowWindowsAccountKeyRing keyRing) =>
        StoreText(accountId, "account-key-ring-pending-v1", keyRing.ToJson());

    public void ClearPendingAccountKeyRing(string accountId) => Delete(accountId, "account-key-ring-pending-v1");

    public void Delete(string accountId, string name)
    {
        var path = PathFor(accountId, name);
        if (File.Exists(path)) File.Delete(path);
    }

    public byte[] GetOrCreateDeviceId(string accountId)
    {
        var existing = Load(accountId, "device-id");
        if (existing is not null && existing.Length > 0) return existing;
        var generated = Encoding.UTF8.GetBytes(Guid.NewGuid().ToString("N"));
        Store(accountId, "device-id", generated);
        return generated;
    }

    private string PathFor(string accountId, string name)
    {
        var accountHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(accountId))).ToLowerInvariant();
        return Path.Combine(_directory, $"{accountHash}-{name}.bin");
    }
}
