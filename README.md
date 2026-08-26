# Free VPN Finder

Windows 10/11 MVP built with Flutter and sing-box. The app downloads public share-link subscriptions, normalizes and deduplicates nodes, verifies them through real HTTP-over-proxy requests, keeps ten warm backups, gradually refreshes them in the background, and switches after hard failures or sustained poor quality.

## Features

- VPN (TUN), System Proxy, and Proxy Only modes
- Split tunneling with Bypass VPN and Use VPN only modes for Windows applications, folders and domains
- VLESS/Reality, VMess, Trojan, Shadowsocks, Hysteria2, and TUIC share links
- Per-protocol enable/disable controls in Settings; at least one protocol always remains available
- Three built-in sources plus custom URI and subscription import
- offline source cache and JSON state in `%AppData%`
- sequential first-working-node discovery and ten-node backup pool with low-impact background refresh (3 seconds by default)
- hard failover and latency failover to the lowest-ping backup with replacement margin/cooldown
- Portable Windows ZIP package with all runtime files and a desktop shortcut
- Manual update check opens the latest portable ZIP download; no installer or auto-update
- tray, settings, activity log, and polished dark UI

## Build

Flutter 3.47.1 and Visual Studio 2022 with Desktop C++ are recommended.

```powershell
flutter pub get
flutter test
flutter build windows --release
```

The release executable expects `core/sing-box.exe`; the CMake build copies it automatically. Run the app as administrator for VPN/TUN mode. System Proxy and Proxy Only do not require elevation.

Public nodes are untrusted third-party infrastructure. Do not use them for banking, secrets, or other sensitive traffic.
