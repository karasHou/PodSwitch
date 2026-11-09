using PodSwitch.App.Platform;
using PodSwitch.Core;

namespace PodSwitch.App;

internal sealed class TrayApp : ApplicationContext
{
    private readonly Control _uiAnchor = new();
    private readonly NotifyIcon _tray;
    private readonly JsonSettingsStore _settings = new();
    private readonly WindowsBluetoothConnector _bluetooth = new();
    private readonly TrayNotifier _notifier;
    private readonly WasapiAudioMonitor _monitor = new();
    private readonly Coordinator _coordinator;
    private readonly PeerSwitchServer _peerServer;

    public TrayApp()
    {
        _ = _uiAnchor.Handle;
        _tray = new NotifyIcon { Icon = LoadTrayIcon(), Visible = true, Text = "PodSwitch" };
        _notifier = new TrayNotifier(_tray);
        _coordinator = new Coordinator(_settings, _bluetooth, _notifier, new PeerSwitchClient());
        _notifier.AcceptRequested += () => _coordinator.Handle(new SwitchEvent.UserAcceptedSwitch());

        _peerServer = new PeerSwitchServer(
            () => _settings.CurrentPeerSettings().Host,
            async () =>
            {
                var target = _settings.TargetDeviceId;
                return target is not null && await _bluetooth.DisconnectAndWaitAsync(target).ConfigureAwait(false);
            });
        RefreshPeerServer();

        _tray.ContextMenuStrip = new ContextMenuStrip();
        _tray.ContextMenuStrip.Opening += (_, _) => RebuildMenu();
        RebuildMenu();
        _monitor.Start(ev => _coordinator.Handle(ev));
    }

    private void RebuildMenu()
    {
        var menu = _tray.ContextMenuStrip!;
        menu.Items.Clear();

        var enabled = new ToolStripMenuItem("Enabled") { Checked = _settings.Enabled };
        enabled.Click += (_, _) => _settings.SetEnabled(!_settings.Enabled);
        menu.Items.Add(enabled);
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(new ToolStripMenuItem("When audio starts") { Enabled = false });
        var steal = new ToolStripMenuItem("Switch automatically") { Checked = _settings.Mode == Mode.Steal };
        steal.Click += (_, _) => _settings.SetMode(Mode.Steal);
        menu.Items.Add(steal);
        var ask = new ToolStripMenuItem("Ask me first") { Checked = _settings.Mode == Mode.Ask };
        ask.Click += (_, _) => _settings.SetMode(Mode.Ask);
        menu.Items.Add(ask);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Target device") { Enabled = false });
        try
        {
            var devices = _bluetooth.ListPairedDevices();
            if (devices.Count == 0)
            {
                menu.Items.Add(new ToolStripMenuItem("No paired Bluetooth devices") { Enabled = false });
            }
            else
            {
                var current = Normalize(_settings.TargetDeviceId);
                foreach (var (address, name) in devices)
                {
                    var item = new ToolStripMenuItem(name) { Checked = Normalize(address) == current };
                    string a = address, n = name;
                    item.Click += (_, _) => _settings.SetTarget(a, n);
                    menu.Items.Add(item);
                }
            }
        }
        catch { menu.Items.Add(new ToolStripMenuItem("Bluetooth unavailable") { Enabled = false }); }

        menu.Items.Add(new ToolStripSeparator());
        var peerSettings = new ToolStripMenuItem("Cross-device settings…");
        peerSettings.Click += (_, _) => ShowPeerSettings();
        menu.Items.Add(peerSettings);
        var peerStatus = new ToolStripMenuItem(_peerServer.IsRunning ? "Peer service: listening" : "Peer service: unavailable")
        {
            Enabled = false
        };
        menu.Items.Add(peerStatus);

        menu.Items.Add(new ToolStripSeparator());
        var autostart = new ToolStripMenuItem("Start at login") { Checked = Autostart.IsEnabled() };
        autostart.Click += (_, _) => Autostart.SetEnabled(!Autostart.IsEnabled());
        menu.Items.Add(autostart);
        var quit = new ToolStripMenuItem("Quit PodSwitch");
        quit.Click += (_, _) => ExitApp();
        menu.Items.Add(quit);
    }

    private void ShowPeerSettings()
    {
        using var form = new PeerSettingsForm(_settings.CurrentPeerSettings());
        if (form.ShowDialog() != DialogResult.OK) return;
        _settings.SetPeerSettings(form.Settings);
        RefreshPeerServer();
        RebuildMenu();
    }

    private void RefreshPeerServer()
    {
        _peerServer.Stop();
        var peer = _settings.CurrentPeerSettings();
        if (peer.Enabled && !string.IsNullOrWhiteSpace(peer.Host))
            _peerServer.Start(peer.Port);
    }

    private void ExitApp()
    {
        _monitor.Stop();
        _peerServer.Stop();
        _tray.Visible = false;
        ExitThread();
    }

    private static string Normalize(string? address)
        => (address ?? string.Empty).Replace(":", "").Replace("-", "").ToLowerInvariant();

    private static Icon LoadTrayIcon()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exe))
            {
                var icon = Icon.ExtractAssociatedIcon(exe);
                if (icon is not null) return icon;
            }
        }
        catch { }
        return SystemIcons.Application;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _monitor.Stop();
            _peerServer.Stop();
            _tray.Dispose();
            _uiAnchor.Dispose();
        }
        base.Dispose(disposing);
    }
}
