import 'package:flclashx/common/common.dart';
import 'package:flclashx/state.dart';
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
      if (rest.endsWith(option)) rest = rest.substring(0, rest.length - option.length);
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
      _rules = raw is List ? raw.map((rule) => _Rule.parse('$rule')).toList() : [];
    });
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
    if (_rules.isEmpty) {
      return const NullStatus(label: 'Правил нет: профиль ещё не применён');
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: rules.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return ListHeader(
            title: _query.isEmpty
                ? 'Всего: ${_rules.length}'
                : 'Найдено: ${rules.length} из ${_rules.length}',
          );
        }
        final rule = rules[index - 1];
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
