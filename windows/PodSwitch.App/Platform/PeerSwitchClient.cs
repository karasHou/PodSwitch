using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text.Json;
using PodSwitch.Core;

namespace PodSwitch.App.Platform;

internal sealed record PeerCheckResult(bool Success, string Message);

/// <summary>Direct HTTP client for the private Tailscale peer API; system proxies are bypassed.</summary>
internal sealed class PeerSwitchClient : IPeerSwitching
{
    private static readonly HttpClient Client = new(
        new HttpClientHandler { UseProxy = false })
    {
        Timeout = TimeSpan.FromSeconds(8)
    };

    public Task<bool> ReleasePeerAsync(string host, int port, CancellationToken cancellationToken = default)
        => RequestAsync(host, port, "/api/release", HttpMethod.Post, cancellationToken);

    public async Task<bool> CheckPeerAsync(string host, int port, CancellationToken cancellationToken = default)
        => (await DiagnoseAsync(host, port, cancellationToken).ConfigureAwait(false)).Success;

    public async Task<PeerCheckResult> DiagnoseAsync(string host, int port, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(host)) return new(false, "Peer MagicDNS 地址为空。");
        try
        {
            using var response = await Client.GetAsync(BuildUri(host, port, "/health"), cancellationToken).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.Forbidden)
                return new(false, "对端拒绝请求：请确认对端的 Peer MagicDNS 配置指向本机。");
            if (response.StatusCode == HttpStatusCode.Unauthorized)
                return new(false, "对端仍使用旧版 Token 认证，请更新两台电脑的 PodSwitch。");
            if (response.StatusCode == HttpStatusCode.NotFound)
                return new(false, "对端 API 版本不匹配，请更新两台电脑的 PodSwitch。");
            if (!response.IsSuccessStatusCode)
            {
                var detail = await DescribeResponseAsync(response, cancellationToken).ConfigureAwait(false);
                return new(false, $"对端返回 HTTP {(int)response.StatusCode}。{detail}");
            }

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var json = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);
            var success = json.RootElement.TryGetProperty("success", out var value) && value.GetBoolean();
            return success
                ? new(true, "连接成功：对端 Tailscale 身份验证通过。")
                : new(false, "对端响应异常，无法确认连接。");
        }
        catch (HttpRequestException ex) when (ex.InnerException is SocketException socket && socket.SocketErrorCode == SocketError.HostNotFound)
        {
            return new(false, "MagicDNS 无法解析，请检查主机名和 Tailscale DNS 设置。");
        }
        catch (HttpRequestException ex) when (ex.InnerException is SocketException socket && socket.SocketErrorCode == SocketError.ConnectionRefused)
        {
            return new(false, "对端拒绝连接，请确认 PodSwitch 已运行且端口正确。");
        }
        catch (TaskCanceledException)
        {
            return new(false, "连接超时，请检查 Tailscale 在线状态、防火墙和对端服务。");
        }
        catch (Exception ex)
        {
            return new(false, $"连接失败：{ex.Message}");
        }
    }

    private static async Task<string> DescribeResponseAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        var details = new List<string>();
        if (response.Headers.Server.Count > 0)
            details.Add($"Server: {string.Join(", ", response.Headers.Server)}");
        if (response.Headers.Via.Count > 0)
            details.Add($"Via: {string.Join(", ", response.Headers.Via)}");

        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!string.IsNullOrWhiteSpace(body))
            details.Add($"响应：{body[..Math.Min(body.Length, 220)]}");

        return details.Count == 0 ? "请检查对端服务、代理和网络路径。" : string.Join("；", details);
    }

    private static async Task<bool> RequestAsync(string host, int port, string path, HttpMethod method, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(host) || port is < 1 or > 65535) return false;
        try
        {
            using var response = await Client.SendAsync(new HttpRequestMessage(method, BuildUri(host, port, path)), cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return false;
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var json = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);
            return json.RootElement.TryGetProperty("success", out var success) && success.GetBoolean();
        }
        catch { return false; }
    }

    private static Uri BuildUri(string host, int port, string path)
    {
        if (port is < 1 or > 65535) throw new ArgumentOutOfRangeException(nameof(port));
        return new Uri($"http://{host.Trim()}:{port}{path}");
    }
}
