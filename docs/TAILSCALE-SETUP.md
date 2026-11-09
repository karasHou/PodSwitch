# PodSwitch Tailscale setup

This fork adds a peer-to-peer hand-off channel for single-connection Bluetooth headphones such as the Sony WH-1000XM3. Each computer runs a small HTTP endpoint bound to its Tailscale IPv4 address. The endpoint authenticates the caller by checking that its source IP exactly matches the IPv4 address resolved from the configured peer MagicDNS name. The macOS app includes a narrowly scoped App Transport Security exception for the `.ts.net` MagicDNS domain because this HTTP traffic is carried inside Tailscale's encrypted WireGuard tunnel. HTTPS remains required for all other domains.

**No shared token, pairing code, cloud service, or account is required.**

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
6. Save the settings.

## 3. Configure PodSwitch on macOS

1. Pair the WH-1000XM3 with macOS and select it as PodSwitch's target device.
2. Open the PodSwitch menu bar menu → **Cross-device settings**.
3. Enable Tailscale switching.
4. Set **Peer MagicDNS** to the Windows computer's full MagicDNS name, such as `windows-pc.example.ts.net`.
5. Keep the HTTP port at `8765`.
6. Save, then use **Test connection**.

**Each computer must enter the other computer's MagicDNS name.** The app resolves that name and only accepts requests whose Tailscale source IPv4 exactly matches the resolved peer address. Existing saved Token values are ignored by this version.

## 4. Windows Firewall

The Windows endpoint binds to the local Tailscale IPv4 address on TCP port 8765. The app also validates the exact remote peer IP. For an additional firewall restriction, obtain the Mac's Tailscale IPv4 address by running `tailscale ip -4` on the Mac, then run PowerShell as Administrator on Windows:

```powershell
New-NetFirewallRule `
  -DisplayName "PodSwitch Tailscale peer" `
  -Direction Inbound `
  -Action Allow `
  -Protocol TCP `
  -LocalPort 8765 `
  -RemoteAddress 100.100.100.100/32 `
  -Profile Any
```

Replace `100.100.100.100` with the actual Mac Tailscale IPv4 address. To remove the rule later:

```powershell
Remove-NetFirewallRule -DisplayName "PodSwitch Tailscale peer"
```

On macOS, allow incoming connections for PodSwitch if the macOS application firewall prompts for permission.

## 5. Verify

1. Confirm Tailscale shows both computers as connected.
2. Open PodSwitch peer settings on both computers and run **Test connection**.
3. A successful test means the peer service is reachable and the source IP matches the configured peer MagicDNS address.
4. HTTP 403 means the receiving computer's Peer MagicDNS field does not resolve to the requester's Tailscale IPv4 address.
5. HTTP 401 means the other computer is still running the old Token-authenticated version; update both computers.
6. Start audio on Mac. Windows should release the XM3 before Mac connects.
7. Start audio on Windows. Mac should release the XM3 before Windows connects.

The test endpoint checks reachability and peer identity. It does not disconnect the headphones.

## Safety behaviour

- Each server binds only to its local Tailscale IPv4 address.
- Each request is accepted only from the exact peer IPv4 address resolved from the configured MagicDNS name.
- The server exposes only `GET /health` and `POST /api/release`.
- If the peer cannot be reached or does not confirm release, the initiating computer cancels its connection attempt.
- On macOS, cross-device audio switching is automatic and silent. Failures are written to the macOS unified log.
- Local duplicate switch events and duplicate release requests are guarded.
- No cloud server, database, shared secret, or third-party relay is used.

If Tailscale starts after PodSwitch, reopen peer settings and save once to retry starting the local peer server. Keep the same port on both computers.
