import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  const options = WindowOptions(
    size: Size(1080, 720),
    minimumSize: Size(940, 640),
    center: true,
    backgroundColor: Color(0xFF070B17),
    title: 'Free VPN Finder',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  final controller = AppController();
  await controller.initialize();
  runApp(FreeVpnFinderApp(controller: controller));
}
