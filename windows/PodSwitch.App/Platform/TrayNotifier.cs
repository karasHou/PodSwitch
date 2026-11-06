using PodSwitch.Core;

namespace PodSwitch.App.Platform;

/// <summary>ASK-mode prompt using a tray balloon; clicking it raises <see cref="AcceptRequested"/>.</summary>
// All NotifyIcon calls must happen on the UI thread (the tray owns it).
internal sealed class TrayNotifier : INotifier, ISwitchFailureNotifier
{
    private readonly NotifyIcon _tray;
    private bool _pending;

    /// <summary>Raised on the UI thread when the user clicks the ASK balloon.</summary>
    public event Action? AcceptRequested;

    public TrayNotifier(NotifyIcon tray)
    {
        _tray = tray;
        _tray.BalloonTipClicked += (_, _) =>
        {
            if (_pending)
            {
                _pending = false;
                AcceptRequested?.Invoke();
            }
        };
    }

    public void ShowAsk()
    {
        _pending = true;
        _tray.BalloonTipTitle = "Move audio here?";
        _tray.BalloonTipText = "Audio started playing on this PC. Click to connect your headphones.";
        _tray.ShowBalloonTip(5000);
    }

    public void ClearAsk()
    {
        _pending = false;
        _tray.Visible = false;
        _tray.Visible = true;
    }

    public void ShowFailure(string message)
    {
        _tray.BalloonTipTitle = "PodSwitch";
        _tray.BalloonTipText = message;
        _tray.ShowBalloonTip(5000);
    }
}
