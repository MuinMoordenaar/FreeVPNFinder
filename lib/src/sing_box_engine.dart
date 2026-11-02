import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart' as mobile_sing_box;

import 'models.dart';
import 'sing_box_config.dart';
import 'storage.dart';

class ProbeResult {
  const ProbeResult(this.ok, this.latency, [this.error]);
  final bool ok;
  final int latency;
  final String? error;
}

class SingBoxEngine {
  SingBoxEngine(this.storage)
    : _android = Platform.isAndroid ? _AndroidSingBoxBridge(storage) : null;
  final LocalStorage storage;
  final _AndroidSingBoxBridge? _android;
  final configBuilder = SingBoxConfigBuilder();
  Process? _process;
  final _probeProcesses = <Process>{};
  int proxyPort = 2080;
  ConnectionMode? activeMode;

  bool get running => Platform.isAndroid ? _android!.running : _process != null;

  Future<String> get binaryPath async {
    final executableDir = File(Platform.resolvedExecutable).parent;
    final candidates = [
      '${executableDir.path}${Platform.pathSeparator}core${Platform.pathSeparator}sing-box.exe',
      '${Directory.current.path}${Platform.pathSeparator}core${Platform.pathSeparator}sing-box.exe',
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return path;
    }
    throw StateError('sing-box.exe is missing from the core folder');
  }

