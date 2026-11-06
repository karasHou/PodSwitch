# PodSwitch Tailscale setup

This fork adds a small peer-to-peer hand-off channel for Bluetooth headphones. Each computer runs its own PodSwitch HTTP endpoint, bound to its Tailscale IPv4 address. When audio starts on one computer, it asks the other computer to release the selected headphones before connecting locally.

## 1. Prepare Tailscale

1. Sign in to the same Tailnet on both computers.
2. Open the [Tailscale DNS settings](https://login.tailscale.com/admin/dns).
3. Enable **MagicDNS**.
4. In **Machines**, give the computers clear names, for example `macbook` and `windows-pc`.
5. Note each machine's full MagicDNS name, for example `macbook.example.ts.net`.

Use the real Tailnet suffix shown in your Tailscale admin console. The example names in this document are placeholders.

## 2. Configure PodSwitch on Windows

1. Pair the WH-1000XM3 with Windows and select it as PodSwitch's target device.
2. Open the tray menu → **Cross-device settings**.
3. Enable cross-device switching.
4. Set **Peer MagicDNS** to the Mac's full MagicDNS name, such as `macbook.example.ts.net`.
5. Keep the HTTP port at `8765`.
6. Click **Generate token**, then **Copy token**.
7. Save the settings.

## 3. Configure PodSwitch on macOS

1. Pair the WH-1000XM3 with macOS and select it as PodSwitch's target device.
2. Open the PodSwitch menu bar menu → **Cross-device settings**.
3. Enable Tailscale switching.
4. Set **Peer MagicDNS** to the Windows computer's full MagicDNS name, such as `windows-pc.example.ts.net`.
5. Keep the HTTP port at `8765`.
6. Paste the token generated on Windows.
7. Save, then use **Test connection**.

Both computers must use the same token and port. Each computer's Peer MagicDNS field points to the other computer.

## 4. Windows Firewall

The Windows endpoint binds to the Tailscale IPv4 address on TCP port 8765. If Windows Firewall blocks inbound traffic, open an elevated PowerShell and add a narrowly scoped rule:

```powershell
New-NetFirewallRule `
  -DisplayName "PodSwitch Tailscale peer" `
  -Direction Inbound `
  -Action Allow `
  -Protocol TCP `
  -LocalPort 8765 `
  -RemoteAddress 100.64.0.0/10 `
  -Profile Any
```

The rule only allows traffic sourced from Tailscale's IPv4 CGNAT range. To remove it later:

```powershell
Remove-NetFirewallRule -DisplayName "PodSwitch Tailscale peer"
```

On macOS, allow incoming connections for PodSwitch if the macOS application firewall prompts for permission.

## 5. Verify

1. Confirm Tailscale shows both computers as connected.
2. Open the PodSwitch peer settings on each computer and run **Test connection**.
3. Start audio on Mac. Windows should release the XM3 before Mac connects.
4. Start audio on Windows. Mac should release the XM3 before Windows connects.

The test endpoint only checks reachability and the shared token. It does not disconnect the headphones.

## Safety behaviour

- The peer server only binds to the local Tailscale IPv4 address.
- Every request requires the shared Bearer token.
- The server exposes only `GET /health` and `POST /api/release`.
- If the peer cannot be reached or does not confirm release, the initiating computer cancels its connection attempt.
- Local duplicate switch events are ignored while a hand-off is already running.
- No cloud server, database, or third-party relay is used.

If Tailscale starts after PodSwitch, reopen the peer settings and save once to retry starting the local peer server. Keep the same port on both computers.
