import 'app_rules.dart';
import 'site_rules.dart';

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

ZapretRoute? _serviceFor(String domain) {
  if (domain == 'youtube.com' || domain == 'youtu.be') return zapretRoutes[0];
  if (domain == 'discord.com' ||
      domain == 'discord.gg' ||
      domain == 'discord.app') {
    return zapretRoutes[1];
  }
  return null;
}

String zapretGroupForDomain(String domain) =>
    _serviceFor(domain)?.group ?? 'Zapret $domain';

// Expand service presets first; explicit rules for their individual hosts win.
List<({String payload, SiteRule rule})> _siteEntries(List<SiteRule> sites) {
  final entries = <String, SiteRule>{};
  for (final site in sites) {
    final service = _serviceFor(site.domain);
    if (service != null) {
      for (final payload in service.rules) {
        entries[payload] = site;
      }
    }
  }
  for (final site in sites) {
    entries.remove('DOMAIN,${site.domain}');
    entries['DOMAIN-SUFFIX,${site.domain}'] = site;
  }
  return [
    for (final entry in entries.entries)
      (payload: entry.key, rule: entry.value),
  ]..sort((a, b) {
      final aParts = a.payload.split(',');
      final bParts = b.payload.split(',');
      if (aParts.first == 'AND') return bParts.first == 'AND' ? 0 : 1;
      if (bParts.first == 'AND') return -1;
      final specificity =
          bParts[1].split('.').length.compareTo(aParts[1].split('.').length);
      if (specificity != 0) return specificity;
      final host = aParts[1].compareTo(bParts[1]);
      if (host != 0) return host;
      return aParts.first.compareTo(bParts.first);
    });
}

/// Builds every routing layer in one place, before the catch-all can hide it.
List<dynamic> patchRoutingConfig(
  Map<String, dynamic> rawConfig,
  List<dynamic> profileRules, {
  required AppRules apps,
  required List<SiteRule> sites,
  required bool zapretAvailable,
  required bool zapretEnabled,
}) {
  final vpnTarget = vpnTargetFor(rawConfig, profileRules);
  final groups = List<dynamic>.from(rawConfig['proxy-groups'] as List? ?? []);
  final generated = <String>{};
  void addFallback(String name, String url) {
    if (!generated.add(name)) return;
    if (groups.any((group) => group is Map && group['name'] == name)) {
      throw StateError('Имя группы «$name» уже занято в профиле');
    }
    groups.add({
      'name': name,
      'type': 'fallback',
      'proxies': ['DIRECT', vpnTarget],
      'url': url,
      'interval': 300,
      'timeout': 3000,
      'lazy': false,
    });
  }

  final serviceRules = <String>[];
  if (zapretAvailable && zapretEnabled && vpnTarget != null) {
    for (final service in zapretRoutes) {
      addFallback(service.group, service.testUrl);
      serviceRules.addAll(
        service.rules.map((rule) => '$rule,${service.group}'),
      );
    }
  }
  final siteRules = <String>[];
  for (final entry in _siteEntries(sites)) {
    final site = entry.rule;
    if ((site.route == SiteRoute.vpn || site.route == SiteRoute.zapret) &&
        vpnTarget == null) {
      throw StateError('В профиле нет VPN-группы для ${site.domain}');
    }
    if (site.route == SiteRoute.zapret) {
      if (!zapretAvailable) {
        throw StateError('Zapret недоступен для ${site.domain}');
      }
      final service = _serviceFor(site.domain);
      addFallback(
        zapretGroupForDomain(site.domain),
        service?.testUrl ?? 'https://${site.domain}/',
      );
    }
    final target = switch (site.route) {
      SiteRoute.vpn => vpnTarget!,
      SiteRoute.direct => 'DIRECT',
      SiteRoute.block => 'REJECT',
      SiteRoute.zapret => zapretGroupForDomain(site.domain),
    };
    siteRules.add('${entry.payload},$target');
  }
  rawConfig['proxy-groups'] = groups;
  return [
    ...siteRules,
    ...serviceRules,
    ...apps.patchConfig(rawConfig, profileRules),
  ];
}

/// Data for the root controller. Service expansion is shared with VPN routing.
Map<String, dynamic> zapretSiteSettings(List<SiteRule> sites) {
  final entries = _siteEntries(sites);
  return {
    'sites': [
      for (final entry in entries)
        if (entry.payload.startsWith('DOMAIN'))
          {
            'host': entry.payload.split(',')[1],
            'exact': entry.payload.startsWith('DOMAIN,'),
            'route': entry.rule.route.name,
          },
    ],
    'customHosts': [
      for (final site in sites)
        if (site.route == SiteRoute.zapret && _serviceFor(site.domain) == null)
          site.domain,
    ],
    'udpBypassPorts': [
      for (final entry in entries)
        if (entry.payload.startsWith('AND,') &&
            entry.rule.route != SiteRoute.zapret)
          {
            'first': int.parse(RegExp(r'DST-PORT,([0-9]+)-([0-9]+)')
                .firstMatch(entry.payload)![1]!),
            'last': int.parse(RegExp(r'DST-PORT,([0-9]+)-([0-9]+)')
                .firstMatch(entry.payload)![2]!),
          },
    ],
  };
}