  Future<void> start(
    VpnNode node,
    ConnectionMode mode, {
    SplitTunnelSettings? splitTunneling,
  }) async {
    if (Platform.isAndroid) {
      final android = _android!;
      await android.start(node, mode, splitTunneling: splitTunneling);
      proxyPort = android.proxyPort;
      activeMode = mode;
      return;
    }
    await stop();
    proxyPort = await _findFreePort();
    final config = File(
      '${storage.root.path}${Platform.pathSeparator}active-config.json',
    );
    await config.writeAsString(
      jsonEncode(
        configBuilder.build(
          node,
          mode,
          proxyPort: proxyPort,
          splitTunneling: splitTunneling,
        ),
      ),
      flush: true,
    );
    final binary = await binaryPath;
    final checked = await Process.run(binary, [
      'check',
      '-c',
      config.path,
    ], runInShell: false);
    if (checked.exitCode != 0)
      throw StateError('Invalid sing-box config: ${checked.stderr}');
    final process = await Process.start(
      binary,
      ['run', '-c', config.path],
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    _process = process;
    final startupErrors = <String>[];
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((e) => storage.appendLog('core: $e'));
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((e) {
          startupErrors.add(e);
          storage.appendLog('core error: $e');
        });
    process.exitCode.then((_) {
      if (identical(_process, process)) _process = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (_process == null) {
      final detail = startupErrors.isEmpty ? '' : ': ${startupErrors.last}';
      throw StateError('sing-box stopped during startup$detail');
    }
    activeMode = mode;
    if (mode == ConnectionMode.systemProxy) {
      await _setSystemProxy(true, splitTunneling: splitTunneling);
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await _android!.stop();
      activeMode = null;
      return;
    }
    if (activeMode == ConnectionMode.systemProxy) await _setSystemProxy(false);
    activeMode = null;
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        process.kill();
      }
    }
    for (final probe in List<Process>.from(_probeProcesses)) {
      probe.kill(ProcessSignal.sigterm);
    }
    _probeProcesses.clear();
  }

  Future<void> cancelProbes() async {
    if (Platform.isAndroid) await _android!.cancelProbes();
  }

  Future<bool> nativeServiceRunning() => Platform.isAndroid
      ? _android!.isServiceRunning()
      : Future<bool>.value(running);

  Future<ProbeResult> checkActive({
    Duration timeout = const Duration(seconds: 8),
  }) => Platform.isAndroid
      ? _android!.checkActive(timeout)
      : _httpProbe(proxyPort, timeout);

  Future<ProbeResult> probe(
    VpnNode node, {
    int port = 0,
    Duration timeout = const Duration(seconds: 7),
  }) async {
    if (Platform.isAndroid) {
      return _android!.probe(node, timeout: timeout);
    }
    final probePort = port == 0 ? await _findFreePort() : port;
    final binary = await binaryPath;
    final config = File(
      '${storage.root.path}${Platform.pathSeparator}probe-${node.id}.json',
    );
    await config.writeAsString(
      jsonEncode(
        configBuilder.build(
          node,
          ConnectionMode.proxyOnly,
          proxyPort: probePort,
          testOnly: true,
        ),
      ),
      flush: true,
    );
    Process? process;
    try {
      final checked = await Process.run(binary, ['check', '-c', config.path]);
      if (checked.exitCode != 0)
        return ProbeResult(false, 0, '${checked.stderr}');
      process = await Process.start(binary, ['run', '-c', config.path]);
      _probeProcesses.add(process);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      return await _httpProbe(probePort, timeout);
    } catch (e) {
      return ProbeResult(false, 0, '$e');
    } finally {
      if (process != null) {
        _probeProcesses.remove(process);
        process.kill(ProcessSignal.sigterm);
        try {
          await process.exitCode.timeout(const Duration(seconds: 1));
        } catch (_) {
          process.kill();
        }
      }
      try {
        await config.delete();
      } catch (_) {}
    }
  }

  Future<List<({VpnNode node, ProbeResult result})>> probeBatch(
    List<VpnNode> nodes, {
    Duration timeout = const Duration(seconds: 7),
  }) async {
    if (Platform.isAndroid) {
      return _android!.probeBatch(nodes, timeout: timeout);
    }
    return [
      for (final node in nodes)
        (node: node, result: await probe(node, timeout: timeout)),
    ];
  }

  Future<bool> preflight(
    VpnNode node, {
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    if (node.protocol == 'hysteria2' || node.protocol == 'tuic') return true;
    Socket? socket;
    try {
      socket = await Socket.connect(node.host, node.port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      await socket?.close();
    }
  }

  Future<int> _findFreePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<ProbeResult> _httpProbe(int port, Duration timeout) async {
    final watch = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      final request = await client
          .getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
          .timeout(timeout);
      request.headers.set('User-Agent', 'FreeVPNFinder/1.0');
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      return ProbeResult(
        response.statusCode == 200,
        watch.elapsedMilliseconds,
        response.statusCode == 200 ? null : 'HTTP ${response.statusCode}',
      );
    } catch (e) {
      return ProbeResult(false, watch.elapsedMilliseconds, '$e');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _setSystemProxy(
    bool enabled, {
    SplitTunnelSettings? splitTunneling,
  }) async {
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    if (enabled) {
      await Process.run('reg.exe', [
        'add',
        key,
        '/v',
        'ProxyServer',
        '/t',
        'REG_SZ',
        '/d',
        '127.0.0.1:$proxyPort',
        '/f',
      ]);
      await Process.run('reg.exe', [
        'add',
        key,
        '/v',
        'ProxyOverride',
        '/t',
        'REG_SZ',
        '/d',
        buildSystemProxyOverride(splitTunneling),
        '/f',
      ]);
    }
    await Process.run('reg.exe', [
      'add',
      key,
      '/v',
      'ProxyEnable',
      '/t',
      'REG_DWORD',
      '/d',
      enabled ? '1' : '0',
      '/f',
    ]);
  }
}

/// Android uses sing-box's native libbox service instead of spawning the
/// Windows executable. The profile file and MMKV metadata are shared with the
/// native service through flutter_sing_box.
class _AndroidSingBoxBridge {
  _AndroidSingBoxBridge(this.storage);

  final LocalStorage storage;
  final configBuilder = SingBoxConfigBuilder();
  static const _platform = MethodChannel('free_vpn_finder/android');
  Future<void> _probeTail = Future<void>.value();
  bool running = false;
  int proxyPort = 2080;
  ConnectionMode? activeMode;

  Future<void> start(
    VpnNode node,
    ConnectionMode mode, {
    SplitTunnelSettings? splitTunneling,
  }) async {
    await stop();
    // Reserve the probe queue while starting the real service. The probe
    // service itself runs separately and never calls this method.
    final previousProbes = _probeTail;
    final startupGate = Completer<void>();
    _probeTail = startupGate.future;
    try {
      await previousProbes;
      await _startWithRetry(node, mode, splitTunneling: splitTunneling);
    } finally {
      startupGate.complete();
    }
  }

  Future<void> _startWithRetry(
    VpnNode node,
    ConnectionMode mode, {
    SplitTunnelSettings? splitTunneling,
  }) async {
    proxyPort = 2080;
    final config = configBuilder.build(
      node,
      mode,
      proxyPort: proxyPort,
      splitTunneling: splitTunneling,
    );
    await _writeProfile(node, config);
    await _configureNative(mode: mode, splitTunneling: splitTunneling);
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      await _stopNativeService();
      try {
        await _platform.invokeMethod<void>(
          mode == ConnectionMode.vpn ? 'startVpnService' : 'startNormalService',
        );
        running = true;
        activeMode = mode;
        if (await _waitForServiceStarted()) return;
        lastError = StateError('Android service stopped during startup');
      } on PlatformException catch (e) {
        lastError = e;
        if (e.code == 'VPN_PERMISSION_DENIED') rethrow;
      } catch (e) {
        lastError = e;
      }
      running = false;
      activeMode = null;
      await _stopNativeService();
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw lastError ?? StateError('Android service stopped during startup');
  }

  Future<bool> _waitForServiceStarted({bool probe = false}) async {
    return await _platform.invokeMethod<bool>('waitForServiceState', {
          'target': 'started',
          if (probe) 'service': 'probe',
        }) ??
        false;
  }

  Future<void> _waitForServiceStopped({bool probe = false}) async {
    try {
      await _platform.invokeMethod<bool>('waitForServiceState', {
        'target': 'stopped',
        if (probe) 'service': 'probe',
      });
    } catch (_) {
      // A service process that already died has no state event to emit.
    }
  }

  Future<void> _stopNativeService() async {
    try {
      await _platform.invokeMethod<void>('stopService');
    } catch (_) {
      // A service process that already died has no state to stop.
      return;
    }
    await _waitForServiceStopped();
  }

  Future<void> _stopProbeService() async {
    try {
      await _platform.invokeMethod<void>('stopProbeService');
    } catch (_) {
      return;
    }
    await _waitForServiceStopped(probe: true);
    // Android can report the service as stopped before the isolated process
    // has released libbox and its local listeners.
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> cancelProbes() async {
    try {
      await _platform.invokeMethod<void>('stopProbeService');
    } catch (_) {
      // The probe service may already be stopped.
    }
  }

  Future<void> stop() async {
    if (!running && activeMode == null) return;
    try {
      await _stopNativeService();
    } finally {
      running = false;
      activeMode = null;
    }
  }

  Future<bool> isServiceRunning() async {
    try {
      final status = await _platform.invokeMethod<int>('getServiceState');
      final serviceRunning = status == 1 || status == 2;
      running = serviceRunning;
      if (!serviceRunning) activeMode = null;
      return serviceRunning;
    } catch (_) {
      // Keep the local state if the activity is temporarily unavailable.
      return running;
    }
  }

  Future<ProbeResult> checkActive(Duration timeout) {
    // Verify the selected outbound through the local mixed inbound. This
    // avoids resolving the test hostname from Flutter through the Android TUN;
    // the TUN remains responsible for all other application traffic.
    return _httpProbe(proxyPort, timeout);
  }

  Future<ProbeResult> probe(
    VpnNode node, {
    Duration timeout = const Duration(seconds: 7),
  }) {
    final previous = _probeTail;
    final done = Completer<void>();
    _probeTail = done.future;
    return previous.then((_) async {
      try {
        return await _probeOne(node, timeout);
      } finally {
        done.complete();
      }
    });
  }

  Future<List<({VpnNode node, ProbeResult result})>> probeBatch(
    List<VpnNode> nodes, {
    Duration timeout = const Duration(seconds: 7),
  }) {
    final previous = _probeTail;
    final done = Completer<void>();
    _probeTail = done.future;
    return previous.then((_) async {
      try {
        final results = <({VpnNode node, ProbeResult result})>[];
        // A batch of Android inbounds is rejected by some libbox/device
        // combinations. Probe one node per isolated service so a shared
        // startup failure cannot make twelve nodes look instantly dead.
        for (final node in nodes) {
          results.add((node: node, result: await _probeOne(node, timeout)));
        }
        return results;
      } finally {
        done.complete();
      }
    });
  }

  int _probePortSequence = 0;

  int _nextProbeBasePort() {
    // A stopped isolated Android service can release listeners a little after
    // its stopped callback. Rotating the batch ports prevents that stale
    // process from poisoning the next probe batch.
    final base = 22000 + (_probePortSequence++ % 1800) * 16;
    return base;
  }

  Future<ProbeResult> _probeOne(VpnNode node, Duration timeout) async {
    final probePort = _nextProbeBasePort();
    final config = configBuilder.build(
      node,
      ConnectionMode.proxyOnly,
      proxyPort: probePort,
      testOnly: true,
    );
    final configFile = File(
      '${storage.root.path}${Platform.pathSeparator}probe-android-$probePort.json',
    );
    await configFile.writeAsString(jsonEncode(config), flush: true);
    await _configureNative(mode: ConnectionMode.proxyOnly, probe: true);
    await _stopProbeService();
    try {
      await _platform.invokeMethod<void>('startProbeService', {
        'configPath': configFile.path,
      });
      if (!await _waitForServiceStarted(probe: true)) {
        return const ProbeResult(
          false,
          0,
          'Android service stopped during startup',
        );
      }
      return await _httpProbe(probePort, timeout);
    } catch (e) {
      return ProbeResult(false, 0, '$e');
    } finally {
      await _stopProbeService();
      try {
        await configFile.delete();
      } catch (_) {}
    }
  }

  Future<void> _configureNative({
    required ConnectionMode mode,
    SplitTunnelSettings? splitTunneling,
    bool probe = false,
  }) async {
    final applications =
        splitTunneling?.applications
            .where((app) => app.enabled && app.isAndroidPackage)
            .map((app) => app.path.trim())
            .where((path) => path.isNotEmpty)
            .toList() ??
        const <String>[];
    final perAppMode =
        mode != ConnectionMode.vpn ||
            splitTunneling?.enabled != true ||
            applications.isEmpty
        ? 'disabled'
        : splitTunneling!.mode == SplitTunnelMode.bypass
        ? 'bypass'
        : 'vpnOnly';
    await _platform.invokeMethod<void>('configureAndroidService', {
      'serviceMode': probe
          ? 'probe'
          : mode == ConnectionMode.vpn
          ? 'vpn'
          : 'normal',
      'perAppMode': perAppMode,
      'packages': applications,
    });
  }

  Future<void> _writeProfile(VpnNode node, Map<String, dynamic> config) async {
    final profiles = mobile_sing_box.ProfileStorage();
    final selected = profiles.getSelectedProfile();
    final id = selected?.id ?? profiles.generateProfileId;
    final profilePath =
        selected?.typed.path ?? await profiles.getProfilePath(id);
    final profileFile = File(profilePath);
    await profileFile.parent.create(recursive: true);
    final encoded = jsonEncode(config);
    await profileFile.writeAsString(encoded, flush: true);

    final profile = mobile_sing_box.Profile(
      id: id,
      order: 0,
      name: node.name,
      outboundsCount: 1,
      typed: mobile_sing_box.TypedProfile(
        type: mobile_sing_box.ProfileType.local,
        path: profilePath,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    mobile_sing_box.ProfileStorage.storage.setString(
      'profile_$id',
      jsonEncode(profile.toJson()),
    );
    profiles.setSelectedProfile(id);

    final storageDirectory = await profiles.getStorageDirectory();
    await storageDirectory.create(recursive: true);
    profiles.setUsingConfig(storageDirectory.path);
    final usingConfig = await profiles.getUsingConfig();
    await usingConfig.writeAsString(encoded, flush: true);
  }

  Future<ProbeResult> _httpProbe(int? port, Duration timeout) async {
    final watch = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    if (port != null) client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      final request = await client
          .getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
          .timeout(timeout);
      request.headers.set('User-Agent', 'FreeVPNFinder/1.5.4 Android');
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      return ProbeResult(
        response.statusCode == 200,
        watch.elapsedMilliseconds,
        response.statusCode == 200 ? null : 'HTTP ${response.statusCode}',
      );
    } catch (e) {
      return ProbeResult(false, watch.elapsedMilliseconds, '$e');
    } finally {
      client.close(force: true);
    }
  }
}

String buildSystemProxyOverride(SplitTunnelSettings? split) {
  final overrides = <String>['<local>'];
  if (split?.enabled == true && split?.mode == SplitTunnelMode.bypass) {
    for (final value in split!.domains) {
      final domain = _normalizeSystemProxyDomain(value);
      if (domain.isEmpty) continue;
      overrides
        ..add(domain)
        ..add('*.$domain');
    }
  }
  return overrides.join(';');
}

String _normalizeSystemProxyDomain(String value) {
  var domain = value.trim().toLowerCase();
  if (domain.startsWith('*.')) domain = domain.substring(2);
  if (domain.startsWith('https://')) domain = domain.substring(8);
  if (domain.startsWith('http://')) domain = domain.substring(7);
  domain = domain.split('/').first.split(':').first;
  return domain.endsWith('.') ? domain.substring(0, domain.length - 1) : domain;
}
