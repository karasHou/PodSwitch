using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using PodSwitch.Core;

namespace PodSwitch.App.Platform;

/// <summary>Windows Bluetooth connector with verified connect and release operations.</summary>
internal sealed class WindowsBluetoothConnector : IBluetoothHandoff
{
    private const int MaxAttempts = 2;
    private const int VerifyTimeoutMs = 8000;
    private const int PollIntervalMs = 400;
    private const uint ServiceDisable = 0x00;
    private const uint ServiceEnable = 0x01;
    private const int ToggleGapMs = 1000;
    private const int EnableRetries = 3;
    private const int EnableRetryDelayMs = 1000;

    private static readonly Guid A2dpSink = new("0000110B-0000-1000-8000-00805F9B34FB");
    private static readonly Guid HandsFree = new("0000111E-0000-1000-8000-00805F9B34FB");

    public bool IsPaired(string targetDeviceId) => FindPairedDevice(Normalize(targetDeviceId)) is not null;

    public bool IsActiveOutput(string targetDeviceId)
    {
        var name = FindPairedName(Normalize(targetDeviceId));
        return name is not null && IsDefaultRenderEndpoint(name);
    }

    public void Connect(string targetDeviceId)
        => _ = ConnectAndWaitAsync(targetDeviceId);

    public Task<bool> DisconnectAndWaitAsync(string targetDeviceId, CancellationToken cancellationToken = default)
    {
        var normalized = Normalize(targetDeviceId);
        return Task.Run(() => DisconnectWithVerify(normalized, cancellationToken), cancellationToken);
    }

    public Task<bool> ConnectAndWaitAsync(string targetDeviceId, CancellationToken cancellationToken = default)
    {
        var normalized = Normalize(targetDeviceId);
        return Task.Run(() => ConnectWithVerify(normalized, cancellationToken), cancellationToken);
    }

    public IReadOnlyList<(string Address, string Name)> ListPairedDevices()
    {
        var list = new List<(string, string)>();
        EnumeratePaired(info =>
        {
            list.Add((FormatAddress(info.Address), info.szName));
            return true;
        });
        return list;
    }

