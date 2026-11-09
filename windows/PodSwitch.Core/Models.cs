namespace PodSwitch.Core;

public enum Mode { Steal, Ask }
public enum Category { Media }
public enum SwitchAction { None, Connect, Notify }

public sealed record Config(
    bool Enabled,
    Mode Mode,
    IReadOnlySet<Category> EnabledCategories,
    string? TargetDeviceId);

/// <summary>The peer MagicDNS hostname is also the inbound Tailscale IP allowlist.</summary>
public sealed record PeerSettings(bool Enabled, string Host, int Port)
{
    public static PeerSettings Disabled { get; } = new(false, string.Empty, 8765);
}

public sealed record DeviceStatus(bool TargetPaired, bool TargetActiveOutput, bool NotificationPending);

public abstract record SwitchEvent
{
    private SwitchEvent() { }
    public sealed record AudioStarted(Category Category) : SwitchEvent;
    public sealed record UserAcceptedSwitch : SwitchEvent;
    public sealed record AudioStopped : SwitchEvent;
}
