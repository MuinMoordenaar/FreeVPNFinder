# Free VPN Finder

Windows 10/11 MVP built with Flutter and sing-box. The app downloads public share-link subscriptions, normalizes and deduplicates nodes, verifies them through real HTTP-over-proxy requests, keeps five warm backups, and switches after hard failures or sustained poor quality.

## Features

- VPN (TUN), System Proxy, and Proxy Only modes
- VLESS/Reality, VMess, Trojan, Shadowsocks, Hysteria2, and TUIC share links
- Three built-in sources plus custom URI and subscription import
- offline source cache and JSON state in `%AppData%`
- sequential first-working-node discovery and five-node backup pool
- hard failover and latency failover with hysteresis/cooldown
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
