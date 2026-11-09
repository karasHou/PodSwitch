using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace PodSwitch.App.Platform;

/// <summary>HTTP endpoint bound to Tailscale IPv4 and restricted to the configured peer MagicDNS IP.</summary>
internal sealed class PeerSwitchServer : IDisposable
{
    private readonly Func<string> _peerHostProvider;
    private readonly Func<Task<bool>> _releaseHandler;
    private TcpListener? _listener;
    private CancellationTokenSource? _stop;
    private readonly SemaphoreSlim _releaseGate = new(1, 1);
    public bool IsRunning { get; private set; }
    public string? LastError { get; private set; }

    public PeerSwitchServer(Func<string> peerHostProvider, Func<Task<bool>> releaseHandler)
    {
        _peerHostProvider = peerHostProvider;
        _releaseHandler = releaseHandler;
    }

    public void Start(int port = 8765)
    {
        if (_listener is not null) return;
        var address = FindTailscaleIPv4();
        if (address is null)
        {
            LastError = "Tailscale IPv4 address not found";
            return;
        }

        try
        {
            var listener = new TcpListener(address, port);
            listener.Start();
            _listener = listener;
            _stop = new CancellationTokenSource();
            IsRunning = true;
            LastError = null;
            _ = AcceptLoopAsync(listener, _stop.Token);
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            IsRunning = false;
            _listener?.Stop();
            _listener = null;
        }
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
                _ = HandleAsync(client, cancellationToken);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception ex) { LastError = ex.Message; }
        finally { IsRunning = false; }
    }

    private async Task HandleAsync(TcpClient client, CancellationToken cancellationToken)
    {
        using (client)
        {
            try
            {
                client.ReceiveTimeout = 5000;
                client.SendTimeout = 5000;
                await using var stream = client.GetStream();
                using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true);

                var requestLine = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(requestLine))
                {
                    await RespondAsync(stream, 400, false, cancellationToken).ConfigureAwait(false);
                    return;
                }

                var parts = requestLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var method = parts.Length > 0 ? parts[0] : string.Empty;
                var path = parts.Length > 1 ? parts[1] : string.Empty;
                var headerBytes = requestLine.Length;
                for (var i = 0; i < 32; i++)
                {
                    var line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                    if (line is null || line.Length == 0) break;
                    headerBytes += line.Length;
                    if (headerBytes > 8192) throw new InvalidDataException("HTTP headers too large");
                }

                var remoteAddress = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.MapToIPv4();
                if (!IsAuthorizedPeer(remoteAddress, _peerHostProvider()))
                {
                    await RespondAsync(stream, 403, false, cancellationToken).ConfigureAwait(false);
                    return;
                }

                if (method == "GET" && path == "/health")
                {
                    await RespondAsync(stream, 200, true, cancellationToken).ConfigureAwait(false);
                    return;
                }

                if (method == "POST" && path == "/api/release")
                {
                    if (!await _releaseGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
                    {
                        await RespondAsync(stream, 409, false, cancellationToken).ConfigureAwait(false);
                        return;
                    }

                    try
                    {
                        var released = await _releaseHandler().WaitAsync(TimeSpan.FromSeconds(12), cancellationToken).ConfigureAwait(false);
                        await RespondAsync(stream, released ? 200 : 409, released, cancellationToken).ConfigureAwait(false);
                    }
                    finally
                    {
                        _releaseGate.Release();
                    }
                    return;
                }

                await RespondAsync(stream, 404, false, cancellationToken).ConfigureAwait(false);
            }
            catch
            {
                // A disconnected peer must never terminate the tray process.
            }
        }
    }

    private static bool IsAuthorizedPeer(IPAddress? remoteAddress, string peerHost)
    {
        if (remoteAddress is null || !IsTailscaleIPv4(remoteAddress) || string.IsNullOrWhiteSpace(peerHost))
            return false;

        try
        {
            return Dns.GetHostAddresses(peerHost.Trim())
                .Where(IsTailscaleIPv4)
                .Any(address => address.Equals(remoteAddress));
        }
        catch { return false; }
    }

    private static async Task RespondAsync(NetworkStream stream, int status, bool success, CancellationToken cancellationToken)
    {
        var reason = status switch
        {
            200 => "OK",
            400 => "Bad Request",
            403 => "Forbidden",
            404 => "Not Found",
            409 => "Conflict",
            _ => "Error"
        };
        var body = Encoding.UTF8.GetBytes($"{{\"success\":{success.ToString().ToLowerInvariant()}}}");
        var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(body, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static IPAddress? FindTailscaleIPv4()
    {
        try
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Where(adapter => adapter.OperationalStatus == OperationalStatus.Up)
                .SelectMany(adapter => adapter.GetIPProperties().UnicastAddresses)
                .Select(item => item.Address)
                .FirstOrDefault(IsTailscaleIPv4);
        }
        catch { return null; }
    }

    private static bool IsTailscaleIPv4(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork) return false;
        var bytes = address.GetAddressBytes();
        return bytes[0] == 100 && bytes[1] is >= 64 and <= 127;
    }

    public void Stop()
    {
        _stop?.Cancel();
        _listener?.Stop();
        _listener = null;
        _stop?.Dispose();
        _stop = null;
        IsRunning = false;
    }

    public void Dispose() => Stop();
}
