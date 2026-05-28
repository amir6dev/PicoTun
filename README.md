# PicoTun

[![Version](https://img.shields.io/badge/version-v2.5.2-blue)](https://github.com/amir6dev/PicoTun/releases)
[![Go](https://img.shields.io/badge/go-1.22-00ADD8)](https://go.dev)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)](#)

**Encrypted Reverse Tunnel** with RFC 6455 WebSocket framing, advanced DPI bypass, multi-port load balancing, and high-capacity support (120+ users).

Designed for environments with deep packet inspection — Iran's filtering system, corporate firewalls, and similar.

---

## Architecture

```
[Users] → [Iran Server :2020/:2021/:2022] ←smux/WS/AES-256-GCM← [Kharej Server] → [Internet]
```

The Iran server **listens** for tunnel connections from Kharej. User traffic on the Iran side is forwarded through the encrypted tunnel to Kharej, which routes it to the open internet. The connection is initiated outbound from Kharej — Iran server never needs to reach Kharej's IP.

---

## Quick Install

Run on **both** servers (Iran and Kharej):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
```

---

## What's New in v2.5.2 — WebSocket Framing

The most significant anti-DPI improvement to date.

### RFC 6455 WebSocket Framing

After the HTTP upgrade handshake, **all tunnel data is wrapped in proper RFC 6455 binary frames**. Previously the tunnel used raw TCP after the handshake — DPI systems could detect this because the traffic pattern didn't match a real WebSocket connection.

- **Proper `Sec-WebSocket-Accept`**: The server now computes `SHA-1(clientKey + WS magic UUID)` and returns the correct base64 value. Previously a hardcoded RFC-example key was used — trivially detectable.
- **Client masking**: Client→Server frames use a random 4-byte mask key per frame (required by RFC 6455). Server→Client frames are unmasked. DPI expects this asymmetry from real browsers.
- **Opcode 0x02**: All frames use the binary opcode, matching real WebSocket data transfers from browsers.

### Domain Pool (18 domains)

Each connection picks a random domain for its `Host` header and HTTP mimic headers:

```
accounts.google.com    meet.google.com       classroom.google.com
docs.google.com        mail.google.com        drive.google.com
teams.microsoft.com    login.microsoftonline.com  outlook.live.com
onedrive.live.com      cdnjs.cloudflare.com   challenges.cloudflare.com
gateway.icloud.com     api.apple-cloudkit.com
d1.awsstatic.com       api.amazon.com
notify.bugsnag.com     ws.postman-echo.com
```

### Updated User-Agent Pool

Rotates among current browser fingerprints:
- Chrome 124, 125, 126 (Windows + macOS)
- Firefox 125, 127
- Edge 124, 125
- Safari 17.4.1 (macOS + iOS)

### Improved Stealth Defaults

| Parameter | v2.5.1 | v2.5.2 |
|---|---|---|
| Min padding | 16 bytes | 32 bytes |
| Max padding | 128 bytes | 256 bytes |
| Conn jitter | 500ms | 800ms |
| Fake traffic interval | 30s | 20s |
| Keepalive jitter | ±2s | ±3s |

---

## What's New in v2.5.1

- **Domain rotation** across 16 popular domains (now expanded to 18 in v2.5.2)
- **User-Agent rotation** — random browser fingerprint per connection
- **Header randomization** — shuffled HTTP header order
- **Response randomization** — varying server names (nginx/Apache/cloudflare/gws)
- **Random query strings** — unique URL parameters per connection
- **TCP fragmentation for httpmux** — enabled by default for plain HTTP mode
- **2× SMUX/TCP buffers** — max_recv/max_stream 1MB→2MB, TCP 64KB→128KB
- **8KB frame size** — smux frames 4KB→8KB
- **Auto-migrate** — old configs upgraded automatically

---

## What's New in v2.5

- **Multi-port load balancer** — Iran server listens on multiple ports simultaneously
- **DPI stealth mode** — random padding, burst split, fake traffic, keepalive jitter
- **120+ user support** — stream limit 512, max connections 500
- **Config auto-migration** — v2.4/v2.5 configs auto-upgraded
- **Random TLS fingerprint rotation** — Chrome/Firefox/Edge/Safari via utls
- **Port mapping fix** — smux stream tagging prevents misrouting

---

## Transport Modes

| Transport | Description | When to Use |
|---|---|---|
| `httpmux` | Plain HTTP with WebSocket upgrade + WS framing | Default for Iran — looks like browser traffic |
| `httpsmux` | TLS + HTTP WebSocket (utls fingerprint rotation) | Strongest — mimics HTTPS traffic |
| `tcpmux` | Plain TCP | Fast but detectable — for trusted networks |

---

## Step-by-Step Setup

### Step 1 — Iran Server

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
```

1. Select **`1) Install Server (Iran)`**
2. Select **`1) Automatic`** (recommended)
3. Enter tunnel port (default: `2020`)
4. Enter a PSK (pre-shared key) — must match Kharej
5. Select transport: `httpmux` recommended
6. Enter ports to forward (see format below)
7. Confirm system optimizations (BBR + TCP buffers)

### Step 2 — Kharej Server

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
```

1. Select **`2) Install Client (Kharej)`**
2. Select **`1) Automatic`**
3. Enter the same PSK
4. Select the same transport as Iran server
5. Enter Iran server `IP:Port` (example: `1.2.3.4:2020`)
6. Select connection pool size (default 4 is fine)

---

## Port Mapping Formats

| Input Format | Result |
|---|---|
| `8080` | Port 8080 → 8080 |
| `1000/2000` | Range 1000–2000 (same ports) |
| `5000=8080` | Port 5000 → 8080 |
| `1000/1010=2000/2010` | Range 1000–1010 → 2000–2010 |

---

## Configuration Files

```
/etc/picotun/server.yaml    ← Iran server config
/etc/picotun/client.yaml    ← Kharej client config
/usr/local/bin/picotun      ← Binary
```

### Iran Server Config Example

```yaml
config_version: 3
mode: "server"
listen: "0.0.0.0:2020"
listen_ports:
  - "0.0.0.0:2020"
  - "0.0.0.0:2021"
transport: "httpmux"
psk: "your-secret-key"
profile: "speed"

maps:
  - { type: tcp, bind: "443",  target: "127.0.0.1:443" }
  - { type: udp, bind: "1234", target: "127.0.0.1:1234" }

stealth:
  random_padding: true
  min_padding: 32
  max_padding: 256
  keepalive_jitter: 3
  conn_jitter_ms: 800
  burst_split: true
  fake_traffic: true
  fake_traffic_interval: 20
```

### Kharej Client Config Example

```yaml
config_version: 3
mode: "client"
psk: "your-secret-key"
transport: "httpmux"
profile: "speed"

paths:
  - transport: "httpmux"
    addr: "iran-ip:2020"
    connection_pool: 4

stealth:
  random_padding: true
  burst_split: true
```

---

## Performance Profiles

| Profile | Connection Pool | Keepalive | Best For |
|---|---|---|---|
| `speed` | 4 | 2s | Downloads, general use |
| `balanced` | 4 | 2s | Mixed usage |
| `gaming` | 6 | 1s | Low-latency games |
| `streaming` | 4 | 2s | Video / audio |
| `lowcpu` | 2 | 5s | Weak servers |

---

## Service Management

```bash
# Status
systemctl status picotun-server
systemctl status picotun-client

# Restart
systemctl restart picotun-server
systemctl restart picotun-client

# Live logs
journalctl -u picotun-server -f
journalctl -u picotun-client -f
```

---

## Update

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
# Then select: 5) Update PicoTun
```

---

## Uninstall

From the script menu select **`6) Uninstall PicoTun`**.  
This removes the binary, configs, systemd services, and kernel tuning.

---

## Troubleshooting

<details>
<summary>Connection not establishing</summary>

- Confirm PSK is identical on both servers
- Confirm transport is the same on both sides
- Open tunnel port in firewall: `ufw allow 2020/tcp`
- Check logs: `journalctl -u picotun-server -f`

</details>

<details>
<summary>IP getting blocked by DPI / daily blocks</summary>

Use `httpmux` or `httpsmux` transport and enable all stealth features:

```yaml
stealth:
  random_padding: true
  min_padding: 32
  max_padding: 256
  keepalive_jitter: 3
  conn_jitter_ms: 800
  burst_split: true
  fake_traffic: true
  fake_traffic_interval: 20
```

</details>

<details>
<summary>Speed drops with many users</summary>

Increase SMUX and TCP buffers:

```yaml
smux:
  max_recv: 2097152    # 2MB
  max_stream: 2097152
  frame_size: 8192     # 8KB
advanced:
  max_streams_per_session: 1024
  max_connections: 1000
  tcp_read_buffer: 131072    # 128KB
  tcp_write_buffer: 131072
```

</details>

<details>
<summary>Gaming micro-disconnects</summary>

```yaml
profile: "gaming"
smux:
  keepalive: 1
session_timeout: 60
```

</details>

<details>
<summary>Port mapping not working</summary>

Make sure the target service is running on the Kharej server and accessible locally.  
Check logs: `journalctl -u picotun-client -f`

</details>

---

## Version History

| Version | Highlights |
|---|---|
| v2.5.2 | RFC 6455 WS framing, proper Accept key, 18 domains, updated UA pool, stronger stealth defaults |
| v2.5.1 | Domain/UA rotation, header randomization, TCP fragmentation for httpmux, 2× buffers |
| v2.5.0 | Multi-port load balancer, DPI stealth mode, 120+ users, config auto-migration, TLS fingerprint rotation |
| v2.4.0 | Performance profiles, multi-IP failover, TLS fragmentation |

---

## Tech Stack

- **Go 1.22** — core tunnel
- **AES-256-GCM** — authenticated encryption
- **xtaci/smux** — multiplexing
- **refraction-networking/utls** — TLS fingerprint rotation
- **RFC 6455** — WebSocket framing (httpmux/httpsmux)
- **BBR** — TCP congestion control (applied on install)

---

## License

MIT — free for personal and commercial use.
