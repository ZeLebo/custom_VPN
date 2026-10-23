import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';

/// Where traffic of an app goes.
enum AppRoute {
  vpn('VPN'),
  direct('Напрямую'),
  block('Блок');

  const AppRoute(this.label);

  final String label;
}

/// Routing of one app, matched by the core with PROCESS-* rules.
///
/// [app] is an app bundle (`/Applications/Telegram.app`), an executable path
/// (`/usr/bin/curl`) or a bare process name (`curl`).
class AppRule {
  const AppRule({required this.app, required this.route});

  factory AppRule.fromJson(Map<String, dynamic> json) => AppRule(
        app: json['app'] as String,
        route: AppRoute.values.firstWhere(
          (route) => route.name == json['route'],
          orElse: () => AppRoute.vpn,
        ),
      );

  final String app;
  final AppRoute route;

  Map<String, dynamic> toJson() => {'app': app, 'route': route.name};

  /// `Telegram` for `/Applications/Telegram.app`.
  String get name => basenameWithoutExtension(app);

  bool get isBundle => app.endsWith('.app');

  /// Rule payload without the target. A bundle also covers its helper
  /// processes (`Google Chrome Helper` lives inside `Google Chrome.app`), so
  /// it is matched by path; mihomo's `*` matches `/` too.
  String get payload {
    if (isBundle) return 'PROCESS-PATH-WILDCARD,$app/*';
    if (app.startsWith('/')) return 'PROCESS-PATH,$app';
    return 'PROCESS-NAME,$app';
  }

  AppRule copyWith({AppRoute? route}) =>
      AppRule(app: app, route: route ?? this.route);
}

/// Per-app routing on top of the profile rules, stored outside the profile so
/// it survives subscription updates and applies to every profile.
class AppRules {
  factory AppRules() => _instance ??= AppRules._internal();

  AppRules._internal();

  static AppRules? _instance;

  /// mihomo has no reliable process lookup on Android/iOS, and app paths are
  /// macOS-shaped here.
  bool get isAvailable => Platform.isMacOS;

  String get _path => join(
        Platform.environment['HOME'] ?? '',
        'Library',
        'Application Support',
        'CustomVPN',
        'app-rules.json',
      );

  List<AppRule>? _rules;
  bool? _onlyListed;

  List<AppRule> get rules {
    if (_rules == null) _load();
    return List.unmodifiable(_rules!);
  }

  /// Only the listed VPN apps use the VPN; everything else goes direct.
  bool get onlyListed {
    if (_onlyListed == null) _load();
    return _onlyListed!;
  }

  set onlyListed(bool value) {
    _onlyListed = value;
    _save();
  }

  /// Adds [rule] or replaces the rule for the same app.
  void put(AppRule rule) {
    final next = [...rules];
    final index = next.indexWhere((item) => item.app == rule.app);
    if (index < 0) {
      next.add(rule);
    } else {
      next[index] = rule;
    }
    _rules = next;
    _save();
  }

  void remove(String app) {
    _rules = rules.where((rule) => rule.app != app).toList();
    _save();
  }

  void _load() {
    _rules = [];
    _onlyListed = false;
    try {
      final file = File(_path);
      if (!file.existsSync()) return;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      _onlyListed = json['onlyListed'] == true;
      _rules = [
        for (final item in (json['rules'] as List? ?? const []))
          if (item is Map<String, dynamic>) AppRule.fromJson(item),
      ];
    } catch (_) {}
  }

  void _save() {
    final file = File(_path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({
      'onlyListed': onlyListed,
      'rules': [for (final rule in rules) rule.toJson()],
    }));
  }

  /// Puts the app rules in front of [rules] (they win over zapret routes and
  /// profile rules). With [onlyListed] everything else goes DIRECT.
  List<dynamic> patchConfig(Map<String, dynamic> rawConfig, List<dynamic> rules) {
    if (!isAvailable) return rules;
    final appRules = this.rules;
    if (appRules.isEmpty && !onlyListed) return rules;
    final vpnTarget = _vpnTarget(rawConfig, rules);
    final patched = [
      for (final rule in appRules)
        // commas would split the rule; no VPN group means nowhere to send it
        if (!rule.app.contains(',') &&
            (rule.route != AppRoute.vpn || vpnTarget != null))
          '${rule.payload},${switch (rule.route) {
            AppRoute.vpn => vpnTarget,
            AppRoute.direct => 'DIRECT',
            AppRoute.block => 'REJECT',
          }}',
    ];
    if (patched.isNotEmpty && rawConfig['find-process-mode'] == 'off') {
      rawConfig['find-process-mode'] = 'strict';
    }
    return [
      ...patched,
      if (onlyListed) 'MATCH,DIRECT' else ...rules,
    ];
  }

  /// The group the profile sends unmatched traffic to, else its first group.
  String? _vpnTarget(Map<String, dynamic> rawConfig, List<dynamic> rules) {
    for (final rule in rules.reversed) {
      final parts = rule.toString().split(',');
      if (parts.length >= 2 && parts.first.trim() == 'MATCH') {
        final target = parts[1].trim();
        if (target != 'DIRECT' && !target.startsWith('REJECT')) return target;
        break;
      }
    }
    final groups = rawConfig['proxy-groups'];
    if (groups is List) {
      for (final group in groups) {
        if (group is Map && group['name'] != null && group['type'] == 'select') {
          return group['name'].toString();
        }
      }
    }
    return null;
  }
}

final appRules = AppRules();
