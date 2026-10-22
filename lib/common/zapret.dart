import 'dart:convert';
import 'dart:io';

import 'package:flclashx/clash/core.dart';
import 'package:path/path.dart';

/// Service that should prefer the zapret DPI bypass (DIRECT) and fall back to
/// the VPN when DIRECT does not get through (zapret stopped, or the ISP blocks
/// the service by IP so no DPI trick helps).
class ZapretRoute {
  const ZapretRoute({
    required this.name,
    required this.testUrl,
    required this.rules,
  });

  final String name;
  final String testUrl;

  /// Rule payloads without the target, e.g. `DOMAIN-SUFFIX,youtube.com`.
  final List<String> rules;

  String get group => 'Zapret $name';
}

const zapretRoutes = [
  ZapretRoute(
    name: 'YouTube',
    testUrl: 'https://www.youtube.com/generate_204',
    rules: [
      'DOMAIN-SUFFIX,youtube.com',
      'DOMAIN-SUFFIX,youtu.be',
      'DOMAIN-SUFFIX,youtube-nocookie.com',
      'DOMAIN-SUFFIX,youtubekids.com',
      'DOMAIN-SUFFIX,googlevideo.com',
      'DOMAIN-SUFFIX,ytimg.com',
      'DOMAIN-SUFFIX,ggpht.com',
      'DOMAIN-SUFFIX,youtubei.googleapis.com',
      'DOMAIN-SUFFIX,youtube.googleapis.com',
      'DOMAIN-SUFFIX,youtubeembeddedplayer.googleapis.com',
      'DOMAIN-SUFFIX,jnn-pa.googleapis.com',
      'DOMAIN-SUFFIX,wide-youtube.l.google.com',
      'DOMAIN-SUFFIX,youtube-ui.l.google.com',
      'DOMAIN-SUFFIX,ytimg.l.google.com',
      'DOMAIN-SUFFIX,yt-video-upload.l.google.com',
      'DOMAIN,yt3.googleusercontent.com',
    ],
  ),
  ZapretRoute(
    name: 'Discord',
    testUrl: 'https://discord.com/api/v9/gateway',
    rules: [
      'DOMAIN-SUFFIX,dis.gd',
      'DOMAIN-SUFFIX,discord.app',
      'DOMAIN-SUFFIX,discord.co',
      'DOMAIN-SUFFIX,discord.com',
      'DOMAIN-SUFFIX,discord.design',
      'DOMAIN-SUFFIX,discord.dev',
      'DOMAIN-SUFFIX,discord.gift',
      'DOMAIN-SUFFIX,discord.gifts',
      'DOMAIN-SUFFIX,discord.gg',
      'DOMAIN-SUFFIX,discord.media',
      'DOMAIN-SUFFIX,discord.new',
      'DOMAIN-SUFFIX,discord.store',
      'DOMAIN-SUFFIX,discord.status',
      'DOMAIN-SUFFIX,discord-activities.com',
      'DOMAIN-SUFFIX,discordactivities.com',
      'DOMAIN-SUFFIX,discordapp.com',
      'DOMAIN-SUFFIX,discordapp.net',
      'DOMAIN-SUFFIX,discordcdn.com',
      'DOMAIN-SUFFIX,discordmerch.com',
      'DOMAIN-SUFFIX,discordpartygames.com',
      'DOMAIN-SUFFIX,discordsays.com',
      'DOMAIN-SUFFIX,discordsez.com',
      'DOMAIN-SUFFIX,discordstatus.com',
      'DOMAIN,discord-attachments-uploads-prd.storage.googleapis.com',
      // voice
      'AND,((NETWORK,UDP),(DST-PORT,50000-50100))',
      'AND,((NETWORK,UDP),(DST-PORT,19294-19344))',
    ],
  ),
];

class ZapretStrategy {
  const ZapretStrategy(this.id, this.title);

  final String id;
  final String title;
}

/// Parsed `strategy-test.txt` written by test-strategies.sh.
class ZapretTestReport {
  const ZapretTestReport({
    required this.date,
    required this.scores,
    required this.best,
  });

  final String date;

  /// Strategy title -> "score/total", or "ошибка запуска".
  final Map<String, String> scores;

  /// Titles of the best strategies.
  final List<String> best;
}

