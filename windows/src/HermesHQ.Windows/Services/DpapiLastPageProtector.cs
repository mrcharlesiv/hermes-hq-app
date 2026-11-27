using System.Runtime.InteropServices;
using Hermes.Core.Browser;

namespace HermesHQ.Services;

/// Watch Browser's kept last pages on Windows: sealed with DPAPI for the signed-in Windows user (CryptProtectData,
/// no UI), the twin of the Mac's file protection. Another user, or a copied file on another PC, can't open them. If
/// DPAPI fails the store keeps the page in memory only (BrowserLastPages never writes plain bytes).
public sealed class DpapiLastPageProtector : IBrowserLastPageProtector
{
    // Ties the sealed bytes to this use, so another DPAPI blob of the same user can't be swapped in as a last page.
    private static readonly byte[] Entropy = "ai.hermes.hqwindows.browser.lastpage.v1"u8.ToArray();
    private const int UiForbidden = 0x1;

    /// The cache folder the app gives BrowserLastPages: %LOCALAPPDATA%\HermesHQ\Cache\browser-last-page.
    public static string Folder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HermesHQ", "Cache",
                     "browser-last-page");

    public byte[] Protect(byte[] plain) =>
        Run(plain, protect: true) ?? throw new IOException("Windows could not protect the last page.");

    public byte[]? Unprotect(byte[] stored) => Run(stored, protect: false);

    private static byte[]? Run(byte[] input, bool protect)
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
    private static extern bool CryptProtectData(ref DataBlob dataIn, string? description, ref DataBlob entropy,
                                                IntPtr reserved, IntPtr prompt, int flags, ref DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptUnprotectData(ref DataBlob dataIn, IntPtr description, ref DataBlob entropy,
                                                  IntPtr reserved, IntPtr prompt, int flags, ref DataBlob dataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr handle);
}
