import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const appVersion = '1.1.7';
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
      (item) => (item['name'] as String? ?? '').endsWith('.zip'),
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
    final zip = File('${temp.path}${Platform.pathSeparator}update.zip');
    await zip.writeAsBytes(bytes, flush: true);
    final script = File(
      '${temp.path}${Platform.pathSeparator}install-update.ps1',
    );
    await script.writeAsString(r'''
param(
  [int]$ProcessId,
  [string]$Zip,
  [string]$InstallDir,
  [string]$Exe,
  [string]$Log,
  [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
function Write-UpdateLog([string]$Message) {
  Add-Content -LiteralPath $Log -Value ("[{0}] {1}" -f (Get-Date -Format o), $Message)
}
try {
  Write-UpdateLog "Updater started. Target: $InstallDir"
  if (-not $Elevated) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
      Write-UpdateLog 'Requesting administrator permission'
      $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
        '-ProcessId', $ProcessId, '-Zip', $Zip, '-InstallDir', $InstallDir,
        '-Exe', $Exe, '-Log', $Log, '-Elevated')
      Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments
      exit 0
    }
  }
  while (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
    Start-Sleep -Milliseconds 300
  }
  $stage = Join-Path $env:TEMP ("free-vpn-finder-stage-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $stage | Out-Null
  Expand-Archive -LiteralPath $Zip -DestinationPath $stage -Force
  foreach ($item in Get-ChildItem -LiteralPath $stage -Force) {
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $InstallDir $item.Name) -Recurse -Force
  }
  if (-not (Test-Path -LiteralPath $Exe)) { throw "Updated executable was not found: $Exe" }
  Write-UpdateLog 'Files copied successfully; starting updated application'
  Start-Process -FilePath $Exe -WorkingDirectory $InstallDir
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
  Write-UpdateLog 'Update completed'
} catch {
  Write-UpdateLog ("Update failed: " + $_.Exception.Message)
  exit 1
} finally {
  Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
''');
    final log = '${temp.path}${Platform.pathSeparator}update.log';
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-ProcessId',
        pid.toString(),
        '-Zip',
        zip.path,
        '-InstallDir',
        File(Platform.resolvedExecutable).parent.path,
        '-Exe',
        Platform.resolvedExecutable,
        '-Log',
        log,
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
