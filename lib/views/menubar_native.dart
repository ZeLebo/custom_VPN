part of 'menubar.dart';

const _nativePages = {
  PageLabel.dashboard: 'home',
  PageLabel.proxies: 'vpn',
  PageLabel.zapret: 'zapret',
  PageLabel.routing: 'routes',
  PageLabel.tools: 'settings',
};

extension _NativeMenuController on _MenubarViewState {
  void _scheduleNativeState() {
    if (!nativeMenu.attached || _nativeStateScheduled) return;
    _nativeStateScheduled = true;
    scheduleMicrotask(() async {
      _nativeStateScheduled = false;
      if (!mounted || !nativeMenu.attached) return;
      try {
        await nativeMenu.publish('state', _nativeSnapshot());
      } catch (error) {
        debugPrint('Native menu state: $error');
      }
    });
  }

  Map<String, Object?> _nativeProfile(Profile profile) {
    final info = profile.subscriptionInfo;
    final limited = info != null && info.total > 0;
    return {
      'id': profile.id,
      'name': profile.label ?? profile.id,
      'updating': profile.isUpdating,
      'usage': limited
          ? '${TrafficValue(value: info.upload + info.download).show} / ${TrafficValue(value: info.total).show}'
          : null,
      'fraction': limited
          ? ((info.upload + info.download) / info.total).clamp(0, 1)
          : null,
      'expires': info == null || info.expire == 0
          ? 'Без срока действия'
          : 'До ${DateFormat('dd.MM.yyyy').format(DateTime.fromMillisecondsSinceEpoch(info.expire * 1000))}',
      'updated': profile.lastUpdateDate == null
          ? null
          : DateFormat('dd.MM HH:mm').format(profile.lastUpdateDate!),
    };
  }

  Map<String, Object?> _nativeSnapshot() {
    final config = ref.read(patchClashConfigProvider);
    final app = ref.read(appSettingProvider);
    final theme = ref.read(themeSettingProvider);
    final runTime = ref.read(runTimeProvider);
    final rawRules = globalState.lastRuntimeConfig?['rule'] as List? ?? [];
    return {
      'protocolVersion': 1,
      'revision': nativeMenu.nextRevision(),
      'initialized': ref.read(initProvider),
      'legacyVisible': nativeMenu.legacyVisible,
      'page': _nativePages[ref.read(currentPageLabelProvider)] ?? 'home',
      'vpnRunning': _vpnRunning,
      'vpnBusy': _vpnBusy,
      'elapsed': runTime == null ? '' : utils.getTimeText(runTime),
      'zapretAvailable': _zapret.isAvailable,
      'zapretKnown': _knownZapret,
      'zapretRunning': _zapretRunning,
      'zapretBusy': _zapretBusy,
      'mode': config.mode.name,
      'systemProxy': ref.read(networkSettingProvider).systemProxy,
      'tun': config.tun.enable,
      'automatic': _zapret.routingEnabled,
      'rulesBusy': _applyingRules,
      'routeBusy': _routePinging,
      'nodeBusy': _nodePinging,
      'checking': _checking,
      'testing': _testing,
      'progress': _progress,
      'strategy': _zapret.strategy,
      'strategyTitle': _strategyTitle,
      'ipset': _zapret.ipsetMode,
      'strategies': [
        for (final s in _zapret.strategies) {'id': s.id, 'name': s.title}
      ],
      'scores': [
        for (final e in _report?.scores.entries ?? <MapEntry<String, String>>[])
          {'name': e.key, 'score': e.value}
      ],
      'best': _report?.best ?? <String>[],
      'checks': [
        for (final service in zapretRoutes)
          {
            'name': service.name,
            'result': !_zapretRunning
                ? 'Сервис выключен'
                : _checking
                    ? 'Проверяю…'
                    : _checks == null
                        ? 'Не проверен'
                        : _checks![service.name] == null
                            ? 'Тайм-аут'
                            : '${_checks![service.name]} мс'
          }
      ],
      'currentProfileId': ref.read(currentProfileProvider)?.id,
      'profiles': [
        for (final p in ref.read(profilesProvider)) _nativeProfile(p)
      ],
      'groups': [
        for (final group in _vpnGroups)
          {
            'id': group.name,
            'selectable': group.type == GroupType.Selector,
            'servers': [
              for (final node in group.all)
                {
                  'name': node.name,
                  'type': node.type,
                  'selected':
                      (ref.read(getSelectedProxyNameProvider(group.name)) ??
                              group.realNow) ==
                          node.name,
                  'delay': ref.read(getDelayProvider(
                      proxyName: node.name, testUrl: group.testUrl)),
                }
            ]
          }
      ],
      'routes': [
        for (final service in zapretRoutes)
          {
            'name': service.name,
            'paths': [
              for (final path in ServicePath.values)
                {
                  'id': path.name,
                  'name': path == ServicePath.vpn ? 'VPN' : 'Zapret',
                  'available': path == ServicePath.zapret
                      ? _zapretRunning
                      : _vpnRunning && _vpnTarget != null,
                  'selected': _pathFor(service) == path,
                  'selectable': (path == ServicePath.zapret
                          ? _zapretRunning
                          : _vpnRunning && _vpnTarget != null) &&
                      config.mode == Mode.rule &&
                      !_zapret.routingEnabled &&
                      !_applyingRules,
                  'result': (path == ServicePath.vpn
                          ? !_vpnRunning
                          : !_zapretRunning)
                      ? 'Выкл.'
                      : _routePinging
                          ? '…'
                          : _routeChecks == null
                              ? '—'
                              : _routeChecks![service.name]?[path] == null
                                  ? 'Тайм-аут'
                                  : '${_routeChecks![service.name]![path]} мс',
                }
            ]
          }
      ],
      'sites': [
        for (final rule in _sites.rules)
          {
            'id': rule.domain,
            'name': rule.domain,
            'route': rule.route.name,
            'target': rule.route.label
          }
      ],
      'apps': [
        for (final rule in _apps.rules)
          {
            'id': rule.app,
            'name': rule.name,
            'route': rule.route.name,
            'target': rule.route.label
          }
      ],
      'onlyListed': _apps.onlyListed,
      'runtimeRules': [
        for (final item in rawRules)
          if (RuntimeRule.parse('$item') case final rule)
            {
              'name': rule.payload.isEmpty ? 'Остальной трафик' : rule.payload,
              'type': rule.type,
              'target': rule.target
            }
      ],
      'accent': theme.primaryColor,
      'appearance': theme.themeMode.name,
      'autoLaunch': app.autoLaunch,
      'startPage': _nativePages[app.menubarStartPage] ?? 'home',
    };
  }

