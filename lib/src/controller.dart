import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'models.dart';
import 'node_parser.dart';
import 'reconnect_policy.dart';
import 'sing_box_engine.dart';
import 'sources.dart';
import 'storage.dart';

class _ConnectionCancelled implements Exception {
  const _ConnectionCancelled();
}

class AppController extends ChangeNotifier with TrayListener, WindowListener {
  static const _backupReplacementMarginMs = 0;
  static const _backgroundProbeConcurrency = 4;
  static const _androidProbeConcurrency = 4;
  static const _androidSearchWindow = Duration(minutes: 5);
  final storage = LocalStorage();
  late final SourceRepository repository;
  late final SingBoxEngine engine;
  AppSettings settings = AppSettings();
  List<VpnSource> sources = [];
  List<VpnNode> nodes = [], backups = [];
  VpnNode? activeNode;
  VpnNode? _preferredNode;
  AppPhase phase = AppPhase.disconnected;
  String status = 'Ready';
  String? error;
  final logs = <String>[];
  int tested = 0;
  Timer? _healthTimer;
  Timer? _backgroundTimer;
  Timer? _nodesSaveTimer;
  Timer? _androidSearchTimer;
  Timer? _androidServiceTimer;
  Timer? _notifyTimer;
  DateTime? _androidSearchUntil;
  String _androidSearchProgress = '';
  DateTime? _lastFailover;
  int _qualityFailures = 0;
  bool _connectionCancelRequested = false;
  bool _searchCancelRequested = false;
  bool _operationInFlight = false;
  bool _shuttingDown = false;
  bool _backupRefreshRunning = false;
  bool _androidInitialPoolReady = false;
  bool _androidManualSearchRunning = false;
  bool _androidSearchPreserveConnection = false;
  bool _serviceStateSyncRunning = false;
  int _backgroundScanIndex = 0;
  final _backgroundGroupHistory = <String>[];

  bool get connected =>
      phase == AppPhase.connected || phase == AppPhase.degraded;

  bool get androidSearchActive =>
      Platform.isAndroid &&
      _androidSearchUntil != null &&
      _androidSearchUntil!.isAfter(DateTime.now());

  bool get androidSearchRunning =>
      Platform.isAndroid && _androidManualSearchRunning;

  bool get _androidDiscoveryPreservesConnection =>
      Platform.isAndroid && _androidSearchPreserveConnection;

  bool get connectionBusy =>
      _operationInFlight ||
      {
        AppPhase.connecting,
        AppPhase.verifying,
        AppPhase.switching,
        AppPhase.disconnecting,
        AppPhase.updatingSources,
      }.contains(phase);

  Duration get androidSearchRemaining {
    final until = _androidSearchUntil;
    if (!androidSearchActive || until == null) return Duration.zero;
    return until.difference(DateTime.now());
  }

