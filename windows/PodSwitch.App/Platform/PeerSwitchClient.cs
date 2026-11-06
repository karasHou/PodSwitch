using System.Net.Http.Headers;
using System.Text.Json;
using PodSwitch.Core;

namespace PodSwitch.App.Platform;

/// <summary>Calls the peer's authenticated HTTP endpoint over Tailscale.</summary>
internal sealed class PeerSwitchClient : IPeerSwitching
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(10) };

    public Task<bool> ReleasePeerAsync(string host, int port, string token, CancellationToken cancellationToken = default)
        => RequestAsync(host, port, token, "/api/release", cancellationToken);

    public Task<bool> CheckPeerAsync(string host, int port, string token, CancellationToken cancellationToken = default)
        => RequestAsync(host, port, token, "/health", cancellationToken);

    private static async Task<bool> RequestAsync(string host, int port, string token, string path, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(host) || string.IsNullOrWhiteSpace(token) || port is < 1 or > 65535)
            return false;

        try
        {
            var method = path == "/api/release" ? HttpMethod.Post : HttpMethod.Get;
            using var request = new HttpRequestMessage(method, $"http://{host}:{port}{path}");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await Client.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return false;

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var json = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);
            return json.RootElement.TryGetProperty("success", out var success) && success.GetBoolean();
        }
        catch
        {
            return false;
        }
    }
}