/// Controls the ZapretMac LaunchDaemon using the payload bundled into the app.
/// User data (lists, selected strategy, IPSet mode) is shared with ZapretMac.
/// Strategy updates from upstream releases live in an overlay in user data and
/// are merged over the bundled payload whenever a script runs.
class Zapret {
  factory Zapret() => _instance ??= Zapret._internal();

  Zapret._internal();

  static Zapret? _instance;

  static const defaultStrategy = 'general-simple-fake';
  static const ipsetModes = ['none', 'loaded', 'any'];
  static const _releasesUrl =
      'https://api.github.com/repos/Flowseal/zapret-mac-discord-youtube/releases/latest';

  String get payloadPath => join(
        dirname(dirname(Platform.resolvedExecutable)),
        'Resources',
        'zapret',
        'Payload',
      );

  String get dataRoot => join(
        Platform.environment['HOME'] ?? '',
        'Library',
        'Application Support',
        'ZapretMac',
      );

  String get listsPath => join(dataRoot, 'lists');

  String get overlayPath => join(dataRoot, 'payload-overlay');

  bool get isAvailable =>
      Platform.isMacOS && File(join(payloadPath, 'install.sh')).existsSync();

  /// The zapret dashboard widgets get added to an existing dashboard once;
  /// removing them afterwards sticks.
  bool get dashboardWidgetsAdded =>
      _readState('customvpn-dashboard-widgets').isNotEmpty;

  set dashboardWidgetsAdded(bool value) =>
      value ? _writeState('customvpn-dashboard-widgets', 'added') : null;

  bool get routingEnabled => _readState('flclashx-routing') != 'off';

  set routingEnabled(bool value) =>
      _writeState('flclashx-routing', value ? 'on' : 'off');

  String get strategy {
    final value = _readState('selected-strategy');
    return value.isEmpty ? defaultStrategy : value;
  }

  String get ipsetMode {
    final value = _readState('ipset-mode');
    return ipsetModes.contains(value) ? value : 'none';
  }

  /// Version of the strategies in use: the overlay if present, else bundled.
  String get version {
    final overlay = File(join(overlayPath, 'VERSION'));
    final file =
        overlay.existsSync() ? overlay : File(join(payloadPath, 'VERSION'));
    return file.existsSync() ? file.readAsStringSync().trim() : '';
  }

  List<ZapretStrategy> get strategies {
    final overlay = File(join(overlayPath, 'strategies.tsv'));
    final file =
        overlay.existsSync() ? overlay : File(join(payloadPath, 'strategies.tsv'));
    if (!file.existsSync()) return [];
    return file
        .readAsLinesSync()
        .map((line) => line.split('\t'))
        .where((parts) => parts.length == 2)
        .map((parts) => ZapretStrategy(parts[0], parts[1]))
        .toList();
  }

  Future<bool> isRunning() async {
    final result = await Process.run('/usr/bin/pgrep', ['-x', 'utunws']);
    return result.exitCode == 0;
  }

  /// Same first-run setup as ZapretMac: copy default lists, default state.
  void initUserData() {
    Directory(listsPath).createSync(recursive: true);
    final defaults = Directory(join(payloadPath, 'default-lists'));
    if (defaults.existsSync()) {
      for (final entity in defaults.listSync().whereType<File>()) {
        final target = File(join(listsPath, basename(entity.path)));
        if (!target.existsSync()) entity.copySync(target.path);
      }
    }
    if (_readState('selected-strategy').isEmpty) {
      _writeState('selected-strategy', defaultStrategy);
    }
    if (_readState('ipset-mode').isEmpty) _writeState('ipset-mode', 'none');
  }

  /// Returns an error message, or null on success.
  Future<String?> start() async {
    initUserData();
    return _runStaged('install.sh', (payload) => [payload, dataRoot]);
  }

  Future<String?> stop() => _runStaged('stop.sh', (_) => []);

  Future<String?> setStrategy(String id) async {
    _writeState('selected-strategy', id);
    return _restartIfRunning();
  }

  Future<String?> setIpsetMode(String mode) async {
    _writeState('ipset-mode', mode);
    return _restartIfRunning();
  }

  /// Lists are copied into the daemon on (re)start, so edits need a restart.
  Future<String?> reload() => _restartIfRunning();

  Future<String?> _restartIfRunning() async {
    if (!await isRunning()) return null;
    return _runStaged('restart.sh', (_) => []);
  }

