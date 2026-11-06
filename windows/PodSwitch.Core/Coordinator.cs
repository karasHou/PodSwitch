namespace PodSwitch.Core;

/// <summary>Coordinates local Bluetooth switching and optional peer release over Tailscale.</summary>
public sealed class Coordinator
{
    private readonly ISettingsStore _settings;
    private readonly IBluetoothConnector _connector;
    private readonly IPeerSwitching? _peer;
    private readonly INotifier _notifier;
    private bool _notificationPending;
    private int _switchInProgress;

    public Coordinator(ISettingsStore settings, IBluetoothConnector connector, INotifier notifier, IPeerSwitching? peer = null)
    {
        _settings = settings;
        _connector = connector;
        _notifier = notifier;
        _peer = peer;
    }

    public void Handle(SwitchEvent ev)
    {
        var config = _settings.CurrentConfig();
        var target = config.TargetDeviceId;
        var paired = target is not null && _connector.IsPaired(target);
        var active = target is not null && _connector.IsActiveOutput(target);
        var status = new DeviceStatus(paired, active, _notificationPending);

        switch (SwitchEngine.Decide(ev, config, status))
        {
            case SwitchAction.None:
                break;
            case SwitchAction.Notify:
                _notificationPending = true;
                _notifier.ShowAsk();
                break;
            case SwitchAction.Connect:
                _notificationPending = false;
                _notifier.ClearAsk();
                if (target is not null) BeginConnect(target);
                break;
        }

        if (ev is SwitchEvent.AudioStopped && _notificationPending)
        {
            _notificationPending = false;
            _notifier.ClearAsk();
        }
    }

    private void BeginConnect(string target)
    {
        var peerSettings = (_settings as IPeerSettingsStore)?.CurrentPeerSettings() ?? PeerSettings.Disabled;
        if (!peerSettings.Enabled)
        {
            _connector.Connect(target);
            return;
        }

        if (Interlocked.CompareExchange(ref _switchInProgress, 1, 0) != 0) return;
        _ = SwitchAsync(target, peerSettings);
    }

    private async Task SwitchAsync(string target, PeerSettings peerSettings)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(peerSettings.Host) || string.IsNullOrWhiteSpace(peerSettings.Token))
            {
                ShowFailure("Configure the peer MagicDNS name and shared token first.");
                return;
            }

            var released = _peer is not null && await _peer.ReleasePeerAsync(peerSettings.Host, peerSettings.Port, peerSettings.Token).ConfigureAwait(false);
            if (!released)
            {
                ShowFailure("Peer did not confirm headphone release. Switching cancelled.");
                return;
            }

            if (_connector is not IBluetoothHandoff handoff)
            {
                ShowFailure("This Bluetooth connector does not support verified switching.");
                return;
            }

            if (!await handoff.ConnectAndWaitAsync(target).ConfigureAwait(false))
                ShowFailure("Could not connect to the headphones. Check Bluetooth.");
        }
        catch (Exception ex)
        {
            ShowFailure($"Switch failed: {ex.Message}");
        }
        finally
        {
            Volatile.Write(ref _switchInProgress, 0);
        }
    }

    private void ShowFailure(string message)
    {
        if (_notifier is ISwitchFailureNotifier failureNotifier)
            failureNotifier.ShowFailure(message);
    }
}