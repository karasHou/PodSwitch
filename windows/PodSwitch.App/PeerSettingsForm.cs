using PodSwitch.App.Platform;
using PodSwitch.Core;

namespace PodSwitch.App;

internal sealed class PeerSettingsForm : Form
{
    private readonly CheckBox _enabled = new() { Text = "Enable cross-device switching", AutoSize = true };
    private readonly TextBox _host = new() { PlaceholderText = "macbook.example.ts.net", Dock = DockStyle.Fill };
    private readonly NumericUpDown _port = new() { Minimum = 1, Maximum = 65535, Value = 8765, Width = 110 };
    private readonly Label _help = new()
    {
        AutoSize = true,
        MaximumSize = new Size(450, 0),
        Text = "Authentication: only the exact peer Tailscale IP resolved from this MagicDNS name is allowed. No shared token is required. Each computer must enter the other computer's MagicDNS name."
    };
    private readonly Label _status = new() { AutoSize = true, MaximumSize = new Size(450, 0), Text = "Tailscale peer identity authentication · TCP 8765" };

    public PeerSettings Settings => new(_enabled.Checked, _host.Text.Trim(), (int)_port.Value);

    public PeerSettingsForm(PeerSettings settings)
    {
        Text = "PodSwitch · Cross-device settings";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        ClientSize = new Size(540, 310);

        _enabled.Checked = settings.Enabled;
        _host.Text = settings.Host;
        _port.Value = settings.Port is > 0 and <= 65535 ? settings.Port : 8765;

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 3,
            RowCount = 6,
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 105));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        layout.Controls.Add(_enabled, 0, 0);
        layout.SetColumnSpan(_enabled, 3);
        layout.Controls.Add(_help, 0, 1);
        layout.SetColumnSpan(_help, 3);

        layout.Controls.Add(new Label { Text = "Peer MagicDNS", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 2);
        layout.Controls.Add(_host, 1, 2);
        var pasteHost = new Button { Text = "Paste", AutoSize = true };
        pasteHost.Click += (_, _) => PasteInto(_host);
        layout.Controls.Add(pasteHost, 2, 2);

        layout.Controls.Add(new Label { Text = "HTTP port", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 3);
        layout.Controls.Add(_port, 1, 3);
        var pastePort = new Button { Text = "Paste", AutoSize = true };
        pastePort.Click += (_, _) => PasteInto(_port);
        layout.Controls.Add(pastePort, 2, 3);

        layout.Controls.Add(_status, 0, 4);
        layout.SetColumnSpan(_status, 3);

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
        layout.Controls.Add(actions, 0, 5);
        layout.SetColumnSpan(actions, 3);

        Controls.Add(layout);
        AcceptButton = save;
        CancelButton = cancel;
    }

    private void PasteInto(Control target)
    {
        try
        {
            if (!Clipboard.ContainsText())
            {
                _status.Text = "Clipboard does not contain text.";
                return;
            }

            var value = Clipboard.GetText().Trim();
            if (target == _port)
            {
                if (decimal.TryParse(value, out var port) && port >= _port.Minimum && port <= _port.Maximum)
                    _port.Value = port;
                else
                    _status.Text = "Port must be between 1 and 65535.";
                return;
            }

            if (target is TextBox textBox) textBox.Text = value;
        }
        catch
        {
            _status.Text = "Unable to read clipboard. Try again.";
        }
    }

    private async Task TestConnectionAsync()
    {
        _status.Text = "Testing peer connection…";
        var settings = Settings;
        var result = await new PeerSwitchClient().DiagnoseAsync(settings.Host, settings.Port);
        _status.Text = result.Message;
    }
}
