using System.Text.Json;
using PodSwitch.Core;

namespace PodSwitch.App.Platform;

/// <summary>JSON-file-backed settings store at %APPDATA%\PodSwitch\settings.json.</summary>
internal sealed class JsonSettingsStore : ISettingsStore, IPeerSettingsStore
{
    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PodSwitch");
    private static readonly string FilePath = Path.Combine(Dir, "settings.json");
    private static readonly IReadOnlySet<Category> AllMedia = new HashSet<Category> { Category.Media };
    private readonly object _lock = new();
    private Persisted _state;

    private sealed class Persisted
    {
        public bool Enabled { get; set; }
        public Mode Mode { get; set; } = Mode.Ask;
        public string? TargetDeviceId { get; set; }
        public string? TargetDeviceName { get; set; }
        public bool PeerEnabled { get; set; }
        public string PeerHost { get; set; } = string.Empty;
        public int PeerPort { get; set; } = 8765;
        public string PeerToken { get; set; } = string.Empty;
    }

    public JsonSettingsStore() => _state = Load();

    public Config CurrentConfig()
    {
        lock (_lock) return new Config(_state.Enabled, _state.Mode, AllMedia, _state.TargetDeviceId);
    }

    public PeerSettings CurrentPeerSettings()
    {
        lock (_lock)
        {
            var port = _state.PeerPort is > 0 and <= 65535 ? _state.PeerPort : 8765;
            return new PeerSettings(_state.PeerEnabled, _state.PeerHost, port, _state.PeerToken);
        }
    }

    public bool Enabled { get { lock (_lock) return _state.Enabled; } }
    public Mode Mode { get { lock (_lock) return _state.Mode; } }
    public string? TargetDeviceId { get { lock (_lock) return _state.TargetDeviceId; } }
    public string? TargetDeviceName { get { lock (_lock) return _state.TargetDeviceName; } }

    public void SetEnabled(bool enabled) => Mutate(s => s.Enabled = enabled);
    public void SetMode(Mode mode) => Mutate(s => s.Mode = mode);
    public void SetTarget(string? address, string? name) => Mutate(s =>
    {
        s.TargetDeviceId = address;
        s.TargetDeviceName = name;
    });
    public void SetPeerSettings(PeerSettings settings) => Mutate(s =>
    {
        s.PeerEnabled = settings.Enabled;
        s.PeerHost = settings.Host;
        s.PeerPort = settings.Port;
        s.PeerToken = settings.Token;
    });

    private void Mutate(Action<Persisted> change)
    {
        lock (_lock)
        {
            change(_state);
            Save(_state);
        }
    }

    private static Persisted Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<Persisted>(File.ReadAllText(FilePath)) ?? new Persisted();
        }
        catch { }
        return new Persisted();
    }

    private static void Save(Persisted state)
    {
        try
        {
            Directory.CreateDirectory(Dir);
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(state, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, FilePath, overwrite: true);
        }
        catch { }
    }
}