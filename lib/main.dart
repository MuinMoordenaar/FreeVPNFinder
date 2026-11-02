import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mmkv/mmkv.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    const options = WindowOptions(
      size: Size(1080, 720),
      minimumSize: Size(940, 640),
      center: true,
      backgroundColor: Color(0xFF090C12),
      title: 'Free VPN Finder',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      await windowManager.show();
      await windowManager.focus();
    });
    final controller = AppController();
    await controller.initialize();
    runApp(FreeVpnFinderApp(controller: controller));
    return;
  }

  final controller = AppController();
  runApp(
    AppStartup(
      controller: controller,
      initialize: () async {
        if (Platform.isAndroid) {
          const channel = MethodChannel('free_vpn_finder/android');
          final rootDir = await channel.invokeMethod<String>('getMmkvRoot');
          if (rootDir == null || rootDir.isEmpty) {
            throw StateError('Android MMKV directory is unavailable');
          }
          await MMKV.initialize(rootDir: rootDir);
        }
        await controller.initialize();
      },
    ),
  );
}

class AppStartup extends StatefulWidget {
  const AppStartup({
    super.key,
    required this.controller,
    required this.initialize,
  });

  final AppController controller;
  final Future<void> Function() initialize;

  @override
  State<AppStartup> createState() => _AppStartupState();
}

class _AppStartupState extends State<AppStartup> {
  late Future<void> _initialization;

  @override
  void initState() {
    super.initState();
    _initialization = widget.initialize();
  }

  void _retry() {
    setState(() => _initialization = widget.initialize());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _initialization,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _StartupMessage(
          title: 'Не удалось запустить приложение',
          details: '${snapshot.error}',
          action: _retry,
          actionLabel: 'Повторить',
        );
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const _StartupMessage(
          title: 'Free VPN Finder',
          details: 'Подготовка приложения…',
        );
      }
      return FreeVpnFinderApp(controller: widget.controller);
    },
  );
}

class _StartupMessage extends StatelessWidget {
  const _StartupMessage({
    required this.title,
    required this.details,
    this.action,
    this.actionLabel,
  });

  final String title;
  final String details;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      backgroundColor: bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 96,
                height: 96,
                child: Image.asset(
                  'assets/brand_logo.png',
                  color: Colors.white,
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(details, textAlign: TextAlign.center),
              if (action != null) ...[
                const SizedBox(height: 20),
                FilledButton(onPressed: action, child: Text(actionLabel!)),
              ] else ...[
                const SizedBox(height: 20),
                const CircularProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