  /// Runs every strategy against YouTube/Discord (takes minutes) and writes
  /// the report; the previous strategy and running state are restored after.
  Future<String?> testStrategies() async {
    initUserData();
    _deleteState('strategy-test-cancel');
    final uid = await _id('-u');
    final gid = await _id('-g');
    return _runStaged(
      'test-strategies.sh',
      (payload) => [payload, dataRoot, uid, gid],
    );
  }

  void cancelTest() => _writeState('strategy-test-cancel', '1');

  String get testProgress => _readState('strategy-test-progress');

  ZapretTestReport? get testReport {
    final file = File(join(dataRoot, 'strategy-test.txt'));
    if (!file.existsSync()) return null;
    final lines = file.readAsLinesSync();
    if (lines.isEmpty) return null;
    final scores = <String, String>{};
    final best = <String>[];
    final scoreLine = RegExp(r'^(.*?)\s+(\d+/\d+)\s+\S+\s+\S+\s+\S+\s+\S+\s*$');
    final errorLine = RegExp(r'^(.*?)\s+(ошибка запуска)\s*$');
    final bestLine = RegExp(r'^Лучшая: (.*) \(\d+/\d+\)$');
    var inTable = false;
    for (final line in lines) {
      if (line.startsWith('Strategy ')) {
        inTable = true;
        continue;
      }
      final bestMatch = bestLine.firstMatch(line);
      if (bestMatch != null) {
        best.addAll(bestMatch.group(1)!.split(', '));
        continue;
      }
      if (!inTable) continue;
      final match = scoreLine.firstMatch(line) ?? errorLine.firstMatch(line);
      if (match != null) scores[match.group(1)!.trim()] = match.group(2)!;
    }
    return ZapretTestReport(date: lines.first, scores: scores, best: best);
  }

  /// Checks upstream ZapretMac releases and installs newer strategies, fake
  /// packets and default lists into the overlay. Scripts and utunws stay the
  /// bundled ones (they carry the VPN-compatible pf rules).
  /// Returns a status message.
  Future<String> updateStrategies() async {
    final client = HttpClient()..userAgent = 'FlClashX';
    final temp = await Directory.systemTemp.createTemp('flclashx-zapret-update-');
    try {
      final release = jsonDecode(await _get(client, _releasesUrl)) as Map;
      final tag = release['tag_name'].toString();
      if (!_isNewer(tag, version)) return 'Стратегии актуальны ($version)';
      final asset = (release['assets'] as List)
          .cast<Map>()
          .firstWhere((asset) => asset['name'].toString().endsWith('.zip'));
      final zip = File(join(temp.path, 'release.zip'));
      final request = await client
          .getUrl(Uri.parse(asset['browser_download_url'].toString()));
      final response = await request.close();
      await response.pipe(zip.openWrite());
      final unpacked = join(temp.path, 'unpacked');
      await _check(Process.run('/usr/bin/ditto', ['-x', '-k', zip.path, unpacked]));
      final payload = Directory(unpacked)
          .listSync(recursive: true)
          .whereType<Directory>()
          .firstWhere((dir) =>
              basename(dir.path) == 'Payload' &&
              File(join(dir.path, 'strategies.tsv')).existsSync());

      final next = Directory('$overlayPath.new');
      if (next.existsSync()) next.deleteSync(recursive: true);
      next.createSync(recursive: true);
      for (final name in ['strategies', 'default-lists']) {
        await _check(Process.run('/usr/bin/ditto',
            [join(payload.path, name), join(next.path, name)]));
      }
      File(join(payload.path, 'strategies.tsv'))
          .copySync(join(next.path, 'strategies.tsv'));
      Directory(join(next.path, 'bin')).createSync();
      for (final file in Directory(join(payload.path, 'bin'))
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.bin'))) {
        file.copySync(join(next.path, 'bin', basename(file.path)));
      }
      File(join(next.path, 'VERSION')).writeAsStringSync('$tag\n');

      final current = Directory(overlayPath);
      if (current.existsSync()) current.deleteSync(recursive: true);
      next.renameSync(overlayPath);

      if (await isRunning()) {
        final error = await start();
        if (error != null) return error;
      }
      return 'Стратегии обновлены до $tag';
    } catch (e) {
      return 'Не удалось обновить стратегии: $e';
    } finally {
      client.close();
      temp.deleteSync(recursive: true);
    }
  }