  String get androidSearchCountdown {
    final remaining = androidSearchRemaining;
    final totalSeconds = remaining.inSeconds.clamp(0, 5 * 60);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String get androidSearchProgress {
    if (_androidSearchProgress.startsWith('Testing cached servers')) {
      return 'Testing cached servers… ${backups.length}/${settings.backupPoolSize} backup nodes';
    }
    if (_androidSearchProgress.startsWith('Finding new servers')) {
      return 'Finding new servers… ${backups.length}/${settings.backupPoolSize} backup nodes';
    }
    return _androidSearchProgress;
  }

  Future<void> initialize() async {
    await storage.initialize();
    repository = SourceRepository(storage);
    engine = SingBoxEngine(storage);
    settings = await storage.loadSettings();
    nodes = (await storage.loadNodes()).where(_supported).toList();
    final savedPool = await storage.loadConnectionPool();
    final nodesByFingerprint = {
      for (final node in nodes) node.fingerprint: node,
    };
    _preferredNode = nodesByFingerprint[savedPool.active];
    backups = [
      for (final fingerprint in savedPool.backups)
        if (nodesByFingerprint[fingerprint] case final node?)
          if (!Platform.isAndroid ||
              (node.latency != null && node.lastSuccessAt != null))
            node..state = NodeState.standby,
    ];
    _sortAndTrimBackups();
    _androidInitialPoolReady =
        Platform.isAndroid && backups.length >= settings.backupPoolSize;
    sources = await storage.loadSources() ?? SourceRepository.defaults.toList();
    if (Platform.isWindows) {
      trayManager.addListener(this);
      windowManager.addListener(this);
      await _setupTray();
    }
    _log(
      'Application initialized with ${nodes.length} cached nodes and ${backups.length} saved backups',
    );
    _startBackgroundDiscovery();
  }

  /// The Android notification can stop the native service while the Flutter
  /// activity is in the background. Reconcile that external action before a
  /// health check or when the activity becomes visible again.
  Future<bool> syncAndroidServiceState() async {
    if (!Platform.isAndroid || _shuttingDown) return connected;
    // Only a connected state is eligible for external-stop reconciliation.
    // During connect/switch/disconnect the native service is expected to be
    // briefly stopped while the controller owns that transition.
    if (!connected) return false;
    if (_serviceStateSyncRunning) return connected;
    _serviceStateSyncRunning = true;
    try {
      final nativeRunning = await engine.nativeServiceRunning();
      if (nativeRunning) return true;

      _healthTimer?.cancel();
      _androidServiceTimer?.cancel();
      _androidServiceTimer = null;
      _qualityFailures = 0;
      final node = activeNode;
      if (node != null) {
        node.state = NodeState.standby;
        if (!backups.any((backup) => backup.fingerprint == node.fingerprint)) {
          backups.add(node);
        }
        _sortAndTrimBackups();
      }
      activeNode = null;
      if (phase != AppPhase.disconnected) {
        _setPhase(AppPhase.disconnected, 'Ready');
      }
      await _persistPool();
      return false;
    } finally {
      _serviceStateSyncRunning = false;
    }
  }

  Future<void> _setupTray() async {
    if (!Platform.isWindows) return;
    try {
      final packagedIcon = File(
        '${File(Platform.resolvedExecutable).parent.path}'
        '${Platform.pathSeparator}app_icon.ico',
      );
      await trayManager.setIcon(
        await packagedIcon.exists()
            ? packagedIcon.path
            : 'windows/runner/resources/app_icon.ico',
      );
      await trayManager.setToolTip('Free VPN Finder');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Open Free VPN Finder'),
            MenuItem(
              key: 'toggle',
              label: connected ? 'Disconnect' : 'Connect',
            ),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: 'Exit'),
          ],
        ),
      );
    } catch (e) {
      _log('Tray unavailable: $e');
    }
  }

  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    if (item.key == 'show') onTrayIconMouseDown();
    if (item.key == 'toggle') await toggleConnection();
    if (item.key == 'exit') await shutdown();
  }

  @override
  void onWindowClose() async {
    await shutdown();
  }

  void _setPhase(AppPhase value, String message) {
    phase = value;
    status = message;
    error = null;
    notifyListeners();
  }

  void _log(String message) {
    logs.insert(
      0,
      '${DateTime.now().toIso8601String().substring(11, 19)}  $message',
    );
    if (logs.length > 300) logs.removeLast();
    storage.appendLog(message);
    _scheduleNotify();
  }

  void _scheduleNotify() {
    if (_notifyTimer != null || _shuttingDown) return;
    _notifyTimer = Timer(const Duration(milliseconds: 80), () {
      _notifyTimer = null;
      if (!_shuttingDown) notifyListeners();
    });
  }

  Future<void> toggleConnection() async {
    if (_shuttingDown) return;
    if (_operationInFlight) {
      // The connect button remains tappable while connecting. A second tap
      // cancels the in-flight activation instead of being ignored.
      _connectionCancelRequested = true;
      unawaited(engine.cancelProbes());
      notifyListeners();
      return;
    }
    if (Platform.isAndroid && !connected && backups.isEmpty) {
      // A search owns the empty-pool state while it verifies candidates. A
      // stray tap on Connect must not start a second, fake connection flow.
      if (androidSearchActive || _androidManualSearchRunning) return;
      _fail('No backup nodes. Tap Find New Servers to search.');
      return;
    }
    _operationInFlight = true;
    try {
      if (phase == AppPhase.disconnected || phase == AppPhase.error) {
        await connect();
      } else {
        await disconnect();
      }
    } finally {
      _operationInFlight = false;
    }
  }

  Future<void> connect() async {
    _connectionCancelRequested = false;
    tested = 0;
    try {
      if (Platform.isAndroid) {
        await _connectFromAndroidBackups();
        return;
      }
      _setPhase(AppPhase.searching, 'Checking your recent servers…');
      final attempted = <String>{};
      final recent = [
        ...recentConnectionCandidates(_preferredNode, backups),
        ...nodes.where(_userProvidedNode),
      ];
      final cachedWinner = await _findFirstWorking(recent, attempted);
      if (cachedWinner != null) {
        await _activate(cachedWinner);
        unawaited(_fillBackups(exclude: cachedWinner));
        return;
      }

      _preferredNode = null;
      backups.removeWhere((node) => attempted.contains(node.fingerprint));
      await _persistPool();
      await refreshSources();
      if (_connectionCancelRequested) return;
      _setPhase(AppPhase.searching, 'Searching for a working server…');
      final candidates = nodes.where(_eligible);
      final winner = await _findFirstWorking(candidates.take(80), attempted);
      if (winner != null) {
        await _activate(winner);
        unawaited(_fillBackups(exclude: winner));
        return;
      }
      throw StateError('No working servers found');
    } on _ConnectionCancelled {
      if (!_shuttingDown && !connected)
        _setPhase(AppPhase.disconnected, 'Ready');
    } catch (e) {
      _fail('$e');
    } finally {
      await storage.saveNodes(nodes);
      await _setupTray();
    }
  }

  Future<void> _connectFromAndroidBackups() async {
    if (backups.isEmpty) {
      _fail('No backup nodes. Tap Find New Servers to search.');
      return;
    }

    final candidates = List<VpnNode>.from(backups)..sort(latencyOrder);
    for (var index = 0; index < candidates.length; index++) {
      if (_connectionCancelRequested) return;
      final node = candidates[index];
      if (!backups.any((backup) => backup.fingerprint == node.fingerprint)) {
        continue;
      }
      _setPhase(
        AppPhase.searching,
        'Connecting to backup ${index + 1}/${candidates.length}…',
      );
      final previousFailureAt = node.lastFailureAt;
      try {
        await _activate(node);
        return;
      } on _ConnectionCancelled {
        if (!connected && phase != AppPhase.disconnected) {
          _setPhase(AppPhase.disconnected, 'Ready');
        }
        return;
      } catch (e) {
        // _activate records verification failures itself. Record startup
        // failures here as well so the failed backup is not retried forever.
        if (identical(node.lastFailureAt, previousFailureAt)) {
          node.recordFailure();
        }
        backups.removeWhere((backup) => backup.fingerprint == node.fingerprint);
        await _persistPool();
        _log('Backup failed: ${node.name}: $e');
      }
    }
    throw StateError(
      'No working backup nodes. Tap Find New Servers to search.',
    );
  }

  Future<VpnNode?> _findFirstWorking(
    Iterable<VpnNode> candidates,
    Set<String> attempted,
  ) async {
    for (final node in candidates) {
      if (_connectionCancelRequested) return null;
      if (!_eligible(node)) continue;
      if (!attempted.add(node.fingerprint)) continue;
      tested++;
      node.state = NodeState.checking;
      notifyListeners();
      final result = await engine.probe(node, port: 21800 + tested % 100);
      if (result.ok) {
        node.recordSuccess(result.latency);
        _log('${node.name} passed in ${result.latency} ms');
        return node;
      }
      node.recordFailure();
      _log('${node.name} failed: ${result.error ?? 'unreachable'}');
    }
    return null;
  }

  bool _supported(VpnNode n) => VpnProtocol.isKnown(n.protocol);

  bool _userProvidedNode(VpnNode n) =>
      n.sourceId == 'custom' || n.sourceId.startsWith('custom-');

  bool _enabled(VpnNode n) =>
      _supported(n) && settings.isProtocolEnabled(n.protocol);

  bool _eligible(VpnNode n) =>
      _enabled(n) &&
      (n.state != NodeState.cooldown ||
          n.lastFailureAt == null ||
          DateTime.now().difference(n.lastFailureAt!).inHours >= 1);

  bool _isAndroidProbeInfrastructureFailure(String error) {
    final value = error.toLowerCase();
    return value.contains('probe_start_failed') ||
        value.contains('probe_stop_failed') ||
        value.contains('android probe service') ||
        value.contains('android service stopped') ||
        value.contains('startcommandserver') ||
        value.contains('127.0.0.1') ||
        value.contains('connection refused') ||
        value.contains('timed out while starting') ||
        value.contains('socketexception');
  }

  Future<void> refreshSources({
    bool preservePhase = false,
    bool forSearch = false,
    bool customOnly = false,
  }) async {
    final previousPhase = phase;
    final previousStatus = status;
    if (preservePhase) {
      // Discovery must not replace the visible connection state.
      if (!forSearch && !connected) {
        status = 'Updating server sources…';
        notifyListeners();
      }
    } else {
      _setPhase(AppPhase.updatingSources, 'Updating server sources…');
    }
    try {
      final fresh = <VpnNode>[];
      for (final source in sources.where(
        (source) => source.enabled && (!customOnly || source.custom),
      )) {
        if (forSearch ? _searchCancelRequested : _connectionCancelRequested) {
          return;
        }
        final result = await repository.fetch(source);
        fresh.addAll(result);
        _log('${source.name}: ${result.length} configurations');
      }
      if (fresh.isNotEmpty) {
        final history = nodes;
        nodes = await Isolate.run(
          () => SourceRepository.mergeNodes(fresh, history),
        );
        _resetBackgroundScan();
      }
      await storage.saveNodes(nodes);
      _log('${nodes.length} unique nodes available');
    } finally {
      if (preservePhase) {
        phase = previousPhase;
        status = previousStatus;
        error = null;
        notifyListeners();
      }
    }
  }

  Future<void> _activate(VpnNode node) async {
    final previous = activeNode;
    if (_connectionCancelRequested) throw const _ConnectionCancelled();
    _setPhase(AppPhase.connecting, 'Connecting to ${node.name}…');
    await engine.start(
      node,
      settings.mode,
      splitTunneling: settings.splitTunneling,
    );
    if (_connectionCancelRequested) {
      await engine.stop();
      throw const _ConnectionCancelled();
    }
    _setPhase(AppPhase.verifying, 'Verifying connection…');
    var result = await engine.checkActive(timeout: const Duration(seconds: 5));
    if (_connectionCancelRequested) {
      await engine.stop();
      throw const _ConnectionCancelled();
    }
    for (var attempt = 1; !result.ok && attempt < 3; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_connectionCancelRequested) {
        await engine.stop();
        throw const _ConnectionCancelled();
      }
      result = await engine.checkActive(timeout: const Duration(seconds: 5));
    }
    if (_connectionCancelRequested) {
      await engine.stop();
      throw const _ConnectionCancelled();
    }
    if (!result.ok) {
      await engine.stop();
      node.recordFailure();
      throw StateError(
        'Connection verification failed: ${result.error ?? 'network unavailable'}',
      );
    }
    if (previous != null &&
        previous.fingerprint != node.fingerprint &&
        previous.consecutiveFailures == 0 &&
        !backups.any((backup) => backup.fingerprint == previous.fingerprint)) {
      previous.state = NodeState.standby;
      backups.add(previous);
    }
    backups.removeWhere((backup) => backup.fingerprint == node.fingerprint);
    _sortAndTrimBackups();
    activeNode = node..state = NodeState.active;
    _preferredNode = node;
    node.recordSuccess(result.latency);
    node.state = NodeState.active;
    _setPhase(AppPhase.connected, 'Connected');
    _log(
      'Connected to ${node.name} (${result.latency} ms) using ${settings.mode.label}',
    );
    _startHealthMonitor();
    await _persistPool();
  }

  Future<void> _fillBackups({
    VpnNode? exclude,
    bool autoConnectFirstFound = false,
    bool preserveActiveConnection = false,
  }) async {
    if (_backupRefreshRunning) return;
    _backupRefreshRunning = true;
    backups = backups
        .where((n) => n.fingerprint != exclude?.fingerprint)
        .toList();
    try {
      if (Platform.isAndroid) {
        final reserved = <String>{};
        var tryFirstWorking =
            !preserveActiveConnection &&
            autoConnectFirstFound &&
            !connected &&
            activeNode == null &&
            backups.isEmpty;
        while (!_shuttingDown &&
            !_searchCancelRequested &&
            androidSearchActive) {
          if (backups.length >= settings.backupPoolSize && !tryFirstWorking) {
            _androidInitialPoolReady = true;
          }
          if (reserved.isNotEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            if (_shuttingDown ||
                _searchCancelRequested ||
                !androidSearchActive) {
              break;
            }
          }

          final candidates = <VpnNode>[];
          final candidateCount = _androidProbeConcurrency;
          for (var i = 0; i < candidateCount; i++) {
            final node = _nextBackgroundCandidate(
              exclude: exclude,
              reserved: reserved,
              ignoreRecent: true,
            );
            if (node == null) break;
            reserved.add(node.fingerprint);
            candidates.add(node);
          }
          if (candidates.isEmpty) break;

          final searchStatus = tryFirstWorking
              ? 'Testing server connection…'
              : 'Testing cached servers…';
          _androidSearchProgress = searchStatus;
          notifyListeners();
          final results = await engine.probeBatch(candidates);
          final working = <({VpnNode node, int latency})>[];
          final infrastructureFailed =
              results.isNotEmpty &&
              results.every(
                (entry) =>
                    !entry.result.ok &&
                    _isAndroidProbeInfrastructureFailure(
                      entry.result.error ?? '',
                    ),
              );
          for (final entry in results) {
            final node = entry.node;
            final result = entry.result;
            if (!result.ok) {
              if (!infrastructureFailed) node.recordFailure();
              continue;
            }
            node.recordSuccess(result.latency);
            working.add((node: node, latency: result.latency));
          }
          for (final entry in working) {
            final node = entry.node;
            node.state = NodeState.standby;
            if (backups.length < settings.backupPoolSize) {
              backups.add(node);
              _log(
                'Verified Android backup ${backups.length}/${settings.backupPoolSize}: '
                '${node.name} (${entry.latency} ms)',
              );
            } else {
              final slowest = backups.reduce(
                (a, b) => latencyOrder(a, b) >= 0 ? a : b,
              );
              if (entry.latency + _backupReplacementMarginMs <
                  (slowest.latency ?? 1 << 30)) {
                slowest.state = NodeState.working;
                backups
                  ..remove(slowest)
                  ..add(node);
                _log(
                  'Verified Android backup replaced: ${slowest.name} → '
                  '${node.name} (${entry.latency} ms)',
                );
              } else {
                node.state = NodeState.working;
              }
            }
          }
          if (infrastructureFailed) {
            _log('Android node checker unavailable; no backup queued');
          }
          if (!preserveActiveConnection &&
              tryFirstWorking &&
              !connected &&
              activeNode == null &&
              working.isNotEmpty) {
            working.sort((a, b) => a.latency.compareTo(b.latency));
            for (final entry in working) {
              if (_connectionCancelRequested || _shuttingDown) break;
              final node = entry.node;
              if (!backups.any(
                (backup) => backup.fingerprint == node.fingerprint,
              )) {
                continue;
              }
              try {
                await _activate(node);
                tryFirstWorking = false;
                break;
              } on _ConnectionCancelled {
                break;
              } catch (e) {
                backups.removeWhere(
                  (backup) => backup.fingerprint == node.fingerprint,
                );
                _log('Verified candidate failed to connect: ${node.name}: $e');
              }
            }
            if (!connected &&
                !_shuttingDown &&
                phase != AppPhase.disconnected &&
                phase != AppPhase.error) {
              _setPhase(AppPhase.disconnected, 'Ready');
            }
          }
          _sortAndTrimBackups();
          if (backups.length >= settings.backupPoolSize) {
            _androidInitialPoolReady = true;
          }
          final searchProgress = 'Finding new servers…';
          _androidSearchProgress = searchProgress;
          await _persistPool();
          notifyListeners();
          _scheduleNodesSave();
        }
        await _persistPool();
        notifyListeners();
        _scheduleNodesSave();
        return;
      }
      final reserved = <String>{};
      final candidates = <VpnNode>[];
      for (var i = 0; i < _backgroundProbeConcurrency; i++) {
        final node = _nextBackgroundCandidate(
          exclude: exclude,
          reserved: reserved,
        );
        if (node == null) break;
        candidates.add(node);
        reserved.add(node.fingerprint);
      }
      if (candidates.isEmpty || _shuttingDown) return;
      await Future<void>.delayed(
        Duration(seconds: settings.backupProbeIntervalSeconds),
      );
      if (_shuttingDown) return;

      final results = await Future.wait(
        candidates.map(_probeBackgroundCandidate),
      );
      for (final entry in results) {
        final node = entry.node;
        final result = entry.result;
        if (!result.ok) {
          node.recordFailure();
          _log('Backup candidate failed: ${node.name}');
          continue;
        }
        node.recordSuccess(result.latency);
        node.state = NodeState.standby;
        if (backups.length < settings.backupPoolSize) {
          backups.add(node);
          _log(
            'Backup ${backups.length}/${settings.backupPoolSize} ready: '
            '${node.name} (${result.latency} ms)',
          );
        } else {
          final slowest = backups.reduce(
            (a, b) => latencyOrder(a, b) >= 0 ? a : b,
          );
          if (result.latency + _backupReplacementMarginMs <
              (slowest.latency ?? 1 << 30)) {
            slowest.state = NodeState.working;
            backups
              ..remove(slowest)
              ..add(node);
            _log(
              'Backup replaced: ${slowest.name} → ${node.name} '
              '(${result.latency} ms)',
            );
          }
        }
      }
      _sortAndTrimBackups();
      await _persistPool();
      notifyListeners();
      _scheduleNodesSave();
    } finally {
      _backupRefreshRunning = false;
    }
    await _persistPool();
  }

  Future<({VpnNode node, ProbeResult result})> _probeBackgroundCandidate(
    VpnNode node,
  ) async {
    _log('Background check: ${node.name} (${node.protocol})');
    try {
      final result = await engine
          .probe(node, port: 0, timeout: const Duration(seconds: 3))
          .timeout(const Duration(seconds: 5));
      return (node: node, result: result);
    } catch (e) {
      return (node: node, result: ProbeResult(false, 0, '$e'));
    }
  }

  void _scheduleNodesSave() {
    if (_nodesSaveTimer != null || _shuttingDown) return;
    _nodesSaveTimer = Timer(const Duration(seconds: 15), () {
      _nodesSaveTimer = null;
      unawaited(storage.saveNodes(nodes));
    });
  }

  VpnNode? _nextBackgroundCandidate({
    VpnNode? exclude,
    Set<String> reserved = const {},
    bool ignoreRecent = false,
  }) {
    if (nodes.isEmpty) return null;
    VpnNode? fallback;
    String? fallbackGroup;
    final limit = ignoreRecent || nodes.length < 256 ? nodes.length : 256;
    for (var offset = 0; offset < limit; offset++) {
      final index = (_backgroundScanIndex + offset) % nodes.length;
      final node = nodes[index];
      if (node.fingerprint == exclude?.fingerprint ||
          node.fingerprint == activeNode?.fingerprint ||
          reserved.contains(node.fingerprint) ||
          backups.any((backup) => backup.fingerprint == node.fingerprint) ||
          !_enabled(node) ||
          (!ignoreRecent && !_backgroundEligible(node))) {
        continue;
      }
      final group = '${node.sourceId}:${node.protocol}';
      final nodePriority = _backgroundPriority(node);
      final fallbackNode = fallback;
      final fallbackPriority = fallbackNode == null
          ? 1 << 30
          : _backgroundPriority(fallbackNode);
      final preferred =
          fallbackNode == null ||
          nodePriority < fallbackPriority ||
          (nodePriority == fallbackPriority &&
              (node.latency ?? 1 << 30) < (fallbackNode.latency ?? 1 << 30));
      if (preferred) {
        fallback = node;
        fallbackGroup = group;
      }
      if (!_backgroundGroupHistory.contains(group)) {
        _backgroundScanIndex = (index + 1) % nodes.length;
        _backgroundGroupHistory.add(group);
        if (_backgroundGroupHistory.length > 16) {
          _backgroundGroupHistory.removeAt(0);
        }
        return node;
      }
    }
    if (fallback != null) {
      final index = nodes.indexOf(fallback);
      _backgroundScanIndex = (index + 1) % nodes.length;
      if (fallbackGroup != null &&
          !_backgroundGroupHistory.contains(fallbackGroup)) {
        _backgroundGroupHistory.add(fallbackGroup);
      }
    }
    return fallback;
  }

  void _resetBackgroundScan() {
    _backgroundScanIndex = 0;
    _backgroundGroupHistory.clear();
  }

  Future<void> startAndroidServerSearch() async {
    if (!Platform.isAndroid ||
        _shuttingDown ||
        androidSearchActive ||
        _androidManualSearchRunning) {
      return;
    }
    _searchCancelRequested = false;
    _androidManualSearchRunning = true;
    final searchStartedWithActiveConnection = connected || activeNode != null;
    _androidSearchPreserveConnection = searchStartedWithActiveConnection;
    _androidSearchProgress = 'Updating server sources…';
    _androidSearchUntil = DateTime.now().add(_androidSearchWindow);
    _androidSearchTimer?.cancel();
    _androidSearchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!androidSearchActive) {
        _androidSearchTimer?.cancel();
        _androidSearchTimer = null;
        _androidSearchUntil = null;
      }
      notifyListeners();
    });
    _log('Manual server search started: 5-minute search window');
    notifyListeners();
    try {
      while (_backupRefreshRunning && !_shuttingDown) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      if (_shuttingDown) return;
      if (!_searchCancelRequested) {
        // Refresh only from the explicit Find New Servers action. Connect
        // remains backup-only and never performs this network operation.
        await refreshSources(preservePhase: true, forSearch: true);
        if (_shuttingDown || _searchCancelRequested) return;
        // Source refresh is preparation, not part of the five-minute search
        // window, so the user gets the full advertised probing period.
        _androidSearchUntil = DateTime.now().add(_androidSearchWindow);
        notifyListeners();
        await _fillBackups(
          exclude: activeNode,
          autoConnectFirstFound: !searchStartedWithActiveConnection &&
              !connected &&
              activeNode == null &&
              backups.isEmpty,
          preserveActiveConnection: searchStartedWithActiveConnection,
        );
      }
    } finally {
      _androidManualSearchRunning = false;
      if (!androidSearchActive) {
        _androidSearchTimer?.cancel();
        _androidSearchTimer = null;
        _androidSearchUntil = null;
        _androidSearchProgress = '';
        notifyListeners();
      }
      if (!connected &&
          (phase == AppPhase.disconnected || phase == AppPhase.error) &&
          !_shuttingDown) {
        _setPhase(AppPhase.disconnected, 'Ready');
      }
      _androidSearchPreserveConnection = false;
    }
  }

  void _startBackgroundDiscovery() {
    if (Platform.isAndroid) return;
    _backgroundTimer?.cancel();
    _backgroundTimer = Timer.periodic(
      Duration(seconds: settings.backupProbeIntervalSeconds),
      (_) => unawaited(_fillBackups(exclude: activeNode)),
    );
    unawaited(_fillBackups(exclude: activeNode));
  }

  bool _backgroundEligible(VpnNode node) {
    if (!_eligible(node)) return false;
    final checkedAt = node.lastCheckedAt;
    return checkedAt == null ||
        DateTime.now().difference(checkedAt) >= const Duration(minutes: 5);
  }

  int _backgroundPriority(VpnNode node) {
    if (node.lastCheckedAt == null) return 0;
    if (node.consecutiveFailures > 0) return 2;
    return 1;
  }

  void _startHealthMonitor() {
    _healthTimer?.cancel();
    _androidServiceTimer?.cancel();
    _healthTimer = Timer.periodic(
      Duration(seconds: settings.healthIntervalSeconds),
      (_) => _healthCheck(),
    );
    if (Platform.isAndroid) {
      _androidServiceTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(syncAndroidServiceState()),
      );
    }
  }

  Future<void> _healthCheck() async {
    if (!connected || activeNode == null) return;
    if (Platform.isAndroid && !await syncAndroidServiceState()) return;
    final preserveConnection = _androidDiscoveryPreservesConnection;
    final result = await engine.checkActive();
    if (!result.ok) {
      activeNode!.recordFailure();
      _qualityFailures++;
      _log(
        'Health check failed ($_qualityFailures/${settings.failureThreshold})',
      );
      if (_qualityFailures >= settings.failureThreshold && !preserveConnection)
        await failover(hard: true);
      else if (preserveConnection &&
          _qualityFailures >= settings.failureThreshold) {
        _setPhase(AppPhase.degraded, 'Connection quality is poor');
      }
      return;
    }
    activeNode!.recordSuccess(result.latency);
    activeNode!.state = NodeState.active;
    if (result.latency > settings.qualityLatencyMs)
      _qualityFailures++;
    else
      _qualityFailures = 0;
    if (settings.autoQualityFailover &&
        _qualityFailures >= settings.failureThreshold) {
      if (!preserveConnection) {
        final switched = await failover(hard: false);
        if (!switched) {
          _setPhase(AppPhase.degraded, 'Connection quality is poor');
        }
      } else {
        _setPhase(AppPhase.degraded, 'Connection quality is poor');
      }
    } else {
      if (phase == AppPhase.degraded) {
        _setPhase(AppPhase.connected, 'Connected');
      } else {
        notifyListeners();
      }
    }
  }

  Future<bool> failover({required bool hard}) async {
    if (hard && activeNode?.consecutiveFailures != 0) {
      _preferredNode = null;
    }
    if (backups.isEmpty) {
      if (Platform.isAndroid) {
        _log('No backup servers available; start a 5-minute search window');
        _setPhase(AppPhase.degraded, 'No backup servers — search for new ones');
        return false;
      }
      _log('No prepared backup; starting a new search');
      await engine.stop();
      activeNode = null;
      await _persistPool();
      await connect();
      return connected;
    }
    if (!hard &&
        _lastFailover != null &&
        DateTime.now().difference(_lastFailover!).inSeconds <
            settings.failoverCooldownSeconds)
      return false;
    final next = lowestLatencyNode(backups);
    return _switchToBackup(next);
  }

  Future<bool> connectToBackup(VpnNode node) async {
    if (!connected ||
        !backups.any((backup) => backup.fingerprint == node.fingerprint)) {
      return false;
    }
    return _switchToBackup(node);
  }

  Future<bool> _switchToBackup(VpnNode next) async {
    backups.removeWhere((backup) => backup.fingerprint == next.fingerprint);
    await _persistPool();
    _setPhase(AppPhase.switching, 'Switching server…');
    try {
      await _activate(next);
      _lastFailover = DateTime.now();
      _qualityFailures = 0;
      if (!Platform.isAndroid) unawaited(_fillBackups(exclude: next));
      return true;
    } on _ConnectionCancelled {
      if (!connected && phase != AppPhase.disconnected) {
        _setPhase(AppPhase.disconnected, 'Ready');
      }
      return false;
    } catch (e) {
      next.recordFailure();
      _log('Backup failed: $e');
      return failover(hard: true);
    }
  }

  Future<bool> manualSwitch() => failover(hard: true);
  Future<void> disconnect() async {
    _connectionCancelRequested = true;
    _healthTimer?.cancel();
    _androidServiceTimer?.cancel();
    _androidServiceTimer = null;
    _setPhase(AppPhase.disconnecting, 'Disconnecting…');
    if (activeNode != null) {
      _preferredNode = activeNode;
      activeNode!.state = NodeState.working;
      if (activeNode!.consecutiveFailures == 0 &&
          !backups.any(
            (backup) => backup.fingerprint == activeNode!.fingerprint,
          )) {
        activeNode!.state = NodeState.standby;
        backups.add(activeNode!);
        _sortAndTrimBackups();
      }
    }
    await _persistPool();
    await engine.stop();
    activeNode = null;
    _setPhase(AppPhase.disconnected, 'Ready');
    await _setupTray();
  }

  Future<void> changeMode(ConnectionMode mode) async {
    final reconnect = connected;
    settings.mode = mode;
    await storage.saveSettings(settings);
    if (reconnect) {
      final node = activeNode!;
      await engine.stop();
      await _activate(node);
    }
    notifyListeners();
  }

  Future<void> addCustomUri(String raw) async {
    final node = NodeParser().parseUri(raw.trim(), 'custom');
    if (node == null) throw FormatException('Unsupported or invalid URI');
    nodes = repository.deduplicate([node, ...nodes], nodes);
    await storage.saveNodes(nodes);
    _log('Custom ${node.protocol} profile added');
  }

  Future<void> addSubscription(String url, {String? name}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme)
      throw FormatException('Invalid subscription URL');
    final source = VpnSource(
      id: 'custom-${DateTime.now().millisecondsSinceEpoch}',
      name: name?.trim().isNotEmpty == true ? name!.trim() : uri.host,
      url: uri.toString(),
      custom: true,
    );
    sources.add(source);
    await storage.saveSources(sources);
    _log('Subscription ${source.name} added');
  }

  Future<void> setSourceEnabled(int index, bool enabled) async {
    sources[index] = sources[index].copyWith(enabled: enabled);
    await storage.saveSources(sources);
    notifyListeners();
  }

  Future<bool> setProtocolEnabled(String protocol, bool enabled) async {
    if (!VpnProtocol.isKnown(protocol)) return false;
    if (settings.isProtocolEnabled(protocol) == enabled) return true;
    if (!enabled && settings.enabledProtocolCount <= 1) return false;

    final disabledActive =
        !enabled && activeNode?.protocol == protocol && connected;
    settings.enabledProtocols[protocol] = enabled;
    backups.removeWhere((node) {
      final remove = !_enabled(node);
      if (remove) node.state = NodeState.working;
      return remove;
    });
    _resetBackgroundScan();
    await storage.saveSettings(settings);
    await _persistPool();

    if (disabledActive) {
      await disconnect();
      await connect();
    } else {
      _startBackgroundDiscovery();
      notifyListeners();
    }
    return true;
  }

  Future<void> saveSettings() async {
    await storage.saveSettings(settings);
    _sortAndTrimBackups();
    _resetBackgroundScan();
    await _persistPool();
    _startHealthMonitor();
    _startBackgroundDiscovery();
    notifyListeners();
  }

  Future<void> saveSplitTunneling() async {
    await storage.saveSettings(settings);
    if (connected && activeNode != null) {
      final node = activeNode!;
      await engine.stop();
      await _activate(node);
    }
    notifyListeners();
  }

  Future<void> addSplitApp(String path) async {
    final entered = path.trim();
    if (entered.isEmpty) {
      throw const FormatException('Application path is empty');
    }
    final file = File(entered);
    if (!await file.exists() || !entered.toLowerCase().endsWith('.exe')) {
      throw const FormatException('Select an existing .exe application');
    }
    final normalized = file.absolute.path;
    if (settings.splitTunneling.applications.any(
      (app) => app.path.toLowerCase() == normalized.toLowerCase(),
    )) {
      return;
    }
    settings.splitTunneling.applications.add(
      SplitTunnelApp(
        name: normalized.split(RegExp(r'[\\/]')).last,
        path: normalized,
      ),
    );
    await saveSplitTunneling();
  }

  Future<void> addSplitFolder(String path) async {
    final entered = path.trim();
    if (entered.isEmpty) {
      throw const FormatException('Folder path is empty');
    }
    final directory = Directory(entered);
    if (!await directory.exists()) {
      throw const FormatException('Select an existing application folder');
    }
    final normalized = directory.absolute.path;
    if (settings.splitTunneling.applications.any(
      (app) => app.path.toLowerCase() == normalized.toLowerCase(),
    )) {
      return;
    }
    settings.splitTunneling.applications.add(
      SplitTunnelApp(
        name: normalized.split(RegExp(r'[\\/]')).last,
        path: normalized,
        isDirectory: true,
      ),
    );
    await saveSplitTunneling();
  }

  Future<void> addSplitAndroidApp(String name, String packageName) async {
    final package = packageName.trim();
    if (package.isEmpty)
      throw const FormatException('Application package is empty');
    if (settings.splitTunneling.applications.any(
      (app) => app.isAndroidPackage && app.path == package,
    )) {
      return;
    }
    settings.splitTunneling.applications.add(
      SplitTunnelApp(
        name: name.trim().isEmpty ? package : name.trim(),
        path: package,
        isAndroidPackage: true,
      ),
    );
    await saveSplitTunneling();
  }

  Future<void> removeSplitApp(int index) async {
    settings.splitTunneling.applications.removeAt(index);
    await saveSplitTunneling();
  }

  Future<void> addSplitDomain(String value) async {
    var domain = value.trim().toLowerCase();
    if (domain.startsWith('*.')) domain = domain.substring(2);
    if (domain.startsWith('https://')) domain = domain.substring(8);
    if (domain.startsWith('http://')) domain = domain.substring(7);
    domain = domain.split('/').first.split(':').first;
    if (domain.endsWith('.')) domain = domain.substring(0, domain.length - 1);
    if (domain.isEmpty || !domain.contains('.')) {
      throw const FormatException('Enter a domain such as youtube.com');
    }
    if (!settings.splitTunneling.domains.contains(domain)) {
      settings.splitTunneling.domains.add(domain);
      await saveSplitTunneling();
    }
  }

  Future<void> removeSplitDomain(int index) async {
    settings.splitTunneling.domains.removeAt(index);
    await saveSplitTunneling();
  }

  Future<void> _persistPool() => storage.saveConnectionPool(
    activeFingerprint: _preferredNode?.fingerprint,
    backupFingerprints: () {
      final sorted =
          backups
              .where((node) => node.fingerprint != activeNode?.fingerprint)
              .toList()
            ..sort(latencyOrder);
      return sorted.map((node) => node.fingerprint);
    }(),
    androidInitialPoolReady: _androidInitialPoolReady,
  );

  void _sortAndTrimBackups() {
    backups.removeWhere((node) {
      final remove = !_enabled(node);
      if (remove) node.state = NodeState.working;
      return remove;
    });
    backups.sort(latencyOrder);
    if (backups.length <= settings.backupPoolSize) return;
    for (final node in backups.sublist(settings.backupPoolSize)) {
      node.state = NodeState.working;
    }
    backups = backups.take(settings.backupPoolSize).toList();
  }

  void _fail(String message) {
    error = message.replaceFirst('Bad state: ', '');
    phase = AppPhase.error;
    status = error!;
    _log('Error: $error');
  }

  Future<void> shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    _backgroundTimer?.cancel();
    _androidSearchTimer?.cancel();
    _androidServiceTimer?.cancel();
    _androidManualSearchRunning = false;
    _androidSearchUntil = null;
    _connectionCancelRequested = true;
    _searchCancelRequested = true;
    _notifyTimer?.cancel();
    _nodesSaveTimer?.cancel();
    try {
      await engine.cancelProbes();
      await disconnect();
      await storage.saveNodes(nodes);
      if (Platform.isWindows) {
        trayManager.removeListener(this);
        windowManager.removeListener(this);
        await trayManager.destroy();
        await windowManager.destroy();
      }
    } finally {
      _shuttingDown = false;
    }
  }
}
