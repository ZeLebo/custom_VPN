import 'dart:async';
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/common/native_menu.dart';
import 'package:flclashx/common/processes.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/views/profiles/add_profile.dart';
import 'package:flclashx/views/profiles/profiles.dart';
import 'package:flclashx/views/proxies/app_picker.dart';
import 'package:flclashx/views/proxies/common.dart';
import 'package:flclashx/views/proxies/section.dart';
import 'package:flclashx/views/proxies/site_rule_dialog.dart';
import 'package:flclashx/views/tools.dart';
import 'package:flclashx/widgets/menubar.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

part 'menubar_native.dart';

// These bindings also let widget tests render the real screens without native
// services, the user's rule files, or network requests.
final menuZapretProvider = Provider<Zapret>((ref) => zapret);
final menuSitesProvider = Provider<SiteRules>((ref) => siteRules);
final menuAppsProvider = Provider<AppRules>((ref) => appRules);
final menuNodeTesterProvider =
    Provider<Future<void> Function(List<Proxy>, String?)>((ref) => delayTest);
final menuGroupRefresherProvider = Provider<Future<void> Function()>(
  (ref) => () => globalState.appController.updateGroups(),
);

class MenubarView extends ConsumerWidget {
  const MenubarView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raw = ref.watch(themeSettingProvider.select((s) => s.primaryColor));
    final color = MenubarStyle.accents.values
            .where((c) => c.toARGB32() == raw)
            .firstOrNull ??
        Theme.of(context).colorScheme.primary;
    return Theme(
      data: MenubarStyle.theme(Theme.of(context), color),
      child: const _MenubarBody(),
    );
  }
}

class _MenubarBody extends ConsumerStatefulWidget {
  const _MenubarBody();

  @override
  ConsumerState<_MenubarBody> createState() => _MenubarViewState();
}

class _MenubarViewState extends ConsumerState<_MenubarBody> {
  static const _destinations = [
    (PageLabel.dashboard, 'Главная', Icons.home_outlined),
    (PageLabel.proxies, 'VPN', Icons.language_rounded),
    (PageLabel.zapret, 'Zapret', Icons.shield_outlined),
    (PageLabel.routing, 'Маршруты', Icons.alt_route_rounded),
    (PageLabel.tools, 'Настройки', Icons.settings_outlined),
  ];
  Timer? _timer;
  bool _polling = false;
  bool _knownZapret = false;
  bool _zapretRunning = false;
  bool _zapretBusy = false;
  bool _vpnBusy = false;
  bool _testing = false;
  bool _checking = false;
  bool _routePinging = false;
  bool _nodePinging = false;
  bool _applyingRules = false;
  bool _showAllRules = false;
  bool _profilesOpen = false;
  bool _nativeStateScheduled = false;
  String _query = '';
  String _progress = '';
  String? _probeSettings;
  String? _pendingPingProfile;
  int _routeCheckEpoch = 0;
  ZapretTestReport? _report;
  Map<String, int?>? _checks;
  Map<String, Map<ServicePath, int?>>? _routeChecks;

