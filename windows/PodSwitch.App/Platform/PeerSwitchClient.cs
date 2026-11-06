using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text.Json;
using PodSwitch.Core;

namespace PodSwitch.App.Platform;

internal sealed record PeerCheckResult(bool Success, string Message);

/// <summary>Calls the peer's authenticated HTTP endpoint over Tailscale.</summary>
internal sealed class PeerSwitchClient : IPeerSwitching
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(10) };

    public Task<bool> ReleasePeerAsync(string host, int port, string token, CancellationToken cancellationToken = default)
        => RequestAsync(host, port, token, "/api/release", cancellationToken);

    public async Task<bool> CheckPeerAsync(string host, int port, string token, CancellationToken cancellationToken = default)
        => (await DiagnoseAsync(host, port, token, cancellationToken).ConfigureAwait(false)).Success;

    public async Task<PeerCheckResult> DiagnoseAsync(string host, int port, string token, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(host))
            return new(false, "MagicDNS 地址为空。");
        if (string.IsNullOrWhiteSpace(token))
            return new(false, "Token 为空。");

        try
        {
            using var request = CreateRequest(host, port, token, "/health", HttpMethod.Get);
            using var response = await Client.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.Unauthorized)
                return new(false, "对端服务可达，但 Token 不匹配（HTTP 401）。请检查两端 Token 是否完全一致。");
            if (response.StatusCode == HttpStatusCode.NotFound)
                return new(false, "对端服务可达，但 API 路径不存在（HTTP 404）。请更新两端 PodSwitch。");
            if (!response.IsSuccessStatusCode)
                return new(false, $"对端返回 HTTP {(int)response.StatusCode}。");

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var json = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);
            var success = json.RootElement.TryGetProperty("success", out var value) && value.GetBoolean();
            return success
                ? new(true, "连接成功：对端服务可达，Token 验证通过。")
                : new(false, "对端响应异常，未能确认 Token。");
        }
        catch (HttpRequestException ex) when (ex.InnerException is SocketException socket && socket.SocketErrorCode == SocketError.HostNotFound)
        {
            return new(false, "MagicDNS 无法解析。请检查主机名和 Tailscale DNS 设置。");
        }
        catch (HttpRequestException ex) when (ex.InnerException is SocketException socket && socket.SocketErrorCode == SocketError.ConnectionRefused)
        {
            return new(false, "对端拒绝连接。请确认 PodSwitch 已运行，且端口正确。");
        }
        catch (TaskCanceledException)
        {
            return new(false, "连接超时。请检查 Tailscale 在线状态、防火墙和对端服务。");
        }
        catch (Exception ex)
        {
            return new(false, $"连接失败：{ex.Message}");
        }
    }

    private static async Task<bool> RequestAsync(string host, int port, string token, string path, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(host) || string.IsNullOrWhiteSpace(token) || port is < 1 or > 65535)
            return false;
        try
        {
            using var request = CreateRequest(host, port, token, path, path == "/api/release" ? HttpMethod.Post : HttpMethod.Get);
            using var response = await Client.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return false;
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var json = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);
            return json.RootElement.TryGetProperty("success", out var success) && success.GetBoolean();
        }
        catch { return false; }
    }

    private static HttpRequestMessage CreateRequest(string host, int port, string token, string path, HttpMethod method)
    {
        if (port is < 1 or > 65535) throw new ArgumentOutOfRangeException(nameof(port));
        var request = new HttpRequestMessage(method, $"http://{host.Trim()}:{port}{path}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Trim());
        return request;
    }
}