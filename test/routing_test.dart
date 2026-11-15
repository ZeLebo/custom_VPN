import 'dart:convert';
import 'dart:io';

import 'package:flclashx/common/app_rules.dart';
import 'package:flclashx/common/routing.dart';
import 'package:flclashx/common/site_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late AppRules apps;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('custom-vpn-routing-test-');
    apps = AppRules.fromFile(File('${temp.path}/apps.json'));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, dynamic> config() => {
        'find-process-mode': 'off',
        'proxy-groups': [
          {
            'name': 'VPN',
            'type': 'select',
            'proxies': ['node'],
          },
        ],
      };

  List<dynamic> patch({
    List<SiteRule> sites = const [],
    bool enabled = true,
    List<dynamic> profile = const [
      'DOMAIN-SUFFIX,profile.test,DIRECT',
      'MATCH,VPN',
    ],
    Map<String, dynamic>? raw,
  }) =>
      patchRoutingConfig(
        raw ?? config(),
        profile,
        apps: apps,
        sites: sites,
        zapretAvailable: true,
        zapretEnabled: enabled,
      );

  group('URL normalization', () {
    test('removes path, IDs, query, fragment and port; keeps subdomain', () {
      expect(
        normalizeSiteDomain(' https://Shop.Example.com:8443/posts/42?id=7#x '),
        'shop.example.com',
      );
      expect(normalizeSiteDomain('example.com/path/123'), 'example.com');
      expect(normalizeSiteDomain('//www.example.com/'), 'www.example.com');
      expect(normalizeSiteDomain('https://example.com./'), 'example.com');
      expect(
        normalizeSiteDomain('xn--e1afmkfd.xn--p1ai'),
        'xn--e1afmkfd.xn--p1ai',
      );
    });

    test('rejects malformed hosts, IPs, credentials and rule injection', () {
      for (final value in [
        '',
        'localhost',
        'https://',
        'https://127.0.0.1/',
        'https://[::1]/',
        '*.example.com',
        'example.com,DIRECT',
        'https://user:pass@example.com',
        'ftp://example.com/file',
        'https://bad..example.com',
        'https://-bad.example.com',
        'https://bad_.example.com',
      ]) {
        expect(
          () => normalizeSiteDomain(value),
          throwsFormatException,
          reason: value,
        );
      }
    });
  });

  group('stored rules', () {
    test('only-listed survives the first lazy load and a reload', () {
      final file = File('${temp.path}/lazy-apps.json');
      final store = AppRules.fromFile(file)..onlyListed = true;
      expect(store.onlyListed, isTrue);
      expect(store.rules, isEmpty);
      expect(AppRules.fromFile(file).onlyListed, isTrue);
    });

    test('normalizes, updates duplicates, survives reload, and removes', () {
      final file = File('${temp.path}/sites.json');
      SiteRules(file)
        ..put(SiteRule(
            domain: 'https://example.com/a?id=1', route: SiteRoute.direct))
        ..put(SiteRule(domain: 'EXAMPLE.com/b', route: SiteRoute.vpn));
      final reloaded = SiteRules(file);
      expect(reloaded.rules.single.domain, 'example.com');
      expect(reloaded.rules.single.route, SiteRoute.vpn);
      expect(
        (jsonDecode(file.readAsStringSync()) as Map)['rules'],
        hasLength(1),
      );
      reloaded.remove('example.com');
      expect(SiteRules(file).rules, isEmpty);
    });

    test('invalid persisted route does not silently change traffic', () {
      final file = File('${temp.path}/sites.json')
        ..writeAsStringSync(
          '{"rules":[{"domain":"example.com","route":"typo"}]}',
        );
      expect(() => SiteRules(file).rules, throwsArgumentError);
    });
  });

  group('routing precedence', () {
    test('sites and service routes beat the browser VPN rule', () {
      apps.put(
        const AppRule(app: '/Applications/Browser.app', route: AppRoute.vpn),
      );
      final raw = config();
      final result = patch(
        raw: raw,
        sites: [SiteRule(domain: 'example.com', route: SiteRoute.direct)],
      );
      expect(result.first, 'DOMAIN-SUFFIX,example.com,DIRECT');
      final youtube = result.indexOf(
        'DOMAIN-SUFFIX,youtube.com,Zapret YouTube',
      );
      final browser = result.indexOf(
        'PROCESS-PATH-WILDCARD,/Applications/Browser.app/*,VPN',
      );
      expect(youtube, greaterThan(0));
      expect(youtube, lessThan(browser));
      expect(result.last, 'MATCH,VPN');
      expect(raw['find-process-mode'], 'strict');
    });

    test('only-listed preserves sites and both fallback routes', () {
      apps
        ..onlyListed = true
        ..put(const AppRule(app: 'browser', route: AppRoute.direct));
      final raw = config();
      final result = patch(
        raw: raw,
        sites: [SiteRule(domain: 'notion.so', route: SiteRoute.vpn)],
      );
      expect(result.first, 'DOMAIN-SUFFIX,notion.so,VPN');
      expect(result, contains('DOMAIN-SUFFIX,youtube.com,Zapret YouTube'));
      expect(result, contains('DOMAIN-SUFFIX,discord.com,Zapret Discord'));
      expect(result, contains('PROCESS-NAME,browser,DIRECT'));
      expect(result, isNot(contains('DOMAIN-SUFFIX,profile.test,DIRECT')));
      expect(result.last, 'MATCH,DIRECT');
      final groups = raw['proxy-groups'] as List;
      expect(
        (groups.firstWhere((g) => g['name'] == 'Zapret YouTube')
            as Map)['proxies'],
        ['DIRECT', 'VPN'],
      );
    });

    test('most specific domain wins regardless of insertion order', () {
      for (final reverse in [false, true]) {
        final sites = [
          SiteRule(domain: 'example.com', route: SiteRoute.direct),
          SiteRule(domain: 'sub.example.com', route: SiteRoute.zapret),
          SiteRule(domain: 'private.sub.example.com', route: SiteRoute.block),
        ];
        final result = patch(sites: reverse ? sites.reversed.toList() : sites);
        expect(result.take(3), [
          'DOMAIN-SUFFIX,private.sub.example.com,REJECT',
          'DOMAIN-SUFFIX,sub.example.com,Zapret sub.example.com',
          'DOMAIN-SUFFIX,example.com,DIRECT',
        ]);
      }
    });

    test(
      'YouTube preset includes video hosts and allows individual overrides',
      () {
        final result = patch(
          sites: [
            SiteRule(domain: 'youtube.com', route: SiteRoute.vpn),
            SiteRule(domain: 'googlevideo.com', route: SiteRoute.direct),
            SiteRule(
              domain: 'yt3.googleusercontent.com',
              route: SiteRoute.zapret,
            ),
          ],
        );
        expect(result, contains('DOMAIN-SUFFIX,youtube.com,VPN'));
        expect(
          result.where((r) => r == 'DOMAIN-SUFFIX,googlevideo.com,DIRECT'),
          hasLength(1),
        );
        final explicit = result.indexOf(
          'DOMAIN-SUFFIX,yt3.googleusercontent.com,Zapret yt3.googleusercontent.com',
        );
        final conflicting = result.indexOf(
          'DOMAIN,yt3.googleusercontent.com,VPN',
        );
        expect(explicit, greaterThanOrEqualTo(0));
        expect(conflicting, -1);
      },
    );

    test(
      'explicit Zapret site works with the automatic service toggle off',
      () {
        final raw = config();
        final result = patch(
          raw: raw,
          enabled: false,
          sites: [SiteRule(domain: 'youtube.com', route: SiteRoute.zapret)],
        );
        expect(
          result,
          contains('DOMAIN-SUFFIX,googlevideo.com,Zapret YouTube'),
        );
        expect(
          result,
          isNot(contains('DOMAIN-SUFFIX,discord.com,Zapret Discord')),
        );
        expect(
          (raw['proxy-groups'] as List).where(
            (g) => g['name'] == 'Zapret YouTube',
          ),
          hasLength(1),
        );
      },
    );

    test('VPN target is resolved before only-listed replaces MATCH', () {
      apps.onlyListed = true;
      final raw = config();
      patch(raw: raw, profile: ['MATCH,DIRECT']);
      expect((raw['proxy-groups'] as List).last['proxies'], ['DIRECT', 'VPN']);
    });

    test('missing VPN target is an error for an explicit VPN/Zapret site', () {
      for (final route in [SiteRoute.vpn, SiteRoute.zapret]) {
        expect(
          () => patch(
            raw: {},
            profile: ['MATCH,DIRECT'],
            sites: [SiteRule(domain: 'example.com', route: route)],
          ),
          throwsStateError,
        );
      }
    });

    test('app wildcard precedence remains intact', () {
      apps
        ..put(const AppRule(app: 'browser*', route: AppRoute.vpn))
        ..put(const AppRule(app: 'browser-helper', route: AppRoute.direct));
      final result = patch(enabled: false);
      expect(result.take(2), [
        'PROCESS-NAME,browser-helper,DIRECT',
        'PROCESS-NAME-WILDCARD,browser*,VPN',
      ]);
    });
  });

  group('Zapret controller settings', () {
    test('matches the settings fixture consumed by the Go daemon', () {
      final actual = {
        'enabled': true,
        'strategy': 'general-simple-fake',
        'ipset': 'none',
        ...zapretSiteSettings([
          SiteRule(domain: 'example.com', route: SiteRoute.direct),
          SiteRule(domain: 'sub.example.com', route: SiteRoute.zapret),
          SiteRule(domain: 'private.sub.example.com', route: SiteRoute.block),
        ]),
        'vpnServers': ['1.1.1.1'],
      };
      expect(
          actual,
          jsonDecode(File('test/fixtures/zapret_control_settings.json')
              .readAsStringSync()));
    });
    test('shares expanded service domains and explicit host overrides', () {
      final data = zapretSiteSettings([
        SiteRule(domain: 'youtube.com', route: SiteRoute.vpn),
        SiteRule(domain: 'googlevideo.com', route: SiteRoute.direct),
      ]);
      final sites = data['sites'] as List;
      expect(sites.where((s) => s['host'] == 'googlevideo.com').single['route'],
          'direct');
      expect(sites.any((s) => s['host'] == 'ytimg.com'), isTrue);
      expect(data['customHosts'], isEmpty);
    });

    test('keeps nested route order and Discord voice bypass ports', () {
      final data = zapretSiteSettings([
        SiteRule(domain: 'example.com', route: SiteRoute.direct),
        SiteRule(domain: 'sub.example.com', route: SiteRoute.zapret),
        SiteRule(domain: 'private.sub.example.com', route: SiteRoute.block),
        SiteRule(domain: 'discord.com', route: SiteRoute.direct),
      ]);
      final sites = data['sites'] as List;
      final nested = sites
          .where((s) => (s['host'] as String).endsWith('example.com'))
          .toList();
      expect(nested.map((s) => s['host']),
          ['private.sub.example.com', 'sub.example.com', 'example.com']);
      expect(data['customHosts'], ['sub.example.com']);
      expect(
          (data['udpBypassPorts'] as List)
              .any((port) => port['first'] == 50000 && port['last'] == 50100),
          isTrue);
    });
  });
}
