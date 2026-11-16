import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';

enum SiteRoute {
  vpn('VPN'),
  direct('Напрямую'),
  zapret('Zapret → VPN'),
  block('Блок');

  const SiteRoute(this.label);

  final String label;
}

/// Keeps the URL's host, including its subdomain, and rejects rule syntax/IPs.
String normalizeSiteDomain(String input) {
  final value = input.trim();
  final uri = Uri.tryParse(
    value.contains('://') || value.startsWith('//') ? value : 'https://$value',
  );
  if (uri == null ||
      (uri.hasScheme && uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('Введите ссылку http/https или домен');
  }
  final domain = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  final labels = domain.split('.');
  if (domain.length > 253 ||
      labels.length < 2 ||
      InternetAddress.tryParse(domain) != null ||
      labels.any(
        (label) =>
            label.isEmpty ||
            label.length > 63 ||
            !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
      )) {
    throw const FormatException('Введите домен, например example.com');
  }
  return domain;
}

class SiteRule {
  SiteRule({required String domain, required this.route})
      : domain = normalizeSiteDomain(domain);

  factory SiteRule.fromJson(Map<String, dynamic> json) => SiteRule(
        domain: json['domain'] as String,
        route: SiteRoute.values.byName(json['route'] as String),
      );

  final String domain;
  final SiteRoute route;

  Map<String, dynamic> toJson() => {'domain': domain, 'route': route.name};

  SiteRule copyWith({SiteRoute? route}) =>
      SiteRule(domain: domain, route: route ?? this.route);
}

/// Global site rules live outside subscription profiles.
class SiteRules {
  SiteRules(this.file);

  final File file;
  List<SiteRule>? _rules;

  List<SiteRule> get rules {
    if (_rules == null) {
      if (!file.existsSync()) {
        _rules = [];
      } else {
        final data =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        _rules = [
          for (final item in data['rules'] as List)
            SiteRule.fromJson(item as Map<String, dynamic>),
        ];
      }
    }
    return List.unmodifiable(_rules!);
  }

  void put(SiteRule rule, {String? previousDomain}) {
    final next = [
      for (final item in rules)
        if (previousDomain == null ||
            previousDomain == rule.domain ||
            item.domain != previousDomain)
          item,
    ];
    final index = next.indexWhere((item) => item.domain == rule.domain);
    if (index < 0) {
      next.add(rule);
    } else {
      next[index] = rule;
    }
    _save(next);
  }

  void remove(String domain) =>
      _save(rules.where((rule) => rule.domain != domain).toList());

  void _save(List<SiteRule> next) {
    file.parent.createSync(recursive: true);
    File('${file.path}.tmp')
      ..writeAsStringSync(
        jsonEncode({
          'rules': [for (final rule in next) rule.toJson()],
        }),
        flush: true,
      )
      ..renameSync(file.path);
    _rules = next;
  }
}

final siteRules = SiteRules(
  File(
    join(
      Platform.environment['HOME'] ?? '',
      'Library',
      'Application Support',
      'CustomVPN',
      'site-rules.json',
    ),
  ),
);