  /// Whether each service is reachable directly (through zapret, past the
  /// VPN): route name -> delay in ms, or null when it doesn't get through.
  Future<Map<String, int?>> checkServices() async {
    final results = await Future.wait(zapretRoutes.map(
      (route) => clashCore.getDelay(route.testUrl, 'DIRECT'),
    ));
    return {
      for (var i = 0; i < zapretRoutes.length; i++)
        zapretRoutes[i].name: (results[i].value ?? -1) > 0 ? results[i].value : null,
    };
  }

  /// Re-checks DIRECT for every route so traffic switches right away instead
  /// of waiting for the next health-check interval.
  Future<void> recheckRoutes() async {
    for (final route in zapretRoutes) {
      await clashCore.healthCheck(route.group);
    }
  }

  /// Adds fallback groups [DIRECT, <VPN target of MATCH>] and puts their rules
  /// first, ahead of profile and override rules.
  List<dynamic> patchConfig(Map<String, dynamic> rawConfig, List<dynamic> rules) {
    if (!isAvailable || !routingEnabled) return rules;
    final vpnTarget = _matchTarget(rules);
    if (vpnTarget == null) return rules;
    final groups = rawConfig['proxy-groups'] is List
        ? List<dynamic>.from(rawConfig['proxy-groups'] as List)
        : <dynamic>[];
    for (final route in zapretRoutes) {
      groups.add({
        'name': route.group,
        'type': 'fallback',
        'proxies': ['DIRECT', vpnTarget],
        'url': route.testUrl,
        'interval': 300,
        'timeout': 3000,
        'lazy': false,
      });
    }
    rawConfig['proxy-groups'] = groups;
    return [
      for (final route in zapretRoutes)
        for (final rule in route.rules) '$rule,${route.group}',
      ...rules,
    ];
  }

  String? _matchTarget(List<dynamic> rules) {
    for (final rule in rules.reversed) {
      final parts = rule.toString().split(',');
      if (parts.length >= 2 && parts.first.trim() == 'MATCH') {
        final target = parts[1].trim();
        return target == 'DIRECT' || target == 'REJECT' ? null : target;
      }
    }
    return null;
  }

  /// Runs [script] as root from a temporary copy of the bundled payload with
  /// the update overlay merged on top.
  Future<String?> _runStaged(
    String script,
    List<String> Function(String payload) arguments,
  ) async {
    final temp = await Directory.systemTemp.createTemp('flclashx-zapret-');
    try {
      final payload = join(temp.path, 'Payload');
      await _check(Process.run('/usr/bin/ditto', [payloadPath, payload]));
      if (Directory(overlayPath).existsSync()) {
        await _check(Process.run('/usr/bin/ditto', [overlayPath, payload]));
      }
      return await _runPrivileged(join(payload, script), arguments(payload));
    } catch (e) {
      return e.toString();
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  Future<String?> _runPrivileged(String script, List<String> arguments) async {
    final command =
        ['/bin/sh', script, ...arguments].map(_shellQuote).join(' ');
    final appleScript =
        'do shell script "${_appleScriptEscape('$command 2>&1')}" with administrator privileges';
    final result = await Process.run('/usr/bin/osascript', ['-e', appleScript]);
    if (result.exitCode == 0) return null;
    final output = '${result.stdout}${result.stderr}'.trim();
    return output.isEmpty ? 'zapret: ${basename(script)} failed' : output;
  }

  Future<void> _check(Future<ProcessResult> process) async {
    final result = await process;
    if (result.exitCode != 0) throw '${result.stderr}'.trim();
  }

  Future<String> _get(HttpClient client, String url) async {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) throw 'HTTP ${response.statusCode}';
    return body;
  }

  Future<String> _id(String flag) async =>
      (await Process.run('/usr/bin/id', [flag])).stdout.toString().trim();

  bool _isNewer(String candidate, String current) {
    List<int> parts(String value) => value
        .replaceFirst(RegExp('^[vV]'), '')
        .split(RegExp(r'[.-]'))
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    final a = parts(candidate);
    final b = parts(current);
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  String _readState(String name) {
    final file = File(join(dataRoot, name));
    return file.existsSync() ? file.readAsStringSync().trim() : '';
  }

  void _writeState(String name, String value) {
    Directory(dataRoot).createSync(recursive: true);
    File(join(dataRoot, name)).writeAsStringSync('$value\n');
  }

  void _deleteState(String name) {
    final file = File(join(dataRoot, name));
    if (file.existsSync()) file.deleteSync();
  }

  String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  String _appleScriptEscape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

final zapret = Zapret();
