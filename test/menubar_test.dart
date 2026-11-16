import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flclashx/common/common.dart';
import 'package:flclashx/common/native_menu.dart';
import 'package:flclashx/common/theme.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/l10n/l10n.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/views/menubar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ZapretFixture implements Zapret {
  bool running = true;
  Completer<String?>? strategyTest;
  bool testCancelled = false;
  @override
  bool get isAvailable => true;
  @override
  Future<bool> isRunning() async => running;
  @override
  Future<String?> testStrategies() => strategyTest!.future;
  @override
  String get testProgress => '';
  @override
  void cancelTest() {
    testCancelled = true;
    strategyTest!.complete();
  }

  @override
  Future<void> recheckRoutes() async {}
  @override
  ZapretTestReport? get testReport => null;
  @override
  String get strategy => 'general-alt12';
  @override
  String get ipsetMode => 'none';
  @override
  List<ZapretStrategy> get strategies => const [
        ZapretStrategy('general-alt12', 'general (ALT12)'),
        ZapretStrategy('general-simple-fake', 'general-simple-fake'),
      ];
  @override
  bool routingEnabled = false;
  @override
  Map<String, ServicePath> manualRoutes = {
    'YouTube': ServicePath.zapret,
    'Discord': ServicePath.vpn,
  };
  int pathChecks = 0;
  String? lastTarget;
  Completer<Map<String, Map<ServicePath, int?>>>? pending;
  Map<String, Map<ServicePath, int?>> measurements = {
    'YouTube': {ServicePath.zapret: 118, ServicePath.vpn: 165},
    'Discord': {ServicePath.zapret: null, ServicePath.vpn: 153},
  };
  @override
  Future<Map<String, Map<ServicePath, int?>>> checkPaths(String? target) async {
    pathChecks++;
    lastTarget = target;
    if (pending != null) return pending!.future;
    return measurements;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late SiteRules sites;
  late AppRules apps;
  late _ZapretFixture daemon;
  int nodeTests = 0;
  int groupRefreshes = 0;
  List<Group>? refreshedGroups;
  const captureKey = ValueKey('menu-capture');

  setUp(() {
    temp = Directory.systemTemp.createTempSync('customvpn-menu-test-');
    sites = SiteRules(File('${temp.path}/sites.json'));
    apps = AppRules.fromFile(File('${temp.path}/apps.json'));
    daemon = _ZapretFixture();
    nodeTests = 0;
    groupRefreshes = 0;
    refreshedGroups = null;
    globalState.accentColor = const Color(0xffa4d7bd);
    globalState.config = Config(
      themeProps: const ThemeProps(primaryColor: 0xffa4d7bd),
      currentProfileId: 'fixture',
      profiles: [
        Profile(
            id: 'fixture',
            label: 'VLESS',
            autoUpdateDuration: const Duration(days: 1),
            lastUpdateDate: DateTime(2026, 11, 15, 12),
            subscriptionInfo: const SubscriptionInfo(
                download: 46042053836, total: 644245094400, expire: 1800835200))
      ],
    );
    globalState.appState = AppState(
      version: 1,
      viewSize: const Size(375, 600),
      runTime: 123,
      requests: FixedList(10),
      logs: FixedList(10),
      traffics: FixedList(10),
      totalTraffic: Traffic(),
      groups: const [
        Group(
            name: 'Remnawave',
            type: GroupType.Selector,
            now: '🇳🇴 Норвегия',
            hidden: false,
            all: [
              Proxy(name: '🇳🇴 Норвегия', type: 'VLESS'),
              Proxy(name: '🇫🇮 Финляндия', type: 'VLESS'),
              Proxy(name: '🇳🇱 Нидерланды', type: 'VLESS'),
              Proxy(name: '🇩🇪 Германия', type: 'VLESS'),
            ])
      ],
      delayMap: {
        defaultTestUrl: {
          '🇳🇴 Норвегия': 135,
          '🇫🇮 Финляндия': 52,
          '🇳🇱 Нидерланды': 77,
          '🇩🇪 Германия': -1
        }
      },
    );
    globalState.lastRuntimeConfig = {
      'proxy-groups': [
        {
          'name': 'Remnawave',
          'type': 'select',
          'proxies': ['🇳🇴 Норвегия']
        }
      ],
      'rule': [
        'DOMAIN-SUFFIX,app.notion.com,Remnawave',
        'DOMAIN-SUFFIX,2ip.io,DIRECT',
        'DOMAIN-SUFFIX,youtube.com,DIRECT',
        'MATCH,Remnawave'
      ],
    };
    sites.put(SiteRule(domain: '2ip.io', route: SiteRoute.direct));
    sites.put(SiteRule(domain: 'app.notion.com', route: SiteRoute.vpn));
    apps.put(const AppRule(app: 'codex', route: AppRoute.vpn));
  });
  tearDown(() {
    nativeMenu.detach();
    nativeMenu.legacyVisible = false;
    temp.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final font = File('/System/Library/Fonts/SFNS.ttf');
      if (font.existsSync()) {
        for (final name in [
          'Roboto',
          '.SF Pro Text',
          '.SF Pro Display',
          'CupertinoSystemText',
          'CupertinoSystemDisplay',
          '.AppleSystemUIFont'
        ]) {
          final loader = FontLoader(name)
            ..addFont(
                Future.value(ByteData.sublistView(font.readAsBytesSync())));
          await loader.load();
        }
      }
    });
    await tester.runAsync(() async {
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
    });
    await tester.pumpWidget(ProviderScope(
        overrides: [
          menuZapretProvider.overrideWithValue(daemon),
          menuSitesProvider.overrideWithValue(sites),
          menuAppsProvider.overrideWithValue(apps),
          menuNodeTesterProvider.overrideWithValue((_, __) async {
            nodeTests++;
          }),
          menuGroupRefresherProvider.overrideWith((ref) => () async {
                groupRefreshes++;
                if (refreshedGroups != null) {
                  ref.read(groupsProvider.notifier).value = refreshedGroups!;
                }
              }),
        ],
        child: RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              navigatorObservers: [NativeMenuNavigationObserver()],
              debugShowCheckedModeBanner: false,
              theme: ThemeData(platform: TargetPlatform.macOS),
              locale: const Locale('ru'),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate
              ],
              supportedLocales: const [Locale('ru')],
              home: Builder(builder: (context) {
                globalState.measure = Measure.of(context, 1);
                globalState.theme = CommonTheme.of(context, 1);
                return const MenubarView();
              }),
            ))));
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('MENU_SCREENSHOTS')) return;
    await tester.runAsync(() async {
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/menubar-preview/$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final width in [375.0, 320.0]) {
    testWidgets('five compact pages keep working at ${width.toInt()}px',
        (tester) async {
      await mount(tester, width);
      expect(find.text('Остановить VPN'), findsOneWidget);
      final nav = find.byKey(const ValueKey('menu-nav-dashboard'));
      expect(tester.getTopLeft(nav).dy, lessThan(80));
      for (final page in [
        PageLabel.dashboard,
        PageLabel.proxies,
        PageLabel.zapret,
        PageLabel.routing,
        PageLabel.tools
      ]) {
        await tester.tap(find.byKey(ValueKey('menu-nav-${page.name}')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: page.name);
        if (width == 375) await capture(tester, page.name);
      }
      expect(nodeTests, greaterThan(0));
      await tester.tap(find.byKey(const ValueKey('menu-nav-routing')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Проверить пинг напрямую и через VPN'));
      await tester.pumpAndSettle();
      expect(daemon.pathChecks, 1);
      expect(daemon.lastTarget, 'Remnawave');
      expect(daemon.manualRoutes,
          {'YouTube': ServicePath.zapret, 'Discord': ServicePath.vpn});
      expect(find.text('118 мс'), findsOneWidget);
      expect(find.text('165 мс'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (width == 375) await capture(tester, 'routing-ping');
      await tester.tap(find.text('Все правила'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'notion');
      await tester.pumpAndSettle();
      expect(find.text('Найдено: 1 из 4'), findsOneWidget);
      expect(find.text('app.notion.com'), findsOneWidget);
      if (width == 375) await capture(tester, 'all-rules');
      await tester.tap(find.byKey(const ValueKey('menu-nav-routing')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Проверить пинг напрямую и через VPN'),
          findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('menu-nav-dashboard')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('VLESS'));
      await tester.pumpAndSettle();
      expect(find.text('Обновить все'), findsOneWidget);
      expect(find.text('Управление'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (width == 375) await capture(tester, 'profiles');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('VPN uptime updates while connected and clears after stopping',
      (tester) async {
    globalState.appState = globalState.appState.copyWith(runTime: 3723000);
    await mount(tester, 375);
    expect(find.text('01:02:03'), findsOneWidget);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MenubarView)));
    container.read(runTimeProvider.notifier).value = 3724000;
    await tester.pump();
    expect(find.text('01:02:04'), findsOneWidget);
    expect(find.text('01:02:03'), findsNothing);
    container.read(runTimeProvider.notifier).value = null;
    await tester.pump();
    expect(find.text('01:02:04'), findsNothing);
    expect(find.text('Включить VPN'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [375.0, 320.0]) {
    testWidgets('service ping stays inline at ${width.toInt()}px',
        (tester) async {
      daemon.measurements = {
        'YouTube': {ServicePath.zapret: 1061, ServicePath.vpn: 327},
        'Discord': {ServicePath.zapret: 797, ServicePath.vpn: 464},
      };
      await mount(tester, width);
      await tester.tap(find.byKey(const ValueKey('menu-nav-routing')));
      await tester.pumpAndSettle();
      final button = find.widgetWithText(OutlinedButton, 'Zapret').first;
      final before = tester.getRect(button);
      await tester.tap(find.byTooltip('Проверить пинг напрямую и через VPN'));
      await tester.pumpAndSettle();
      final label = tester.getCenter(
          find.descendant(of: button, matching: find.text('Zapret')));
      final ping = tester.getCenter(find.text('1061 мс'));
      expect(
          tester
              .renderObject<RenderParagraph>(
                  find.descendant(of: button, matching: find.text('Zapret')))
              .didExceedMaxLines,
          isFalse);
      expect(ping.dy, closeTo(label.dy, 1));
      expect(ping.dx, greaterThan(label.dx));
      expect(tester.getRect(button).height, closeTo(before.height, .1));
      expect(tester.takeException(), isNull);
      await capture(tester, 'inline-ping-${width.toInt()}');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('automatic route is refreshed immediately after service probes',
      (tester) async {
    daemon.routingEnabled = true;
    const automatic = Group(
      name: 'Zapret YouTube',
      type: GroupType.Fallback,
      now: 'Remnawave',
      hidden: true,
      all: [
        Proxy(name: 'DIRECT', type: 'Direct'),
        Proxy(name: 'Remnawave', type: 'Selector')
      ],
    );
    final groups = globalState.appState.groups;
    globalState.appState =
        globalState.appState.copyWith(groups: [...groups, automatic]);
    refreshedGroups = [...groups, automatic.copyWith(now: 'DIRECT')];
    await mount(tester, 375);
    await tester.tap(find.byKey(const ValueKey('menu-nav-routing')));
    await tester.pumpAndSettle();
    final button = find.widgetWithText(OutlinedButton, 'Zapret').first;
    final semantics =
        find.ancestor(of: button, matching: find.byType(Semantics)).first;
    expect(tester.widget<Semantics>(semantics).properties.selected, isFalse);
    await tester.tap(find.byTooltip('Проверить пинг напрямую и через VPN'));
    await tester.pumpAndSettle();
    expect(groupRefreshes, 1);
    expect(tester.widget<Semantics>(semantics).properties.selected, isTrue);
    expect(daemon.manualRoutes,
        {'YouTube': ServicePath.zapret, 'Discord': ServicePath.vpn});
    expect(tester.takeException(), isNull);
    await capture(tester, 'automatic-ping');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'site editor saves normalized URLs and edits the same stored rule',
      (tester) async {
    globalState.config = const Config(themeProps: defaultThemeProps);
    await mount(tester, 375);
    await tester.tap(find.byKey(const ValueKey('menu-nav-routing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Добавить сайт'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField), 'https://docs.example.com/path?id=1');
    await tester.pump();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(sites.rules.last.domain, 'docs.example.com');
    await tester.ensureVisible(find.text('docs.example.com'));
    await tester.tap(find.text('docs.example.com'));
    await tester.pumpAndSettle();
    expect(find.text('Изменить маршрут'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'help.example.com');
    await tester.pump();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(sites.rules.where((r) => r.domain == 'docs.example.com'), isEmpty);
    expect(sites.rules.last.domain, 'help.example.com');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'opening VPN pings every group; service probes use the real rule target',
      (tester) async {
    globalState.appState = globalState.appState.copyWith(delayMap: {
      ...globalState.appState.delayMap,
      'https://example.invalid/check': {'inactive-node': 91},
    }, groups: [
      ...globalState.appState.groups,
      const Group(
          name: 'SERVERS',
          type: GroupType.Selector,
          hidden: false,
          testUrl: 'https://example.invalid/check',
          all: [Proxy(name: 'inactive-node', type: 'VLESS')]),
    ]);
    globalState.lastRuntimeConfig!['rule'] = ['MATCH,🇳🇴 Норвегия'];
    await mount(tester, 375);
    await tester.tap(find.byKey(const ValueKey('menu-nav-proxies')));
    await tester.pumpAndSettle();
    expect(nodeTests, 2);
    expect(find.text('91 мс'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-nav-routing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Проверить пинг напрямую и через VPN'));
    await tester.pumpAndSettle();
    expect(daemon.lastTarget, '🇳🇴 Норвегия');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'strategy testing starts while stopped and keeps cancellation available',
      (tester) async {
    globalState.config = const Config(themeProps: defaultThemeProps);
    daemon.running = false;
    daemon.strategyTest = Completer<String?>();
    await mount(tester, 375);
    await tester.tap(find.byKey(const ValueKey('menu-nav-zapret')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Проверить все стратегии'));
    await tester.pump();
    expect(find.text('Остановить проверку'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Остановить проверку'));
    await tester.pumpAndSettle();
    expect(daemon.testCancelled, isTrue);
    expect(find.text('Проверить все стратегии'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'a late ping result cannot overwrite measurements after a server change',
      (tester) async {
    daemon.pending = Completer<Map<String, Map<ServicePath, int?>>>();
    await mount(tester, 375);
    await tester.tap(find.byKey(const ValueKey('menu-nav-routing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Проверить пинг напрямую и через VPN'));
    await tester.pump();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MenubarView)));
    container.read(profilesProvider.notifier).updateProfile('fixture',
        (p) => p.copyWith(selectedMap: {'Remnawave': '🇫🇮 Финляндия'}));
    await tester.pump();
    daemon.pending!.complete({
      'YouTube': {ServicePath.zapret: 118, ServicePath.vpn: 165},
      'Discord': {ServicePath.zapret: 123, ServicePath.vpn: 153}
    });
    await tester.pumpAndSettle();
    expect(find.text('118 мс'), findsNothing);
    expect(find.text('165 мс'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<Map<String, dynamic>> nativeCall(String method,
      [Map<String, Object?>? args]) async {
    const codec = StandardMethodCodec();
    final response = Completer<ByteData?>();
    // Exercise the real native-to-Dart MethodChannel handler.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            NativeMenuChannel.channel.name,
            codec.encodeMethodCall(MethodCall(method, args)),
            response.complete);
    return Map<String, dynamic>.from(
        codec.decodeEnvelope((await response.future)!) as Map);
  }

  testWidgets('native menu uses real state, actions and legacy presentation',
      (tester) async {
    final published = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeMenuChannel.channel, (call) async {
      published.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeMenuChannel.channel, null));
    await mount(tester, 375);
    final element = tester.element(find.byType(MenubarView));
    final container = ProviderScope.containerOf(element);
    container.read(initProvider.notifier).value = true;
    var state = await nativeCall('attach');
    expect(state['initialized'], isTrue);
    expect(state['protocolVersion'], 1);
    expect(state['profiles'][0]['name'], 'VLESS');
    expect(state['groups'][0]['servers'][0]['name'], '🇳🇴 Норвегия');
    expect(state['groups'][0]['servers'][0]['delay'], 135);
    expect(state['runtimeRules'], hasLength(4));
    expect(state['routes'][0]['paths'][0]['selected'], isTrue);
    expect(state['sites'], hasLength(2));
    await nativeCall('action', {'action': 'navigate', 'value': 'vpn'});
    await tester.pumpAndSettle();
    state = await nativeCall('state');
    expect(state['page'], 'vpn');
    expect(nodeTests, 1);
    // Core/profile actions still use this scaffold's loadingRun gate.
    expect(globalState.homeScaffoldKey.currentState?.mounted, isTrue);
    expect(find.text('Остановить VPN'), findsNothing);

    await expectLater(nativeCall('action', {'action': 'vpn'}),
        throwsA(isA<PlatformException>()));
    await expectLater(
        nativeCall('action',
            {'action': 'saveSite', 'name': 'not a domain', 'value': 'vpn'}),
        throwsA(isA<PlatformException>()));
    expect(sites.rules, hasLength(2));

    daemon.pending = Completer();
    state = await nativeCall('action', {'action': 'pingRoutes'});
    expect(state['routeBusy'], isTrue);
    state = await nativeCall('action', {'action': 'pingRoutes'});
    expect(state['routeBusy'], isFalse);
    daemon.pending!.complete(daemon.measurements);
    await tester.pumpAndSettle();
    state = await nativeCall('state');
    expect(state['routes'][0]['paths'][0]['result'], '—');
    daemon.pending = null;
    await nativeCall('action', {'action': 'pingRoutes'});
    await tester.pumpAndSettle();
    state = await nativeCall('state');
    expect(state['routes'][0]['paths'][0]['result'], '118 мс');
    expect(state['routes'][1]['paths'][0]['result'], 'Тайм-аут');

    final navigator = Navigator.of(element);
    unawaited(navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Legacy editor')))));
    await tester.pumpAndSettle();
    expect((await nativeCall('state'))['legacyVisible'], isTrue);
    navigator.pop();
    await tester.pumpAndSettle();
    expect((await nativeCall('state'))['legacyVisible'], isFalse);
    expect(published.any((c) => c.method == 'legacyVisible'), isTrue);

    await nativeCall('action', {'action': 'navigate', 'value': 'home'});
    state = await nativeCall('state');
    // The native contract/render check consumes this controller-generated data.
    final fixture = File('build/native-menu-fixture.json');
    fixture.parent.createSync(recursive: true);
    fixture.writeAsStringSync(jsonEncode(state));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  test('startup page and accent survive config serialization', () {
    final encoded = jsonEncode(globalState.config
        .copyWith(
          appSetting: globalState.config.appSetting
              .copyWith(menubarStartPage: PageLabel.routing),
          themeProps:
              globalState.config.themeProps.copyWith(primaryColor: 0xfff2b078),
        )
        .toJson());
    final restored =
        Config.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
    expect(restored.appSetting.menubarStartPage, PageLabel.routing);
    expect(restored.themeProps.primaryColor, 0xfff2b078);
  });
}