    private bool DisconnectWithVerify(string normalizedAddress, CancellationToken cancellationToken)
    {
        var info = FindPairedDevice(normalizedAddress);
        if (info is null) return false;
        var deviceName = info.Value.szName;
        if (!IsAudioEndpointAvailable(deviceName) && !IsActiveOutput(normalizedAddress)) return true;

        var device = info.Value;
        _ = SetService(ref device, HandsFree, ServiceDisable);
        _ = SetService(ref device, A2dpSink, ServiceDisable);

        var waited = 0;
        while (waited < VerifyTimeoutMs)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Thread.Sleep(PollIntervalMs);
            waited += PollIntervalMs;
            if (!IsAudioEndpointAvailable(deviceName) && !IsActiveOutput(normalizedAddress))
                return true;
        }
        return false;
    }

    private bool ConnectWithVerify(string normalizedAddress, CancellationToken cancellationToken)
    {
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var name = FindPairedName(normalizedAddress);
            if (name is null) return false;
            if (IsBluetoothConnected(normalizedAddress) && IsDefaultRenderEndpoint(name)) return true;

            if (!ToggleAudioServices(normalizedAddress)) continue;

            var waited = 0;
            while (waited < VerifyTimeoutMs)
            {
                cancellationToken.ThrowIfCancellationRequested();
                Thread.Sleep(PollIntervalMs);
                waited += PollIntervalMs;
                TrySetDefaultEndpoint(name);
                if (IsBluetoothConnected(normalizedAddress) && IsDefaultRenderEndpoint(name)) return true;
            }
        }
        return false;
    }

    private bool ToggleAudioServices(string normalizedAddress)
    {
        var device = FindPairedDevice(normalizedAddress);
        if (device is null) return false;
        var info = device.Value;
        var hfp = ToggleService(ref info, HandsFree);
        var a2dp = ToggleService(ref info, A2dpSink);
        return hfp || a2dp;
    }

    private static bool ToggleService(ref BLUETOOTH_DEVICE_INFO info, Guid service)
    {
        _ = SetService(ref info, service, ServiceDisable);
        Thread.Sleep(ToggleGapMs);
        for (var i = 0; i < EnableRetries; i++)
        {
            if (SetService(ref info, service, ServiceEnable)) return true;
            Thread.Sleep(EnableRetryDelayMs);
        }
        return false;
    }

    private static bool SetService(ref BLUETOOTH_DEVICE_INFO info, Guid service, uint state)
    {
        var guid = service;
        try { return BluetoothSetServiceState(IntPtr.Zero, ref info, ref guid, state) == 0; }
        catch { return false; }
    }

    private bool IsBluetoothConnected(string normalizedAddress)
        => FindPairedDevice(normalizedAddress)?.fConnected == 1;

    private BLUETOOTH_DEVICE_INFO? FindPairedDevice(string normalizedAddress)
    {
        BLUETOOTH_DEVICE_INFO? found = null;
        EnumeratePaired(info =>
        {
            if (Normalize(FormatAddress(info.Address)) != normalizedAddress) return true;
            found = info;
            return false;
        });
        return found;
    }

    private string? FindPairedName(string normalizedAddress)
        => FindPairedDevice(normalizedAddress)?.szName;

    private static void EnumeratePaired(Func<BLUETOOTH_DEVICE_INFO, bool> onDevice)
    {
        var search = new BLUETOOTH_DEVICE_SEARCH_PARAMS
        {
            dwSize = (uint)Marshal.SizeOf<BLUETOOTH_DEVICE_SEARCH_PARAMS>(),
            fReturnAuthenticated = 1,
            fReturnRemembered = 1,
            fReturnUnknown = 0,
            fReturnConnected = 1,
            fIssueInquiry = 0,
            cTimeoutMultiplier = 0,
            hRadio = IntPtr.Zero,
        };
        var info = new BLUETOOTH_DEVICE_INFO { dwSize = (uint)Marshal.SizeOf<BLUETOOTH_DEVICE_INFO>() };
        var handle = BluetoothFindFirstDevice(ref search, ref info);
        if (handle == IntPtr.Zero) return;
        try
        {
            do
            {
                if (!onDevice(info)) return;
                info = new BLUETOOTH_DEVICE_INFO { dwSize = (uint)Marshal.SizeOf<BLUETOOTH_DEVICE_INFO>() };
            } while (BluetoothFindNextDevice(handle, ref info));
        }
        finally { BluetoothFindDeviceClose(handle); }
    }

    private bool IsAudioEndpointAvailable(string deviceName)
    {
        try
        {
            using var audio = new MMDeviceEnumerator();
            foreach (var endpoint in audio.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            {
                using (endpoint)
                {
                    if (EndpointMatches(endpoint.FriendlyName, deviceName)) return true;
                }
            }
        }
        catch { }
        return false;
    }

    private bool IsDefaultRenderEndpoint(string deviceName)
    {
        try
        {
            using var audio = new MMDeviceEnumerator();
            if (!audio.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)) return false;
            using var endpoint = audio.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            return EndpointMatches(endpoint.FriendlyName, deviceName);
        }
        catch { return false; }
    }

    private void TrySetDefaultEndpoint(string deviceName)
    {
        try
        {
            using var audio = new MMDeviceEnumerator();
            foreach (var endpoint in audio.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            {
                using (endpoint)
                {
                    if (!EndpointMatches(endpoint.FriendlyName, deviceName) || IsDefaultRenderEndpoint(deviceName)) continue;
                    var policy = (IPolicyConfig)new CPolicyConfigClient();
                    try
                    {
                        policy.SetDefaultEndpoint(endpoint.ID, 0);
                        policy.SetDefaultEndpoint(endpoint.ID, 1);
                        policy.SetDefaultEndpoint(endpoint.ID, 2);
                    }
                    finally { Marshal.ReleaseComObject(policy); }
                    return;
                }
            }
        }
        catch { }
    }

    private static bool EndpointMatches(string endpointName, string deviceName)
        => !string.IsNullOrEmpty(endpointName) && !string.IsNullOrEmpty(deviceName)
            && (endpointName.Contains(deviceName, StringComparison.OrdinalIgnoreCase)
                || deviceName.Contains(endpointName, StringComparison.OrdinalIgnoreCase));

    private static string FormatAddress(ulong address)
    {
        var bytes = new byte[6];
        for (var i = 0; i < 6; i++) bytes[i] = (byte)((address >> (8 * i)) & 0xFF);
        return $"{bytes[5]:X2}:{bytes[4]:X2}:{bytes[3]:X2}:{bytes[2]:X2}:{bytes[1]:X2}:{bytes[0]:X2}";
    }

    private static string Normalize(string address)
        => address.Replace(":", "").Replace("-", "").Replace(" ", "").ToLowerInvariant();

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEMTIME
    {
        public ushort wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct BLUETOOTH_DEVICE_INFO
    {
        public uint dwSize;
        public ulong Address;
        public uint ulClassofDevice;
        public int fConnected;
        public int fRemembered;
        public int fAuthenticated;
        public SYSTEMTIME stLastSeen;
        public SYSTEMTIME stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)]
        public string szName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BLUETOOTH_DEVICE_SEARCH_PARAMS
    {
        public uint dwSize;
        public int fReturnAuthenticated;
        public int fReturnRemembered;
        public int fReturnUnknown;
        public int fReturnConnected;
        public int fIssueInquiry;
        public byte cTimeoutMultiplier;
        public IntPtr hRadio;
    }

    [DllImport("bthprops.cpl", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr BluetoothFindFirstDevice(ref BLUETOOTH_DEVICE_SEARCH_PARAMS search, ref BLUETOOTH_DEVICE_INFO info);
    [DllImport("bthprops.cpl", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool BluetoothFindNextDevice(IntPtr handle, ref BLUETOOTH_DEVICE_INFO info);
    [DllImport("bthprops.cpl", SetLastError = true)]
    private static extern bool BluetoothFindDeviceClose(IntPtr handle);
    [DllImport("bthprops.cpl", SetLastError = true)]
    private static extern uint BluetoothSetServiceState(IntPtr radio, ref BLUETOOTH_DEVICE_INFO info, ref Guid service, uint flags);

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    private class CPolicyConfigClient { }

    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat(string deviceName, IntPtr format);
        [PreserveSig] int GetDeviceFormat(string deviceName, int isDefault, IntPtr format);
        [PreserveSig] int ResetDeviceFormat(string deviceName);
        [PreserveSig] int SetDeviceFormat(string deviceName, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod(string deviceName, int isDefault, IntPtr period, IntPtr minimum);
        [PreserveSig] int SetProcessingPeriod(string deviceName, IntPtr period);
        [PreserveSig] int GetShareMode(string deviceName, IntPtr mode);
        [PreserveSig] int SetShareMode(string deviceName, IntPtr mode);
        [PreserveSig] int GetPropertyValue(string deviceName, int fxStore, IntPtr key, IntPtr value);
        [PreserveSig] int SetPropertyValue(string deviceName, int fxStore, IntPtr key, IntPtr value);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceName, int role);
        [PreserveSig] int SetEndpointVisibility(string deviceName, int visible);
    }
}