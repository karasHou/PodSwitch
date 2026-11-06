using System.Security.Cryptography;
using PodSwitch.Core;

namespace PodSwitch.App;

/// <summary>Small settings dialog for the peer MagicDNS endpoint and shared token.</summary>
internal sealed class PeerSettingsForm : Form
{
    private readonly CheckBox _enabled = new() { Text = "Enable cross-device switching", AutoSize = true };
    private readonly TextBox _host = new() { PlaceholderText = "macbook.example.ts.net", Dock = DockStyle.Fill };
    private readonly NumericUpDown _port = new() { Minimum = 1, Maximum = 65535, Value = 8765, Width = 110 };
    private readonly TextBox _token = new() { UseSystemPasswordChar = true, Dock = DockStyle.Fill };
    private readonly Label _status = new() { AutoSize = true, Text = "Enter the peer MagicDNS name and shared token." };

    public PeerSettings Settings => new(_enabled.Checked, _host.Text.Trim(), (int)_port.Value, _token.Text.Trim());

    public PeerSettingsForm(PeerSettings settings)
    {
        Text = "PodSwitch · Cross-device settings";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        ClientSize = new Size(470, 300);

        _enabled.Checked = settings.Enabled;
        _host.Text = settings.Host;
        _port.Value = settings.Port is > 0 and <= 65535 ? settings.Port : 8765;
        _token.Text = settings.Token;

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 2,
            RowCount = 7,
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 105));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.Controls.Add(_enabled, 0, 0);
        layout.SetColumnSpan(_enabled, 2);
        layout.Controls.Add(new Label { Text = "Peer MagicDNS", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 1);
        layout.Controls.Add(_host, 1, 1);
        layout.Controls.Add(new Label { Text = "HTTP port", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 2);
        layout.Controls.Add(_port, 1, 2);
        layout.Controls.Add(new Label { Text = "Shared token", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 3);
        layout.Controls.Add(_token, 1, 3);
        layout.Controls.Add(_status, 0, 4);
        layout.SetColumnSpan(_status, 2);

        var tokenButtons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        var generate = new Button { Text = "Generate token", AutoSize = true };
        generate.Click += (_, _) => _token.Text = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var copy = new Button { Text = "Copy token", AutoSize = true };
        copy.Click += (_, _) =>
        {
            if (!string.IsNullOrWhiteSpace(_token.Text)) Clipboard.SetText(_token.Text);
        };
        tokenButtons.Controls.Add(generate);
        tokenButtons.Controls.Add(copy);
        layout.Controls.Add(tokenButtons, 0, 5);
        layout.SetColumnSpan(tokenButtons, 2);

        var actions = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true
        };
        var save = new Button { Text = "Save", DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true };
        var test = new Button { Text = "Test connection", AutoSize = true };
        test.Click += async (_, _) => await TestConnectionAsync();
        actions.Controls.Add(save);
        actions.Controls.Add(cancel);
        actions.Controls.Add(test);
        layout.Controls.Add(actions, 0, 6);
        layout.SetColumnSpan(actions, 2);

        Controls.Add(layout);
        AcceptButton = save;
        CancelButton = cancel;
    }

    private async Task TestConnectionAsync()
    {
        _status.Text = "Testing peer connection…";
        var settings = Settings;
        var success = await new PeerSwitchClient().CheckPeerAsync(settings.Host, settings.Port, settings.Token);
        _status.Text = success
            ? "Connected: peer is reachable and token is valid."
            : "Connection failed. Check Tailscale, MagicDNS, port and token.";
    }
}