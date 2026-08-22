import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const appVersion = '1.1.9';
const latestReleaseApi =
    'https://api.github.com/repos/MuinMoordenaar/FreeVPNFinder/releases/latest';

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.downloadUrl,
    this.sha256,
    this.notes = '',
  });

  final String version;
  final String downloadUrl;
  final String? sha256;
  final String notes;
}

class AppUpdater {
  Future<UpdateInfo?> check() async {
    final response = await http.get(
      Uri.parse(latestReleaseApi),
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'FreeVPNFinder',
      },
    );
    if (response.statusCode != 200) {
      throw Exception('Update check failed (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = (data['tag_name'] as String? ?? '').replaceFirst('v', '');
    final assets = (data['assets'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>();
    final asset = assets.firstWhere(
      (item) => (item['name'] as String? ?? '').toLowerCase().endsWith('.exe'),
      orElse: () => <String, dynamic>{},
    );
    final url = asset['browser_download_url'] as String?;
    if (tag.isEmpty || url == null || !_isNewer(tag, appVersion)) return null;
    return UpdateInfo(
      version: tag,
      downloadUrl: url,
      sha256: (asset['digest'] as String?)?.replaceFirst('sha256:', ''),
      notes: data['body'] as String? ?? '',
    );
  }

  Future<void> install(UpdateInfo update) async {
    final response = await http.get(
      Uri.parse(update.downloadUrl),
      headers: {'User-Agent': 'FreeVPNFinder'},
    );
    if (response.statusCode != 200) {
      throw Exception('Update download failed (${response.statusCode})');
    }
    final bytes = response.bodyBytes;
    final actualHash = sha256.convert(bytes).toString();
    if (update.sha256 != null &&
        update.sha256!.isNotEmpty &&
        actualHash.toLowerCase() != update.sha256!.toLowerCase()) {
      throw Exception('Downloaded update failed integrity check');
    }

    final temp = Directory.systemTemp.createTempSync('free-vpn-finder-update-');
    final installer = File(
      '${temp.path}${Platform.pathSeparator}FreeVPNFinder-Setup.exe',
    );
    await installer.writeAsBytes(bytes, flush: true);
    final installDir = File(Platform.resolvedExecutable).parent.path;
    await Process.start(
      installer.path,
      [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
        '/DIR="$installDir"',
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: temp.path,
    );
  }
}

bool _isNewer(String candidate, String current) {
  final next = _parts(candidate);
  final installed = _parts(current);
  for (var i = 0; i < 3; i++) {
    if (next[i] != installed[i]) return next[i] > installed[i];
  }
  return false;
}

List<int> _parts(String value) {
  final clean = value.split('+').first;
  final parts = clean
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  while (parts.length < 3) parts.add(0);
  return parts.take(3).toList();
}
