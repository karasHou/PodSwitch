namespace PodSwitch.Core;

public interface IAudioMonitor
{
    void Start(Action<SwitchEvent> onEvent);
    void Stop();
}

public interface IBluetoothConnector
{
    bool IsPaired(string targetDeviceId);
    bool IsActiveOutput(string targetDeviceId);
    void Connect(string targetDeviceId);
}

/// <summary>Verified async Bluetooth operations used by cross-device switching.</summary>
public interface IBluetoothHandoff : IBluetoothConnector
{
    Task<bool> DisconnectAndWaitAsync(string targetDeviceId, CancellationToken cancellationToken = default);
    Task<bool> ConnectAndWaitAsync(string targetDeviceId, CancellationToken cancellationToken = default);
}

public interface IPeerSwitching
{
    Task<bool> ReleasePeerAsync(string host, int port, string token, CancellationToken cancellationToken = default);
    Task<bool> CheckPeerAsync(string host, int port, string token, CancellationToken cancellationToken = default);
}

public interface IPeerSettingsStore
{
    PeerSettings CurrentPeerSettings();
}

public interface INotifier
{
    void ShowAsk();
    void ClearAsk();
}

public interface ISwitchFailureNotifier
{
    void ShowFailure(string message);
}

public interface ISettingsStore
{
    Config CurrentConfig();
}