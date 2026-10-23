import 'dart:async';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/views/proxies/app_picker.dart';
import 'package:flclashx/views/proxies/section.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One rule of the running config, e.g. `DOMAIN-SUFFIX,youtube.com,Zapret YouTube`.
class _Rule {
  factory _Rule.parse(String raw) {
    var rest = raw.trim();
    // trailing options like ",no-resolve" / ",src" are not part of the target
    for (final option in const [',no-resolve', ',src']) {
      if (rest.endsWith(option)) {
        rest = rest.substring(0, rest.length - option.length);
      }
    }
    final first = rest.indexOf(',');
    if (first < 0) return _Rule._(rest, '', '');
    final last = rest.lastIndexOf(',');
    return _Rule._(
      rest.substring(0, first),
      first == last ? '' : rest.substring(first + 1, last),
      rest.substring(last + 1),
    );
  }

  const _Rule._(this.type, this.payload, this.target);

  final String type;
  final String payload;
  final String target;

  bool matches(String query) {
    final q = query.toLowerCase();
    return type.toLowerCase().contains(q) ||
        payload.toLowerCase().contains(q) ||
        target.toLowerCase().contains(q);
  }
}

/// Rules the core is running with, in order: zapret routes, override rules,
/// then the profile's own rules.
class RulesView extends ConsumerStatefulWidget {
  const RulesView({super.key});

  @override
  ConsumerState<RulesView> createState() => _RulesViewState();
}

class _RulesViewState extends ConsumerState<RulesView> with PageMixin {
  List<_Rule> _rules = [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
    ref.listenManual(
      proxiesSectionActiveProvider(ProxiesSection.rules),
      (prev, next) {
        if (next && prev != next) {
          _load();
          initPageState();
        }
      },
      fireImmediately: true,
    );
  }

  void _load() {
    final raw = globalState.lastRuntimeConfig?['rule'];
    setState(() {
      _rules =
          raw is List ? raw.map((rule) => _Rule.parse('$rule')).toList() : [];
    });
  }

  void _updateAppRules(VoidCallback change) {
    setState(change);
    globalState.appController.applyProfileDebounce(silence: true);
    unawaited(Future.delayed(const Duration(seconds: 1), () {
      if (mounted) _load();
    }));
  }

  Future<void> _addApp() async {
    final app = await showAppPicker(context);
    if (app == null || !mounted) return;
    var route = AppRoute.vpn;
    for (final rule in appRules.rules) {
      if (rule.app == app) {
        route = rule.route;
        break;
      }
    }
    _updateAppRules(() => appRules.put(AppRule(app: app, route: route)));
  }

  @override
  List<Widget> get actions => [
        IconButton(
          tooltip: 'Обновить',
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ];

  @override
  Function(String)? get onSearch => (value) => setState(() => _query = value);

  Color? _targetColor(BuildContext context, String target) {
    final scheme = Theme.of(context).colorScheme;
    if (target == 'DIRECT') return scheme.tertiary;
    if (target.startsWith('REJECT')) return scheme.error;
    if (target.startsWith('Zapret ')) return scheme.primary;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final rules = _query.isEmpty
        ? _rules
        : _rules.where((rule) => rule.matches(_query)).toList();
    final showApps = appRules.isAvailable;
    if (_rules.isEmpty && !showApps) {
      return const NullStatus(label: 'Правил нет: профиль ещё не применён');
    }
    final query = _query.toLowerCase();
    final appItems = <Widget>[
      if (showApps) ...[
        ListHeader(
          title: 'Приложения',
          actions: [
            IconButton(
              tooltip: 'Добавить приложение',
              onPressed: _addApp,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
        ListItem.switchItem(
          title: const Text('Только эти приложения через VPN'),
          subtitle: const Text('Остальной трафик пойдёт напрямую'),
          delegate: SwitchDelegate(
            value: appRules.onlyListed,
            onChanged: (value) =>
                _updateAppRules(() => appRules.onlyListed = value),
          ),
        ),
        if (appRules.rules.isEmpty)
          const ListItem(
            dense: true,
            title: Text(
              'Добавьте приложение, чтобы пустить его через VPN или мимо него',
            ),
          ),
        for (final rule in appRules.rules)
          if (rule.name.toLowerCase().contains(query) ||
              rule.app.toLowerCase().contains(query))
            ListItem(
              dense: true,
              leading: Icon(
                rule.isBundle ? Icons.apps_rounded : Icons.terminal_rounded,
              ),
              title: Text(rule.name),
              subtitle: Text(
                rule.app,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<AppRoute>(
                    initialValue: rule.route,
                    onSelected: (route) => _updateAppRules(
                      () => appRules.put(rule.copyWith(route: route)),
                    ),
                    itemBuilder: (_) => [
                      for (final route in AppRoute.values)
                        PopupMenuItem(value: route, child: Text(route.label)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        rule.route.label,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: _targetColor(
                                  context,
                                  switch (rule.route) {
                                    AppRoute.vpn => '',
                                    AppRoute.direct => 'DIRECT',
                                    AppRoute.block => 'REJECT',
                                  }),
                            ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Удалить',
                    onPressed: () =>
                        _updateAppRules(() => appRules.remove(rule.app)),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
            ),
        const ListItem(
          dense: true,
          leading: Icon(Icons.info_outline_rounded),
          title: Text(
            'Команды в терминале (curl, git, ssh) — отдельные процессы: '
            'правило для kitty или Terminal их не ловит. '
            'Добавляйте их через «Процесс или шаблон…».',
          ),
        ),
      ],
    ];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: appItems.length + 1 + (_rules.isEmpty ? 1 : rules.length),
      itemBuilder: (context, index) {
        if (index < appItems.length) return appItems[index];
        final ruleIndex = index - appItems.length;
        if (ruleIndex == 0) {
          return ListHeader(
            title: _query.isEmpty
                ? 'Всего: ${_rules.length}'
                : 'Найдено: ${rules.length} из ${_rules.length}',
          );
        }
        if (_rules.isEmpty) {
          return const ListItem(
            dense: true,
            title: Text('Правил нет: профиль ещё не применён'),
          );
        }
        final rule = rules[ruleIndex - 1];
        return ListItem(
          dense: true,
          title: Text(
            rule.payload.isEmpty ? rule.type : rule.payload,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(rule.payload.isEmpty ? '' : rule.type),
          trailing: Text(
            rule.target,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: _targetColor(context, rule.target),
                ),
          ),
        );
      },
    );
  }
}
