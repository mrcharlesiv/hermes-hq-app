using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Hermes.Core.Composio;
using Hermes.Core.Gateways;
using HermesHQ.Services;

namespace HermesHQ.Features.ConnectApps;

/// Per-account Composio API key store sealed with Windows DPAPI (`CryptProtectData` / `CryptUnprotectData`,
/// current-user scope, UI forbidden), following the per-account pattern of `WindowsPhoneKeyStore.cs`.
/// Never logs keys or stores plaintext on disk.
internal sealed class ComposioKeyStore : IComposioKeyStore
{
    private static readonly byte[] Entropy = "ai.hermes.hqwindows.composio.apikey.v1"u8.ToArray();
    private const int UiForbidden = 0x1;
    private readonly object _gate = new();
    private readonly string _folder;

    public ComposioKeyStore(string? folder = null) =>
        _folder = folder ?? Path.Combine(AppPaths.Root, "composio-keys");

    private string PathFor(string accountId)
    {
        var tag = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(accountId)))[..24];
        return Path.Combine(_folder, $"composio-{tag}.bin");
    }

    public string? ReadKey(string accountId)
    {
        lock (_gate)
        {
            try
            {
                var path = PathFor(accountId);
                if (!File.Exists(path)) return null;
                var protectedBytes = File.ReadAllBytes(path);
                if (protectedBytes.Length == 0) return null;
                var plain = RunDpapi(protectedBytes, protect: false);
                if (plain == null || plain.Length == 0) return null;
                var key = Encoding.UTF8.GetString(plain).Trim();
                Array.Clear(plain);
                return key.Length > 0 ? key : null;
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    public void SaveKey(string accountId, string apiKey)
    {
        var clean = apiKey.Trim();
        if (!ComposioKeyRules.Plausible(clean))
            throw new ComposioException(ComposioErrorKind.BadKey, "That doesn’t look like a Composio key.");

        var plain = Encoding.UTF8.GetBytes(clean);
        try
        {
            var sealedBytes = RunDpapi(plain, protect: true)
                ?? throw new ComposioException(ComposioErrorKind.Rejected, $"This {DeviceWord.Name} couldn’t save the key.");
            lock (_gate)
            {
                Directory.CreateDirectory(_folder);
                var path = PathFor(accountId);
                var tmp = path + ".tmp";
                File.WriteAllBytes(tmp, sealedBytes);
                File.Move(tmp, path, overwrite: true);
            }
        }
        catch (ComposioException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new ComposioException(ComposioErrorKind.Rejected, $"This {DeviceWord.Name} couldn’t save the key.");
        }
        finally
        {
            Array.Clear(plain);
        }
    }

    public void DeleteKey(string accountId)
    {
        lock (_gate)
        {
            try
            {
                var path = PathFor(accountId);
                if (File.Exists(path)) File.Delete(path);
            }
            catch (Exception) { /* best-effort cleanup */ }
        }
    }

    private static byte[]? RunDpapi(byte[] input, bool protect)
    {
        var inHandle = GCHandle.Alloc(input, GCHandleType.Pinned);
        var entropyHandle = GCHandle.Alloc(Entropy, GCHandleType.Pinned);
        var output = new DataBlob();
        try
        {
            var inBlob = new DataBlob { Size = input.Length, Data = inHandle.AddrOfPinnedObject() };
            var entropy = new DataBlob { Size = Entropy.Length, Data = entropyHandle.AddrOfPinnedObject() };
            var ok = protect
                ? CryptProtectData(ref inBlob, null, ref entropy, IntPtr.Zero, IntPtr.Zero, UiForbidden, ref output)
                : CryptUnprotectData(ref inBlob, IntPtr.Zero, ref entropy, IntPtr.Zero, IntPtr.Zero, UiForbidden, ref output);
            if (!ok || output.Data == IntPtr.Zero) return null;
            var result = new byte[output.Size];
            Marshal.Copy(output.Data, result, 0, output.Size);
            return result;
        }
        finally
        {
            if (output.Data != IntPtr.Zero) LocalFree(output.Data);
            inHandle.Free();
            entropyHandle.Free();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn, string? description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, int flags, ref DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn, IntPtr description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, int flags, ref DataBlob dataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr handle);
}