  Zapret get _zapret => ref.read(menuZapretProvider);
  SiteRules get _sites => ref.read(menuSitesProvider);
  AppRules get _apps => ref.read(menuAppsProvider);
  bool get _vpnRunning => ref.read(runTimeProvider) != null;

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS) nativeMenu.listen(_handleNativeMenu);
    _report = _zapret.testReport;
    unawaited(_refreshZapret());
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshZapret(),
    );
    ref.listenManual(
        currentProfileProvider
            .select((p) => (p?.id, p?.selectedMap, p?.lastUpdateDate)),
        (previous, next) {
      _invalidateChecks();
      if (previous?.$1 != next.$1) _pendingPingProfile = next.$1;
    });
    ref.listenManual(runTimeProvider.select((time) => time != null),
        (_, __) => _invalidateChecks());
    ref.listenManual(patchClashConfigProvider.select((config) => config.mode),
        (_, __) => _invalidateChecks());
    ref.listenManual(groupsProvider, (_, next) {
      final profileId = ref.read(currentProfileProvider)?.id;
      if (_pendingPingProfile == profileId && next.isNotEmpty) {
        _pendingPingProfile = null;
        unawaited(_pingNodes());
      }
    });
    ref.listenManual(currentPageLabelProvider, (_, next) {
      if (next == PageLabel.proxies) {
        if (mounted) unawaited(_pingNodes());
      }
      if (mounted) {
        setState(() {
          _showAllRules = false;
          _query = '';
        });
      }
    });
    ref.listenManual(proxiesSectionProvider, (_, next) {
      if (next == ProxiesSection.profiles) {
        if (!mounted) return;
        ref.read(proxiesSectionProvider.notifier).state =
            ProxiesSection.proxies;
        unawaited(_showProfiles());
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          ref.read(currentPageLabelProvider) == PageLabel.dashboard) {
        _navigate(ref.read(appSettingProvider).menubarStartPage);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (Platform.isMacOS) nativeMenu.detach();
    super.dispose();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleNativeState();
  }

  void _invalidateChecks() {
    _routeCheckEpoch++;
    _routePinging = false;
    _routeChecks = null;
    _checks = null;
    _checking = false;
  }

  Future<void> _refreshZapret() async {
    if (!mounted || _polling) return;
    _polling = true;
    try {
      final running = _zapret.isAvailable && await _zapret.isRunning();
      if (!mounted) return;
      final probeSettings = '${_zapret.strategy}/${_zapret.ipsetMode}';
      if (_probeSettings != null && _probeSettings != probeSettings) {
        _invalidateChecks();
      }
      _probeSettings = probeSettings;
      final changed = _knownZapret && running != _zapretRunning;
      setState(() {
        _knownZapret = true;
        _zapretRunning = running;
        _progress = _testing ? _zapret.testProgress : '';
      });
      if (changed && !_testing && !_zapretBusy) {
        _invalidateChecks();
        if (!running) _zapret.useVpnRoutes();
        await _applyRouting();
      }
    } catch (error) {
      if (mounted) _notify(error);
    } finally {
      _polling = false;
    }
  }

  void _notify(Object message) {
    if (mounted) unawaited(context.showNotifier(message.toString()));
  }

  Future<void> _applyRouting() async {
    if (!mounted || ref.read(currentProfileProvider) == null) return;
    await globalState.appController.applyProfile(silence: true);
  }

  Future<void> _changeRouting(VoidCallback change) async {
    if (_applyingRules) return;
    setState(() => _applyingRules = true);
    var saved = false;
    try {
      change();
      saved = true;
      await _applyRouting();
      if (_zapret.routingEnabled) await _zapret.recheckRoutes();
    } catch (error) {
      _notify(saved ? 'Сохранено. Ошибка применения: $error' : error);
    } finally {
      if (mounted) setState(() => _applyingRules = false);
    }
  }

  Future<void> _toggleVpn() async {
    if (_vpnBusy) return;
    setState(() {
      _vpnBusy = true;
      _invalidateChecks();
    });
    try {
      await globalState.appController.updateStatus(!_vpnRunning);
      if (!_vpnRunning && _zapretRunning && !_zapret.routingEnabled) {
        for (final service in zapretRoutes) {
          _zapret.setManualRoute(service.name, ServicePath.zapret);
        }
        await _applyRouting();
      }
    } catch (error) {
      _notify(error);
    } finally {
      if (mounted) setState(() => _vpnBusy = false);
    }
  }

  Future<void> _runZapret(Future<String?> Function() action) async {
    if (_zapretBusy) return;
    setState(() {
      _zapretBusy = true;
      _invalidateChecks();
    });
    try {
      final error = await action();
      if (error != null) {
        _notify(error);
        return;
      }
      await _applyRouting();
      await _zapret.recheckRoutes();
    } catch (error) {
      _notify(error);
    } finally {
      await _refreshZapret();
      if (mounted) setState(() => _zapretBusy = false);
    }
  }

  Future<void> _testStrategies() async {
    if (_testing) {
      _zapret.cancelTest();
      return;
    }
    setState(() => _testing = true);
    await _runZapret(_zapret.testStrategies);
    if (mounted) {
      setState(() {
        _testing = false;
        _report = _zapret.testReport;
      });
    }
  }

  Future<void> _checkConnections() async {
    if (_checking) return;
    final epoch = _routeCheckEpoch;
    setState(() => _checking = true);
    try {
      final result = await _zapret.checkServices();
      if (mounted && epoch == _routeCheckEpoch) {
        setState(() => _checks = result);
      }
    } catch (error) {
      if (epoch == _routeCheckEpoch) _notify(error);
    } finally {
      if (mounted && epoch == _routeCheckEpoch) {
        setState(() => _checking = false);
      }
    }
  }

  List<Group> get _vpnGroups {
    final generated = {
      for (final service in zapretRoutes) service.group,
      for (final site in _sites.rules)
        if (site.route == SiteRoute.zapret) zapretGroupForDomain(site.domain),
    };
    final global = ref.read(patchClashConfigProvider).mode == Mode.global;
    return ref
        .read(groupsProvider)
        .where((group) =>
            (global ? group.name == 'GLOBAL' : group.name != 'GLOBAL') &&
            !generated.contains(group.name) &&
            group.hidden != true)
        .toList();
  }

  String? get _vpnTarget {
    if (ref.read(patchClashConfigProvider).mode == Mode.global) {
      return ref.read(groupsProvider).getGroup('GLOBAL')?.name;
    }
    final raw = globalState.lastRuntimeConfig;
    final rules = raw?['rule'];
    return raw == null ? null : vpnTargetFor(raw, rules is List ? rules : []);
  }

  Future<void> _pingNodes() async {
    if (!mounted || _nodePinging) return;
    final groups = _vpnGroups;
    if (groups.isEmpty) return;
    setState(() => _nodePinging = true);
    try {
      await Future.wait(groups.map((group) =>
          ref.read(menuNodeTesterProvider)(group.all, group.testUrl)));
    } catch (error) {
      _notify(error);
    } finally {
      if (mounted) setState(() => _nodePinging = false);
    }
  }

  Future<void> _selectNode(Group group, Proxy node) async {
    _invalidateChecks();
    try {
      await globalState.appController.changeProxy(
        groupName: group.name,
        proxyName: node.name,
      );
      globalState.appController.updateCurrentSelectedMap(group.name, node.name);
      await globalState.appController.updateGroups();
    } catch (error) {
      _notify(error);
    }
  }

  Future<void> _pingRoutes() async {
    if (_routePinging || _testing) return;
    final epoch = ++_routeCheckEpoch;
    setState(() {
      _routePinging = true;
      _routeChecks = null;
    });
    try {
      final result = await _zapret.checkPaths(
        _vpnRunning ? _vpnTarget : null,
      );
      if (!mounted || epoch != _routeCheckEpoch) return;
      await ref.read(menuGroupRefresherProvider)();
      if (mounted && epoch == _routeCheckEpoch) {
        setState(() => _routeChecks = result);
      }
    } catch (error) {
      if (epoch == _routeCheckEpoch) _notify(error);
    } finally {
      if (mounted && epoch == _routeCheckEpoch) {
        setState(() => _routePinging = false);
      }
    }
  }

  ServicePath? _pathFor(ZapretRoute service) {
    final mode = ref.read(patchClashConfigProvider).mode;
    if (mode == Mode.direct) return null;
    if (mode == Mode.global) return _vpnRunning ? ServicePath.vpn : null;
    if (!_zapretRunning) return _vpnRunning ? ServicePath.vpn : null;
    if (!_vpnRunning) return ServicePath.zapret;
    if (_zapret.routingEnabled) {
      final group = ref.read(groupsProvider).getGroup(service.group);
      if (group == null || group.realNow.isEmpty) return null;
      return group.realNow == 'DIRECT' ? ServicePath.zapret : ServicePath.vpn;
    }
    return _zapret.manualRoutes[service.name];
  }

  String _pathLabel(ZapretRoute service) {
    if (ref.read(patchClashConfigProvider).mode == Mode.direct) {
      return 'Напрямую';
    }
    return switch (_pathFor(service)) {
      ServicePath.zapret => 'Zapret',
      ServicePath.vpn => 'VPN',
      null => _zapret.routingEnabled && _vpnRunning ? 'Авто' : 'Выключено',
    };
  }

  void _navigate(PageLabel page) {
    if (page == ref.read(currentPageLabelProvider)) {
      setState(() {
        _showAllRules = false;
        _query = '';
      });
      return;
    }
    ref.read(currentPageLabelProvider.notifier).value = page;
  }

  Widget _gap([double height = 8]) => SizedBox(height: height);
  Widget _caption(String text) => Text(text,
      style: const TextStyle(fontSize: 10, color: MenubarStyle.muted));
  Widget _heading(String text) => Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      );
  Widget _switch(bool value, ValueChanged<bool>? onChanged) => SizedBox(
        width: 40,
        height: 32,
        child: FittedBox(
          child: Switch(value: value, onChanged: onChanged),
        ),
      );
  IconData _serviceIcon(String name) => name == 'YouTube'
      ? Icons.smart_display_outlined
      : Icons.sports_esports_outlined;
  Color _serviceColor(String name) =>
      name == 'YouTube' ? const Color(0xfffa8e8e) : const Color(0xffb7b6fc);

  Widget _navigation(PageLabel current) => MenuPanel(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            for (final (page, label, icon) in _destinations)
              Expanded(
                child: Semantics(
                  selected: current == page,
                  child: TextButton(
                    key: ValueKey('menu-nav-${page.name}'),
                    onPressed: () => _navigate(page),
                    style: TextButton.styleFrom(
                      foregroundColor: current == page
                          ? Theme.of(context).colorScheme.primary
                          : MenubarStyle.muted,
                      backgroundColor: current == page
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: .08)
                          : null,
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      shape: RoundedRectangleBorder(
                        borderRadius: MenubarStyle.controlRadius,
                        side: BorderSide(
                          color: current == page
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 19),
                        const SizedBox(height: 3),
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _profileCard({bool power = false}) {
    final profile = ref.watch(currentProfileProvider);
    if (profile == null) {
      return MenuPanel(
        child: OutlinedButton.icon(
          onPressed: _addProfile,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Добавить профиль'),
        ),
      );
    }
    return MenuPanel(
      primary: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (power) ...[
                MenuPower(
                  enabled: _vpnRunning,
                  label: 'VPN',
                  onPressed: _vpnBusy ? null : _toggleVpn,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _caption('Профиль'),
                    InkWell(
                      onTap: _showProfiles,
                      borderRadius: MenubarStyle.controlRadius,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                profile.label ?? profile.id,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.expand_more_rounded, size: 15),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Обновить профиль',
                onPressed:
                    profile.isUpdating ? null : () => _updateProfile(profile),
                icon: const Icon(Icons.sync_rounded),
              ),
            ],
          ),
          _gap(10),
          _profileUsage(profile),
        ],
      ),
    );
  }

  Widget _profileUsage(Profile profile) {
    final info = profile.subscriptionInfo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info != null && info.total > 0) ...[
          Text(
            '${TrafficValue(value: info.upload + info.download).show} / ${TrafficValue(value: info.total).show}',
            style: const TextStyle(fontSize: 12),
          ),
          _gap(6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ((info.upload + info.download) / info.total).clamp(0, 1),
              minHeight: 4,
              backgroundColor: MenubarStyle.raised,
            ),
          ),
          _gap(8),
        ],
        Row(
          children: [
            Expanded(
              child: _caption(
                info == null || info.expire == 0
                    ? 'Без срока действия'
                    : 'До ${DateFormat('dd.MM.yyyy').format(DateTime.fromMillisecondsSinceEpoch(info.expire * 1000))}',
              ),
            ),
            if (profile.isUpdating)
              _caption('Обновление…')
            else if (profile.lastUpdateDate != null)
              _caption(
                DateFormat('dd.MM HH:mm').format(profile.lastUpdateDate!),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _updateProfile(Profile profile) async {
    _invalidateChecks();
    try {
      await globalState.appController.updateProfile(profile);
    } catch (error) {
      _notify(error);
    }
    if (mounted && profile.id == ref.read(currentProfileProvider)?.id) {
      await _pingNodes();
    }
  }

  void _addProfile() =>
      _open('Добавить профиль', AddProfileView(context: context));

  Future<void> _showProfiles() async {
    if (_profilesOpen) return;
    _profilesOpen = true;
    await showDialog<void>(
      context: context,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final profiles = ref.watch(profilesProvider);
          final current = ref.watch(currentProfileProvider);
          final busy = profiles.any((p) => p.isUpdating);
          return Dialog(
            insetPadding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 352,
                maxHeight: MediaQuery.sizeOf(context).height - 48,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(child: _heading('Профили')),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  _invalidateChecks();
                                  try {
                                    await globalState.appController
                                        .updateProfiles();
                                    await _pingNodes();
                                  } catch (error) {
                                    _notify(error);
                                  }
                                },
                          child: const Text(
                            'Обновить все',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Закрыть',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final profile in profiles)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: current?.id == profile.id
                                        ? Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: .08)
                                        : null,
                                    borderRadius: MenubarStyle.controlRadius,
                                    border: Border.all(
                                      color: current?.id == profile.id
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : MenubarStyle.border,
                                    ),
                                  ),
                                  child: InkWell(
                                    borderRadius: MenubarStyle.controlRadius,
                                    onTap: () {
                                      Navigator.pop(context);
                                      _pendingPingProfile = profile.id;
                                      ref
                                          .read(
                                            currentProfileIdProvider.notifier,
                                          )
                                          .value = profile.id;
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(10),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  profile.label ?? profile.id,
                                                  style: const TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                              if (profile.id == current?.id)
                                                Icon(
                                                  Icons.check_rounded,
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                                  size: 16,
                                                ),
                                              IconButton(
                                                tooltip:
                                                    'Обновить ${profile.label ?? profile.id}',
                                                onPressed: profile.isUpdating
                                                    ? null
                                                    : () => _updateProfile(
                                                          profile,
                                                        ),
                                                icon: const Icon(
                                                  Icons.sync_rounded,
                                                ),
                                              ),
                                            ],
                                          ),
                                          _gap(4),
                                          _profileUsage(profile),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            _addProfile();
                          },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Добавить'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            _open(
                              'Профили',
                              const ProfilesView(standalone: true),
                            );
                          },
                          child: const Text('Управление'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    _profilesOpen = false;
  }

  Widget _home() {
    final config = ref.watch(patchClashConfigProvider);
    final network = ref.watch(networkSettingProvider);
    return Column(
      children: [
        _profileCard(),
        _gap(),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: MenubarStyle.well,
            borderRadius: MenubarStyle.panelRadius,
            border: Border.all(color: MenubarStyle.border),
          ),
          child: Row(
            children: [
              for (final (mode, label) in [
                (Mode.rule, 'По правилам'),
                (Mode.global, 'Глобальный'),
                (Mode.direct, 'Напрямую'),
              ])
                Expanded(
                  child: TextButton(
                    onPressed: () => globalState.appController.changeMode(mode),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: EdgeInsets.zero,
                      foregroundColor: config.mode == mode
                          ? Theme.of(context).colorScheme.primary
                          : MenubarStyle.muted,
                      backgroundColor:
                          config.mode == mode ? MenubarStyle.raised : null,
                      shape: const RoundedRectangleBorder(
                        borderRadius: MenubarStyle.controlRadius,
                      ),
                    ),
                    child: Text(label, style: const TextStyle(fontSize: 11)),
                  ),
                ),
            ],
          ),
        ),
        _gap(),
        MenuPanel(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            children: [
              MenuRow(
                label: 'Системный прокси',
                icon: Icons.shuffle_rounded,
                onTap: () => _navigate(PageLabel.tools),
                trailing: _switch(
                  network.systemProxy,
                  (v) => ref
                      .read(networkSettingProvider.notifier)
                      .updateState((s) => s.copyWith(systemProxy: v)),
                ),
              ),
              MenuRow(
                label: 'Zapret',
                icon: Icons.shield_outlined,
                detail: _strategyTitle,
                onTap: () => _navigate(PageLabel.zapret),
                trailing: _switch(
                  _zapretRunning,
                  !_zapret.isAvailable || _zapretBusy
                      ? null
                      : (v) => _runZapret(v ? _zapret.start : _zapret.stop),
                ),
              ),
              MenuRow(
                label: 'TUN',
                icon: Icons.terminal_rounded,
                onTap: () => _navigate(PageLabel.tools),
                trailing: _switch(
                  config.tun.enable,
                  (v) => ref
                      .read(patchClashConfigProvider.notifier)
                      .updateState((s) => s.copyWith.tun(enable: v)),
                ),
              ),
              MenuRow(
                label: 'Автовыбор',
                icon: Icons.alt_route_rounded,
                detail: 'YouTube / Discord',
                divider: false,
                onTap: () => _navigate(PageLabel.routing),
                trailing: _switch(
                  _zapret.routingEnabled,
                  _applyingRules
                      ? null
                      : (v) => _changeRouting(() => _zapret.routingEnabled = v),
                ),
              ),
            ],
          ),
        ),
        _gap(),
        Row(
          children: [
            for (var i = 0; i < zapretRoutes.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: _routeShortcut(zapretRoutes[i])),
            ],
          ],
        ),
      ],
    );
  }

  Widget _routeShortcut(ZapretRoute service) => OutlinedButton(
        onPressed: () => _navigate(PageLabel.routing),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.all(10),
          minimumSize: const Size(0, 50),
          backgroundColor: MenubarStyle.well,
          shape: const RoundedRectangleBorder(
              borderRadius: MenubarStyle.panelRadius),
        ),
        child: Row(
          children: [
            Icon(
              _serviceIcon(service.name),
              color: _serviceColor(service.name),
              size: 21,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _caption(service.name),
                  Text(
                    _pathLabel(service),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: MenubarStyle.muted,
              size: 14,
            ),
          ],
        ),
      );

  Widget _vpn() {
    final groups = _vpnGroups;
    return Column(
      children: [
        _profileCard(power: true),
        _gap(),
        if (groups.isEmpty)
          const MenuPanel(
            child: Text(
              'В выбранном профиле нет серверов.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        for (final group in groups) ...[
          MenuPanel(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _heading(
                        groups.length == 1 ? 'Серверы' : group.name,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _nodePinging
                          ? null
                          : () async {
                              setState(() => _nodePinging = true);
                              try {
                                await ref.read(menuNodeTesterProvider)(
                                  group.all,
                                  group.testUrl,
                                );
                              } catch (error) {
                                _notify(error);
                              } finally {
                                if (mounted) {
                                  setState(() => _nodePinging = false);
                                }
                              }
                            },
                      icon: const Icon(Icons.network_ping_rounded, size: 15),
                      label: Text(_nodePinging ? 'Проверяю…' : 'Пинг'),
                    ),
                  ],
                ),
                _gap(8),
                for (final node in group.all) _node(group, node),
              ],
            ),
          ),
          _gap(),
        ],
      ],
    );
  }

  Widget _node(Group group, Proxy node) {
    final selected =
        ref.watch(getSelectedProxyNameProvider(group.name)) ?? group.realNow;
    final delay = ref.watch(
      getDelayProvider(proxyName: node.name, testUrl: group.testUrl),
    );
    final isSelected = selected == node.name;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        selected: isSelected,
        child: InkWell(
          borderRadius: MenubarStyle.controlRadius,
          onTap: group.type == GroupType.Selector
              ? () => _selectNode(group, node)
              : null,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: MenubarStyle.controlRadius,
              color: isSelected ? MenubarStyle.raised : null,
              border: Border.all(
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(node.name, style: const TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                Text(
                  _nodePinging || delay == null || delay == 0
                      ? '…'
                      : delay > 0
                          ? '$delay мс'
                          : 'Тайм-аут',
                  style: TextStyle(
                    fontSize: 11,
                    color: delay != null && delay < 0
                        ? const Color(0xfff0c58a)
                        : MenubarStyle.accents['Мятный'],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 14,
                  child: isSelected
                      ? Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _strategyTitle {
    for (final strategy in _zapret.strategies) {
      if (strategy.id == _zapret.strategy) return strategy.title;
    }
    return _zapret.strategy;
  }

  Widget _zapretPage() {
    final strategies = _zapret.strategies;
    if (!_zapret.isAvailable) {
      return const MenuPanel(child: Text('Zapret не встроен в эту сборку.'));
    }
    final best = _report?.best.firstOrNull;
    final bestStrategy = strategies.where((s) => s.title == best).firstOrNull;
    return Column(
      children: [
        MenuPanel(
          primary: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  MenuPower(
                    enabled: _zapretRunning,
                    label: 'Zapret',
                    onPressed: _zapretBusy || _testing
                        ? null
                        : () => _runZapret(
                              _zapretRunning ? _zapret.stop : _zapret.start,
                            ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _caption('Стратегия'),
                        DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            isDense: true,
                            value:
                                strategies.any((s) => s.id == _zapret.strategy)
                                    ? _zapret.strategy
                                    : null,
                            hint: const Text(
                              'Нет стратегий',
                              style: TextStyle(fontSize: 12),
                            ),
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontSize: 14,
                                      color: MenubarStyle.text,
                                      fontWeight: FontWeight.w500,
                                    ),
                            items: [
                              for (final s in strategies)
                                DropdownMenuItem(
                                  value: s.id,
                                  child: Text(s.title),
                                ),
                            ],
                            onChanged: _zapretBusy || _testing
                                ? null
                                : (id) {
                                    if (id != null) {
                                      unawaited(_runZapret(
                                          () => _zapret.setStrategy(id)));
                                    }
                                  },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              _gap(12),
              const Divider(height: 1),
              _gap(12),
              FilledButton(
                onPressed: (_zapretBusy && !_testing) || _checking
                    ? null
                    : _testStrategies,
                child: Text(
                  _testing ? 'Остановить проверку' : 'Проверить все стратегии',
                ),
              ),
              if (_testing) ...[
                _gap(8),
                _caption(_progress.isEmpty ? 'Проверка стратегий…' : _progress),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (_report != null) ...[
                _gap(8),
                for (final entry in _report!.scores.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.key,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                        Text(entry.value, style: const TextStyle(fontSize: 10)),
                        if (_report!.best.contains(entry.key))
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(Icons.check_rounded, size: 14),
                          ),
                      ],
                    ),
                  ),
                if (bestStrategy != null && bestStrategy.id != _zapret.strategy)
                  TextButton(
                    onPressed: _testing || _zapretBusy
                        ? null
                        : () => _runZapret(
                              () => _zapret.setStrategy(bestStrategy.id),
                            ),
                    child: Text(
                      'Применить: ${bestStrategy.title}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
              _gap(12),
              const Divider(height: 1),
              _settingChoice<String>(
                'IPSet',
                _zapret.ipsetMode,
                const {
                  'none': 'Домены и правила',
                  'loaded': 'Загруженный IPSet',
                  'any': 'Любые адреса',
                },
                _testing || _zapretBusy
                    ? null
                    : (v) => _runZapret(() => _zapret.setIpsetMode(v)),
              ),
              const Divider(height: 1),
              MenuRow(
                label: 'Домены',
                divider: false,
                trailing: Row(
                  children: [
                    for (final name in ['YouTube', 'Discord'])
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: MenubarStyle.raised,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: _caption(name),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _gap(16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: _heading('Подключения')),
                  const Icon(Icons.network_ping_rounded, size: 16),
                ],
              ),
              _gap(),
              Row(
                children: [
                  for (var i = 0; i < zapretRoutes.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: MenuPanel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _serviceIcon(zapretRoutes[i].name),
                                  color: _serviceColor(zapretRoutes[i].name),
                                  size: 16,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  zapretRoutes[i].name,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                            _gap(12),
                            _caption(
                              _checking
                                  ? 'Проверяю…'
                                  : _checks == null
                                      ? 'Не проверен'
                                      : _checks![zapretRoutes[i].name] == null
                                          ? 'Тайм-аут'
                                          : '${_checks![zapretRoutes[i].name]} мс',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              _gap(),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _zapretBusy || _checking || _testing
                      ? null
                      : _checkConnections,
                  icon: const Icon(Icons.network_ping_rounded, size: 16),
                  label: Text(
                    _checking ? 'Проверяю…' : 'Проверить подключения',
                  ),
                ),
              ),
              _gap(),
              Row(
                children: [
                  TextButton(
                    onPressed: () =>
                        Process.run('/usr/bin/open', [_zapret.listsPath]),
                    child: const Text('Списки', style: TextStyle(fontSize: 11)),
                  ),
                  TextButton(
                    onPressed:
                        _zapretBusy ? null : () => _runZapret(_zapret.reload),
                    child: const Text(
                      'Применить списки',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                  const Spacer(),
                  PopupMenuButton<String>(
                    tooltip: 'Дополнительно',
                    iconSize: 18,
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'update',
                        child: Text('Обновить стратегии'),
                      ),
                    ],
                    onSelected: (_) async {
                      try {
                        _notify(await _zapret.updateStrategies());
                      } catch (error) {
                        _notify(error);
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _settingChoice<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T>? onChanged,
  ) =>
      SizedBox(
        height: 42,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 12, color: MenubarStyle.muted),
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                isDense: true,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontSize: 11, color: MenubarStyle.text),
                items: [
                  for (final e in options.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: onChanged == null
                    ? null
                    : (v) {
                        if (v != null) onChanged(v);
                      },
              ),
            ),
          ],
        ),
      );

  Widget _routing() {
    if (_showAllRules) return _allRules();
    final mode = ref.watch(patchClashConfigProvider).mode;
    return Column(
      children: [
        MenuPanel(
          child: Row(
            children: [
              const Icon(Icons.alt_route_rounded, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [_heading('Автовыбор'), _caption('Zapret → VPN')],
                ),
              ),
              _switch(
                _zapret.routingEnabled,
                _applyingRules
                    ? null
                    : (v) => _changeRouting(() => _zapret.routingEnabled = v),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Проверить пинг напрямую и через VPN',
                onPressed: _routePinging || _testing || _applyingRules
                    ? null
                    : _pingRoutes,
                icon: _routePinging
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_ping_rounded, size: 16),
              ),
            ],
          ),
        ),
        _gap(),
        if (mode != Mode.rule)
          Row(
            children: [
              Expanded(
                child: _caption(
                  mode == Mode.global ? 'Глобальный режим' : 'Режим «Напрямую»',
                ),
              ),
              TextButton(
                onPressed: () =>
                    globalState.appController.changeMode(Mode.rule),
                child: const Text('По правилам'),
              ),
            ],
          ),
        MenuPanel(
          child: Column(
            children: [
              for (var i = 0; i < zapretRoutes.length; i++) ...[
                if (i > 0) _gap(),
                _serviceRoute(zapretRoutes[i], mode),
              ],
            ],
          ),
        ),
        _gap(),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => setState(() {
              _showAllRules = true;
              _query = '';
            }),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 44),
              backgroundColor: MenubarStyle.well,
              shape: const RoundedRectangleBorder(
                borderRadius: MenubarStyle.panelRadius,
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.format_list_bulleted_rounded, size: 16),
                const SizedBox(width: 8),
                const Expanded(child: Text('Все правила')),
                _caption(
                  '${(globalState.lastRuntimeConfig?['rule'] as List? ?? []).length}',
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded, size: 14),
              ],
            ),
          ),
        ),
        _gap(),
        _siteRules(),
        _gap(),
        _appRules(),
      ],
    );
  }

  Widget _serviceRoute(ZapretRoute service, Mode mode) => Row(
        children: [
          SizedBox(
            width: 80,
            child: Row(
              children: [
                Icon(
                  _serviceIcon(service.name),
                  color: _serviceColor(service.name),
                  size: 18,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    service.name,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          for (final path in ServicePath.values) ...[
            if (path == ServicePath.vpn) const SizedBox(width: 6),
            Expanded(child: _routeChoice(service, path, mode)),
          ],
        ],
      );

  Widget _routeChoice(ZapretRoute service, ServicePath path, Mode mode) {
    final enabled = path == ServicePath.zapret
        ? _zapretRunning
        : _vpnRunning && _vpnTarget != null;
    final selected = _pathFor(service) == path;
    final delay = _routeChecks?[service.name]?[path];
    final primary = Theme.of(context).colorScheme.primary;
    return Semantics(
      selected: selected,
      child: OutlinedButton(
        onPressed: !enabled ||
                mode != Mode.rule ||
                _zapret.routingEnabled ||
                _applyingRules
            ? null
            : () => _changeRouting(
                  () => _zapret.setManualRoute(service.name, path),
                ),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 38),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          foregroundColor: MenubarStyle.text,
          disabledForegroundColor: MenubarStyle.text,
          backgroundColor:
              selected ? primary.withValues(alpha: .08) : MenubarStyle.well,
          side: BorderSide(color: selected ? primary : MenubarStyle.border),
        ),
        child: Opacity(
          opacity: enabled ? 1 : .35,
          child: LayoutBuilder(builder: (context, constraints) {
            final showPing = _routePinging || _routeChecks != null;
            final compact = showPing && constraints.maxWidth < 100;
            return Row(
              children: [
                if (!compact) ...[
                  Icon(
                    path == ServicePath.zapret
                        ? Icons.shield_outlined
                        : Icons.language_rounded,
                    size: 13,
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                          child: Text(
                        path == ServicePath.zapret ? 'Zapret' : 'VPN',
                        style: const TextStyle(fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )),
                      if (selected && !showPing) ...[
                        const SizedBox(width: 3),
                        Icon(Icons.check_rounded, size: 11, color: primary),
                      ],
                    ],
                  ),
                ),
                if (showPing)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      _routePinging
                          ? '…'
                          : path == ServicePath.vpn && !_vpnRunning
                              ? 'Выключен'
                              : delay == null
                                  ? 'Тайм-аут'
                                  : '$delay мс',
                      style: TextStyle(
                        fontSize: 10,
                        color: delay == null
                            ? const Color(0xfff0c58a)
                            : MenubarStyle.accents['Мятный'],
                      ),
                    ),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget _ruleHeader(
    String title,
    int count,
    VoidCallback add, {
    VoidCallback? apply,
  }) =>
      Row(
        children: [
          Expanded(
            child: Row(
              children: [
                _heading(title),
                const SizedBox(width: 8),
                _caption('$count'),
              ],
            ),
          ),
          if (apply != null)
            IconButton(
              tooltip: 'Применить правила',
              onPressed: _applyingRules ? null : apply,
              icon: const Icon(Icons.sync_rounded, size: 16),
            ),
          IconButton(
            tooltip: 'Добавить ${title == 'Сайты' ? 'сайт' : 'приложение'}',
            onPressed: _applyingRules ? null : add,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      );

  Widget _siteRules() => MenuPanel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          children: [
            _ruleHeader(
              'Сайты',
              _sites.rules.length,
              _editSite,
              apply: () => _changeRouting(() {}),
            ),
            if (_applyingRules) const LinearProgressIndicator(minHeight: 2),
            if (_sites.rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _caption('Добавьте сайт кнопкой «+».'),
              ),
            for (final rule in _sites.rules)
              _ruleRow(
                icon: Icons.language_rounded,
                name: rule.domain,
                target: rule.route.label,
                onTap: () => _editSite(rule),
                onDelete: () =>
                    _changeRouting(() => _sites.remove(rule.domain)),
                color: rule.route == SiteRoute.direct
                    ? const Color(0xffd4b3ed)
                    : null,
              ),
          ],
        ),
      );

  Future<void> _editSite([SiteRule? existing]) async {
    final rule = await showDialog<SiteRule>(
      context: context,
      builder: (_) => SiteRuleDialog(initialRule: existing),
    );
    if (rule == null || !mounted) return;
    await _changeRouting(
      () => _sites.put(rule, previousDomain: existing?.domain),
    );
  }

  Widget _appRules() => MenuPanel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          children: [
            _ruleHeader('Приложения', _apps.rules.length, _addApp),
            MenuRow(
              label: 'Только эти приложения через VPN',
              divider: false,
              trailing: _switch(
                _apps.onlyListed,
                _applyingRules
                    ? null
                    : (v) => _changeRouting(() => _apps.onlyListed = v),
              ),
            ),
            if (_apps.rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _caption('Добавьте приложение кнопкой «+».'),
              ),
            for (final rule in _apps.rules)
              _ruleRow(
                icon: rule.isBundle
                    ? Icons.apps_outlined
                    : Icons.terminal_rounded,
                name: rule.name,
                subtitle: rule.app == rule.name ? null : rule.app,
                target: rule.route.label,
                onTap: () => _editApp(rule),
                onDelete: () => _changeRouting(() => _apps.remove(rule.app)),
                color: rule.route == AppRoute.direct
                    ? const Color(0xffd4b3ed)
                    : null,
              ),
          ],
        ),
      );

  Widget _ruleRow({
    required IconData icon,
    required String name,
    required String target,
    required VoidCallback onTap,
    required VoidCallback onDelete,
    String? subtitle,
    Color? color,
  }) =>
      Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: MenubarStyle.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: _applyingRules ? null : onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Icon(icon, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name, style: const TextStyle(fontSize: 12)),
                            if (subtitle != null)
                              Text(
                                subtitle,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: MenubarStyle.muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        target,
                        style: TextStyle(
                          fontSize: 10,
                          color: color ?? Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Удалить $name',
              onPressed: _applyingRules ? null : onDelete,
              icon: const Icon(Icons.delete_outline_rounded, size: 16),
            ),
          ],
        ),
      );

  Future<void> _addApp() async {
    final selected = await showAppPicker(context);
    if (selected == null || !mounted) return;
    await _changeRouting(() {
      for (final app in selected) {
        final existing = _apps.rules.where((r) => r.app == app).firstOrNull;
        _apps.put(AppRule(app: app, route: existing?.route ?? AppRoute.vpn));
      }
    });
  }

  Future<void> _editApp(AppRule rule) async {
    final result = await showDialog<AppRoute>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(rule.name),
        children: [
          for (final route in AppRoute.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, route),
              child: Row(
                children: [
                  Expanded(child: Text(route.label)),
                  if (rule.route == route)
                    const Icon(Icons.check_rounded, size: 16),
                ],
              ),
            ),
        ],
      ),
    );
    if (result != null && mounted) {
      await _changeRouting(() => _apps.put(rule.copyWith(route: result)));
    }
  }

  Widget _allRules() {
    final raw = globalState.lastRuntimeConfig?['rule'] as List? ?? [];
    final rules = raw
        .map((r) => RuntimeRule.parse('$r'))
        .where((r) => r.matches(_query))
        .toList();
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Назад к маршрутам',
              onPressed: () => setState(() => _showAllRules = false),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(child: _heading('Все правила')),
            IconButton(
              tooltip: 'Обновить список',
              onPressed: () => setState(() {}),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        _gap(),
        TextField(
          onChanged: (v) => setState(() => _query = v),
          decoration: const InputDecoration(
            labelText: 'Домен, процесс или маршрут',
            prefixIcon: Icon(Icons.search_rounded, size: 18),
          ),
        ),
        _gap(),
        Align(
          alignment: Alignment.centerLeft,
          child: _caption(
            _query.isEmpty
                ? 'Всего: ${raw.length}'
                : 'Найдено: ${rules.length} из ${raw.length}',
          ),
        ),
        _gap(),
        MenuPanel(
          child: Column(
            children: [
              if (raw.isEmpty)
                _caption('Правил нет: профиль ещё не применён')
              else if (rules.isEmpty)
                _caption('Правила не найдены.'),
              for (final rule in rules)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: const BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: MenubarStyle.border)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              rule.payload.isEmpty
                                  ? 'Остальной трафик'
                                  : rule.payload,
                              style: const TextStyle(fontSize: 11),
                            ),
                            _caption(rule.type),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 95,
                        child: Text(
                          rule.target,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 10,
                            color: rule.target == 'DIRECT'
                                ? const Color(0xffd4b3ed)
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _settings() {
    final theme = ref.watch(themeSettingProvider);
    final app = ref.watch(appSettingProvider);
    final network = ref.watch(networkSettingProvider);
    final tun = ref.watch(patchClashConfigProvider).tun.enable;
    return Column(
      children: [
        MenuPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _heading('Акцентный цвет'),
              _gap(12),
              Row(
                children: [
                  for (final e in MenubarStyle.accents.entries)
                    Expanded(
                      child: Semantics(
                        selected: theme.primaryColor == e.value.toARGB32(),
                        child: InkWell(
                          onTap: () => ref
                              .read(themeSettingProvider.notifier)
                              .updateState(
                                (s) => s.copyWith(
                                  primaryColor: e.value.toARGB32(),
                                ),
                              ),
                          borderRadius: MenubarStyle.controlRadius,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: e.value,
                                    shape: BoxShape.circle,
                                  ),
                                  child:
                                      theme.primaryColor == e.value.toARGB32()
                                          ? const Icon(
                                              Icons.check_rounded,
                                              size: 16,
                                              color: Color(0xff17261f),
                                            )
                                          : null,
                                ),
                                _gap(6),
                                Text(
                                  e.key,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: MenubarStyle.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        _gap(),
        MenuPanel(
          child: Column(
            children: [
              const MenuRow(
                label: 'Оформление',
                trailing: Text('Тёмное', style: TextStyle(fontSize: 12)),
              ),
              MenuRow(
                label: 'Запускать при входе',
                divider: false,
                trailing: _switch(
                  app.autoLaunch,
                  (v) => ref
                      .read(appSettingProvider.notifier)
                      .updateState((s) => s.copyWith(autoLaunch: v)),
                ),
              ),
              const Divider(height: 1),
              _settingChoice<PageLabel>(
                'Открывать',
                app.menubarStartPage,
                {for (final item in _destinations) item.$1: item.$2},
                (v) => ref
                    .read(appSettingProvider.notifier)
                    .updateState((s) => s.copyWith(menubarStartPage: v)),
              ),
            ],
          ),
        ),
        _gap(),
        MenuPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _heading('Сеть'),
              MenuRow(
                label: 'Системный прокси',
                trailing: _switch(
                  network.systemProxy,
                  (v) => ref
                      .read(networkSettingProvider.notifier)
                      .updateState((s) => s.copyWith(systemProxy: v)),
                ),
              ),
              MenuRow(
                label: 'TUN',
                divider: false,
                trailing: _switch(
                  tun,
                  (v) => ref
                      .read(patchClashConfigProvider.notifier)
                      .updateState((s) => s.copyWith.tun(enable: v)),
                ),
              ),
            ],
          ),
        ),
        _gap(),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _open('Все настройки', const ToolsView()),
            icon: const Icon(Icons.tune_rounded, size: 16),
            label: const Text('Все настройки'),
          ),
        ),
      ],
    );
  }

  void _open(String title, Widget child) => showExtend(
        context,
        builder: (_, type) =>
            AdaptiveSheetScaffold(type: type, title: title, body: child),
      );

  @override
  Widget build(BuildContext context) {
    final initialized = ref.watch(initProvider);
    _scheduleNativeState();
    // Keep provider subscriptions alive while switching between the compact pages.
    ref.watch(groupsProvider);
    final runTime = ref.watch(runTimeProvider);
    ref.watch(currentProfileProvider);
    ref.watch(patchClashConfigProvider);
    final requested = ref.watch(currentPageLabelProvider);
    final page = _destinations.any((d) => d.$1 == requested)
        ? requested
        : PageLabel.dashboard;
    return CommonScaffold(
      key: globalState.homeScaffoldKey,
      hideAppBar: true,
      disableBackground: true,
      backgroundColor: MenubarStyle.background,
      body: nativeMenu.attached && initialized
          ? const SizedBox.shrink()
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: _navigation(page),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey('menu-page-${page.name}'),
                    padding: const EdgeInsets.all(8),
                    child: switch (page) {
                      PageLabel.proxies => _vpn(),
                      PageLabel.zapret => _zapretPage(),
                      PageLabel.routing => _routing(),
                      PageLabel.tools => _settings(),
                      _ => _home(),
                    },
                  ),
                ),
                if (page == PageLabel.dashboard)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _vpnBusy ? null : _toggleVpn,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          backgroundColor: MenubarStyle.panel,
                        ),
                        icon: Icon(
                          _vpnRunning
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 18,
                        ),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _vpnBusy
                                  ? 'Применяю…'
                                  : _vpnRunning
                                      ? 'Остановить VPN'
                                      : 'Включить VPN',
                            ),
                            if (runTime != null) ...[
                              const SizedBox(width: 12),
                              Text(utils.getTimeText(runTime)),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
