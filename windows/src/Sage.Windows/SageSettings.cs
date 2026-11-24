using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Sage.Core.Networking;

namespace Sage.Windows;

/// <summary>
/// Where Sage keeps its configuration. The Worker address is not secret and lives in
/// %LOCALAPPDATA%\Sage\settings.json. The access token goes in Windows Credential
/// Manager, which encrypts it for the signed-in user (the Windows equivalent of the
/// Mac app's Keychain item). Nothing here ever holds an Anthropic key.
/// </summary>
internal static class SageSettings
{
    private const string CredentialTarget = "Sage/AccessToken";

    private static string SettingsPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sage", "settings.json");

    public static Uri? WorkerBaseUri
    {
        get
        {
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllBytes(SettingsPath));
                return document.RootElement.TryGetProperty("workerBaseUrl", out var value) && value.ValueKind == JsonValueKind.String
                    ? SageWorkerClient.ValidateBaseUri(value.GetString())
                    : null;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
            {
                return null;
            }
        }
        set
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(new Dictionary<string, string?>
            {
                ["workerBaseUrl"] = value?.ToString().TrimEnd('/'),
            }));
        }
    }

    public static unsafe string? AccessToken
    {
        get
        {
            if (!CredReadW(CredentialTarget, CredentialTypeGeneric, 0, out nint pointer))
            {
                int error = Marshal.GetLastPInvokeError();
                return error == ErrorNotFound ? null : throw new Win32Exception(error, "Couldn't read the Sage access token");
            }

            try
            {
                var credential = (Credential*)pointer;
                string token = Encoding.UTF8.GetString(credential->CredentialBlob, (int)credential->CredentialBlobSize);
                return SageWorkerClient.IsAccessTokenFormat(token) ? token : null;
            }
            finally
            {
                CredFree(pointer);
            }
        }
        set
        {
            if (value is null)
            {
                if (!CredDeleteW(CredentialTarget, CredentialTypeGeneric, 0) && Marshal.GetLastPInvokeError() != ErrorNotFound)
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError(), "Couldn't remove the Sage access token");
                }

                return;
            }

            if (!SageWorkerClient.IsAccessTokenFormat(value)) throw new ArgumentException("That isn't a Sage access token.");
            byte[] blob = Encoding.UTF8.GetBytes(value);
            fixed (byte* blobPointer = blob)
            fixed (char* target = CredentialTarget)
            fixed (char* user = "Sage")
            {
                var credential = new Credential
                {
                    Type = CredentialTypeGeneric,
                    TargetName = target,
                    UserName = user,
                    CredentialBlob = blobPointer,
                    CredentialBlobSize = (uint)blob.Length,
                    Persist = PersistLocalMachine,
                };
                if (!CredWriteW(credential, 0))
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError(), "Couldn't save the Sage access token");
                }
            }

            Array.Clear(blob);
        }
    }

    // MARK: - Credential Manager

    private const uint CredentialTypeGeneric = 1;
    // Stays on this PC for this user and doesn't roam with the profile.
    private const uint PersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    [StructLayout(LayoutKind.Sequential)]
    private unsafe struct Credential
    {
        public uint Flags;
        public uint Type;
        public char* TargetName;
        public char* Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public byte* CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public nint Attributes;
        public char* TargetAlias;
        public char* UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, uint type, uint flags, out nint credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(in Credential credential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(nint buffer);
}
