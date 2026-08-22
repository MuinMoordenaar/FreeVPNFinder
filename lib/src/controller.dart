import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'models.dart';
import 'node_parser.dart';
import 'reconnect_policy.dart';
import 'sing_box_engine.dart';
import 'sources.dart';
import 'storage.dart';
import 'updater.dart';

class AppController extends ChangeNotifier with TrayListener, WindowListener {
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
  DateTime? _lastFailover;
  int _qualityFailures = 0;
  bool _cancelRequested = false;
  bool _operationInFlight = false;
  bool _shuttingDown = false;
  final updater = AppUpdater();
  UpdateInfo? availableUpdate;
  bool checkingUpdate = false;
  bool installingUpdate = false;
  String? updateMessage;

  bool get connected =>
      phase == AppPhase.connected || phase == AppPhase.degraded;

  Future<void> updateAction() async {
    if (installingUpdate) return;
    if (availableUpdate != null) {
      installingUpdate = true;
      updateMessage = 'Downloading update…';
      notifyListeners();
      try {
        if (connected) await disconnect();
        await updater.install(availableUpdate!);
        updateMessage = 'Restarting…';
        notifyListeners();
        await shutdown();
        exit(0);
      } catch (e) {
        installingUpdate = false;
        updateMessage = e.toString().replaceFirst('Exception: ', '');
        notifyListeners();
      }
      return;
    }
    if (checkingUpdate) return;
    checkingUpdate = true;
    updateMessage = 'Checking for updates…';
    notifyListeners();
    try {
      availableUpdate = await updater.check();
      updateMessage = availableUpdate == null
          ? 'You have the latest version'
          : 'Version ${availableUpdate!.version} is available';
    } catch (e) {
      updateMessage = e.toString().replaceFirst('Exception: ', '');
    } finally {
      checkingUpdate = false;
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    await storage.initialize();
    repository = SourceRepository(storage);
    engine = SingBoxEngine(storage);
    settings = await storage.loadSettings();
    nodes = await storage.loadNodes();
    final savedPool = await storage.loadConnectionPool();
    final nodesByFingerprint = {
      for (final node in nodes) node.fingerprint: node,
    };
    _preferredNode = nodesByFingerprint[savedPool.active];
    backups = [
      for (final fingerprint in savedPool.backups)
        if (nodesByFingerprint[fingerprint] case final node?)
          node..state = NodeState.standby,
    ];
    sources = await storage.loadSources() ?? SourceRepository.defaults.toList();
    trayManager.addListener(this);
    windowManager.addListener(this);
    await _setupTray();
    _log(
      'Application initialized with ${nodes.length} cached nodes and ${backups.length} saved backups',
    );
  }

  Future<void> _setupTray() async {
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
    notifyListeners();
  }

  Future<void> toggleConnection() async {
    if (_operationInFlight || _shuttingDown) return;
    _operationInFlight = true;
    try {
      if (phase == AppPhase.disconnected) {
        await connect();
      } else {
        await disconnect();
      }
    } finally {
      _operationInFlight = false;
    }
  }

  Future<void> connect() async {
    _cancelRequested = false;
    tested = 0;
    try {
      _setPhase(AppPhase.searching, 'Checking your recent servers…');
      final attempted = <String>{};
      final recent = recentConnectionCandidates(_preferredNode, backups);
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
      if (_cancelRequested) return;
      _setPhase(AppPhase.searching, 'Searching for a working server…');
      final winner = await _findFirstWorking(
        nodes.where(_eligible).take(80),
        attempted,
      );
      if (winner != null) {
        await _activate(winner);
        unawaited(_fillBackups(exclude: winner));
        return;
      }
      throw StateError('No working servers found');
    } catch (e) {
      _fail('$e');
    } finally {
      await storage.saveNodes(nodes);
      await _setupTray();
    }
  }

  Future<VpnNode?> _findFirstWorking(
    Iterable<VpnNode> candidates,
    Set<String> attempted,
  ) async {
    for (final node in candidates) {
      if (_cancelRequested) return null;
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

  bool _eligible(VpnNode n) =>
      n.state != NodeState.cooldown ||
      n.lastFailureAt == null ||
      DateTime.now().difference(n.lastFailureAt!).inHours >= 1;

  Future<void> refreshSources() async {
    _setPhase(AppPhase.updatingSources, 'Updating server sources…');
    final fresh = <VpnNode>[];
    for (final source in sources.where((s) => s.enabled)) {
      if (_cancelRequested) return;
      final result = await repository.fetch(source);
      fresh.addAll(result);
      _log('${source.name}: ${result.length} configurations');
    }
    if (fresh.isNotEmpty) nodes = repository.deduplicate(fresh, nodes);
    await storage.saveNodes(nodes);
    _log('${nodes.length} unique nodes available');
  }

  Future<void> _activate(VpnNode node) async {
    final previous = activeNode;
    _setPhase(AppPhase.connecting, 'Connecting to ${node.name}…');
    await engine.start(node, settings.mode);
    _setPhase(AppPhase.verifying, 'Verifying connection…');
    final result = await engine.checkActive();
    if (!result.ok) {
      await engine.stop();
      node.recordFailure();
      throw StateError('Connection verification failed');
    }
    if (previous != null &&
        previous.fingerprint != node.fingerprint &&
        previous.consecutiveFailures == 0 &&
        !backups.any((backup) => backup.fingerprint == previous.fingerprint)) {
      previous.state = NodeState.standby;
      backups.add(previous);
    }
    backups.removeWhere((backup) => backup.fingerprint == node.fingerprint);
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

  Future<void> _fillBackups({VpnNode? exclude}) async {
    backups = backups
        .where((n) => n.fingerprint != exclude?.fingerprint)
        .toList();
    for (final node in nodes.where(
      (n) =>
          _eligible(n) &&
          n.fingerprint != activeNode?.fingerprint &&
          !backups.any((b) => b.fingerprint == n.fingerprint),
    )) {
      if (_cancelRequested || !connected || backups.length >= 5) break;
      final result = await engine.probe(node, port: 21950);
      if (result.ok) {
        node.recordSuccess(result.latency);
        node.state = NodeState.standby;
        backups.add(node);
        _log('Backup ${backups.length}/5 ready: ${node.name}');
        await _persistPool();
        notifyListeners();
      } else {
        node.recordFailure();
      }
    }
    await storage.saveNodes(nodes);
    await _persistPool();
  }

  void _startHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(
      Duration(seconds: settings.healthIntervalSeconds),
      (_) => _healthCheck(),
    );
  }

  Future<void> _healthCheck() async {
    if (!connected || activeNode == null) return;
    final result = await engine.checkActive();
    if (!result.ok) {
      activeNode!.recordFailure();
      _qualityFailures++;
      _log(
        'Health check failed ($_qualityFailures/${settings.failureThreshold})',
      );
      if (_qualityFailures >= settings.failureThreshold)
        await failover(hard: true);
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
      _setPhase(AppPhase.degraded, 'Connection quality is poor');
      await failover(hard: false);
    } else {
      notifyListeners();
    }
  }

  Future<void> failover({required bool hard}) async {
    if (hard && activeNode?.consecutiveFailures != 0) {
      _preferredNode = null;
    }
    if (backups.isEmpty) {
      _log('No prepared backup; starting a new search');
      await engine.stop();
      activeNode = null;
      await _persistPool();
      await connect();
      return;
    }
    if (!hard &&
        _lastFailover != null &&
        DateTime.now().difference(_lastFailover!).inSeconds <
            settings.failoverCooldownSeconds)
      return;
    final next = backups.reduce((a, b) => a.score >= b.score ? a : b);
    if (!hard &&
        activeNode?.latency != null &&
        next.latency != null &&
        next.latency! > activeNode!.latency! * .7) {
      _qualityFailures = 0;
      return;
    }
    backups.remove(next);
    await _persistPool();
    _setPhase(AppPhase.switching, 'Switching server…');
    try {
      await _activate(next);
      _lastFailover = DateTime.now();
      _qualityFailures = 0;
      unawaited(_fillBackups(exclude: next));
    } catch (e) {
      next.recordFailure();
      _log('Backup failed: $e');
      await failover(hard: true);
    }
  }

  Future<void> manualSwitch() => failover(hard: true);
  Future<void> disconnect() async {
    _cancelRequested = true;
    _healthTimer?.cancel();
    _setPhase(AppPhase.disconnecting, 'Disconnecting…');
    if (activeNode != null) {
      _preferredNode = activeNode;
      activeNode!.state = NodeState.working;
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

  Future<void> saveSettings() async {
    await storage.saveSettings(settings);
    _startHealthMonitor();
    notifyListeners();
  }

  Future<void> _persistPool() => storage.saveConnectionPool(
    activeFingerprint: _preferredNode?.fingerprint,
    backupFingerprints: backups
        .where((node) => node.fingerprint != activeNode?.fingerprint)
        .map((node) => node.fingerprint),
  );

  void _fail(String message) {
    error = message.replaceFirst('Bad state: ', '');
    phase = AppPhase.error;
    status = error!;
    _log('Error: $error');
  }

  Future<void> shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    try {
      await disconnect();
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      await trayManager.destroy();
      await windowManager.destroy();
    } finally {
      _shuttingDown = false;
    }
  }
}
