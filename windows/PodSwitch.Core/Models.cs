namespace PodSwitch.Core;

public enum Mode { Steal, Ask }
public enum Category { Media }
public enum SwitchAction { None, Connect, Notify }

public sealed record Config(
    bool Enabled,
    Mode Mode,
    IReadOnlySet<Category> EnabledCategories,
    string? TargetDeviceId);

/// <summary>Remote peer settings. Both devices use the same shared bearer token.</summary>
public sealed record PeerSettings(bool Enabled, string Host, int Port, string Token)
{
    public static PeerSettings Disabled { get; } = new(false, string.Empty, 8765, string.Empty);
}

public sealed record DeviceStatus(
    bool TargetPaired,
    bool TargetActiveOutput,
    bool NotificationPending);

public abstract record SwitchEvent
{
    private SwitchEvent() { }
    public sealed record AudioStarted(Category Category) : SwitchEvent;
    public sealed record UserAcceptedSwitch : SwitchEvent;
    public sealed record AudioStopped : SwitchEvent;
}