  Future<Object?> _handleNativeMenu(MethodCall call) async {
    try {
      switch (call.method) {
        case 'attach':
        case 'state':
          return _nativeSnapshot();
        case 'opened':
          if (ref.read(initProvider) &&
              ref.read(currentPageLabelProvider) == PageLabel.proxies) {
            unawaited(_pingNodes());
          }
          return _nativeSnapshot();
        case 'action':
          if (!ref.read(initProvider)) {
            throw StateError('Приложение ещё запускается');
          }
          await _nativeAction(Map<String, dynamic>.from(call.arguments as Map));
          return _nativeSnapshot();
        default:
          throw MissingPluginException(
              'Unknown native menu method: ${call.method}');
      }
    } catch (error) {
      throw PlatformException(code: 'MENU_ACTION', message: error.toString());
    }
  }

  Future<void> _nativeAction(Map<String, dynamic> args) async {
    final action = args['action'] as String;
    final value = args['value'];
    switch (action) {
      case 'navigate':
        _navigate(_nativePages.entries.firstWhere((e) => e.value == value).key);
      case 'vpn':
        final enabled = value as bool;
        if (enabled != _vpnRunning) {
          await _toggleVpn();
        }
      case 'zapret':
        final enabled = value as bool;
        if (!_zapret.isAvailable || !_knownZapret || _testing) {
          throw StateError('Zapret недоступен');
        }
        if (enabled != _zapretRunning) {
          unawaited(_runZapret(enabled ? _zapret.start : _zapret.stop));
        }
      case 'mode':
        globalState.appController
            .changeMode(Mode.values.byName(value as String));
      case 'systemProxy':
        ref
            .read(networkSettingProvider.notifier)
            .updateState((s) => s.copyWith(systemProxy: value as bool));
      case 'tun':
        ref
            .read(patchClashConfigProvider.notifier)
            .updateState((s) => s.copyWith.tun(enable: value as bool));
      case 'automatic':
        await _changeRouting(() => _zapret.routingEnabled = value as bool);
      case 'route':
        final service =
            zapretRoutes.firstWhere((s) => s.name == args['service']);
        final path = ServicePath.values.byName(value as String);
        final available = path == ServicePath.zapret
            ? _zapretRunning
            : _vpnRunning && _vpnTarget != null;
        if (!available ||
            _zapret.routingEnabled ||
            ref.read(patchClashConfigProvider).mode != Mode.rule) {
          throw StateError('Этот путь сейчас недоступен');
        }
        await _changeRouting(() => _zapret.setManualRoute(service.name, path));
      case 'pingRoutes':
        if (_routePinging) {
          setState(() {
            _routeCheckEpoch++;
            _routePinging = false;
            _routeChecks = null;
          });
        } else {
          unawaited(_pingRoutes());
        }
      case 'pingNodes':
        unawaited(_pingNodes());
      case 'server':
        final group = _vpnGroups.firstWhere((g) => g.name == args['group']);
        if (group.type != GroupType.Selector) {
          throw StateError('Группа выбирает сервер автоматически');
        }
        await _selectNode(group, group.all.firstWhere((n) => n.name == value));
      case 'profile':
        final profile =
            ref.read(profilesProvider).firstWhere((p) => p.id == value);
        _pendingPingProfile = profile.id;
        ref.read(currentProfileIdProvider.notifier).value = profile.id;
      case 'updateProfile':
        await _updateProfile(
            ref.read(profilesProvider).firstWhere((p) => p.id == value));
      case 'updateAll':
        await globalState.appController.updateProfiles();
        await _pingNodes();
      case 'strategy':
        final strategy = _zapret.strategies.firstWhere((s) => s.id == value);
        unawaited(_runZapret(() => _zapret.setStrategy(strategy.id)));
      case 'ipset':
        if (!Zapret.ipsetModes.contains(value)) {
          throw const FormatException('Неизвестный режим IPSet');
        }
        unawaited(_runZapret(() => _zapret.setIpsetMode(value as String)));
      case 'testStrategies':
        unawaited(_testStrategies());
      case 'checkConnections':
        if (_checking) {
          setState(() {
            _routeCheckEpoch++;
            _checking = false;
            _checks = null;
          });
        } else {
          unawaited(_checkConnections());
        }
      case 'openLists':
        await Process.run('/usr/bin/open', [_zapret.listsPath]);
      case 'applyLists':
        unawaited(_runZapret(_zapret.reload));
      case 'updateStrategies':
        final result = await _zapret.updateStrategies();
        _notify(result);
      case 'saveSite':
        final rule = SiteRule(
            domain: args['name'] as String,
            route: SiteRoute.values.byName(value as String));
        await _changeRouting(() =>
            _sites.put(rule, previousDomain: args['previous'] as String?));
      case 'deleteSite':
        await _changeRouting(() => _sites.remove(value as String));
      case 'saveApp':
        final name = (args['name'] as String).trim();
        if (name.isEmpty ||
            name.contains(',') ||
            ((name.contains('*') || name.contains('?')) &&
                isTooBroadPattern(name))) {
          throw const FormatException('Уточните имя, путь или шаблон процесса');
        }
        final expanded = name.startsWith('~/')
            ? '${Platform.environment['HOME']}/${name.substring(2)}'
            : name;
        final rule = AppRule(
            app: expanded, route: AppRoute.values.byName(value as String));
        await _changeRouting(() => _apps.put(rule));
      case 'deleteApp':
        await _changeRouting(() => _apps.remove(value as String));
      case 'onlyListed':
        await _changeRouting(() => _apps.onlyListed = value as bool);
      case 'applyRules':
        await _changeRouting(() {});
      case 'accent':
        if (!MenubarStyle.accents.values.any((c) => c.toARGB32() == value)) {
          throw const FormatException('Неизвестный акцентный цвет');
        }
        ref
            .read(themeSettingProvider.notifier)
            .updateState((s) => s.copyWith(primaryColor: value as int));
      case 'appearance':
        ref.read(themeSettingProvider.notifier).updateState((s) =>
            s.copyWith(themeMode: ThemeMode.values.byName(value as String)));
      case 'autoLaunch':
        ref
            .read(appSettingProvider.notifier)
            .updateState((s) => s.copyWith(autoLaunch: value as bool));
      case 'startPage':
        final page =
            _nativePages.entries.firstWhere((e) => e.value == value).key;
        ref
            .read(appSettingProvider.notifier)
            .updateState((s) => s.copyWith(menubarStartPage: page));
      case 'addProfile':
        _addProfile();
      case 'manageProfiles':
        _open('Профили', const ProfilesView(standalone: true));
      case 'allSettings':
        _open('Все настройки', const ToolsView());
      case 'addApps':
        unawaited(_addApp());
      default:
        throw ArgumentError('Unknown native menu action: $action');
    }
    _scheduleNativeState();
  }
}
