import 'dart:async';
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';

class ZapretView extends StatefulWidget {
  const ZapretView({super.key});

  @override
  State<ZapretView> createState() => _ZapretViewState();
}

class _ZapretViewState extends State<ZapretView> {
  bool _running = false;
  bool _busy = false;
  bool _testing = false;
  bool _checking = false;
  Map<String, int?>? _services;
  String _progress = '';
  ZapretTestReport? _report;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _report = zapret.testReport;
    _refresh();
    _checkServices();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final running = await zapret.isRunning();
    final progress = _testing ? zapret.testProgress : '';
    if (!mounted) return;
    if (running != _running || progress != _progress) {
      setState(() {
        _running = running;
        _progress = progress;
      });
    }
  }

  Future<void> _run(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final error = await action();
    if (error == null) await zapret.recheckRoutes();
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      context.showNotifier(error);
    } else {
      unawaited(_checkServices());
    }
  }

  Future<void> _checkServices() async {
    if (_checking) return;
    setState(() => _checking = true);
    final results = await zapret.checkServices();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _services = results;
    });
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    await _run(zapret.testStrategies);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _report = zapret.testReport;
    });
  }

  Future<void> _update() async {
    if (_busy) return;
    setState(() => _busy = true);
    final message = await zapret.updateStrategies();
    if (!mounted) return;
    setState(() => _busy = false);
    context.showNotifier(message);
  }

  String? get _bestId {
    final best = _report?.best ?? const [];
    if (best.isEmpty) return null;
    for (final strategy in zapret.strategies) {
      if (strategy.title == best.first) return strategy.id;
    }
    return null;
  }

  Widget _status() => ListItem.switchItem(
        title: const Text('Zapret'),
        subtitle: Text(
          _testing
              ? (_progress.isEmpty ? 'Проверка стратегий…' : _progress)
              : _busy
                  ? 'Применяю…'
                  : _running
                      ? 'Работает'
                      : 'Остановлен',
        ),
        delegate: SwitchDelegate(
          value: _running,
          onChanged: _busy
              ? null
              : (value) => _run(value ? zapret.start : zapret.stop),
        ),
      );

  Widget _strategies() {
    final report = _report;
    final best = report?.best.toSet() ?? const <String>{};
    final current = zapret.strategy;
    final bestId = _bestId;
    return generateSectionV2(
      title: 'Стратегии · ${zapret.version}',
      actions: [
        if (_testing)
          TextButton(
            onPressed: zapret.cancelTest,
            child: const Text('Остановить'),
          )
        else
          TextButton(
            onPressed: _busy ? null : _test,
            child: const Text('Проверить все'),
          ),
      ],
      items: [
        if (report != null)
          ListItem(
            title: Text('Проверка: ${report.date}'),
            subtitle: Text(
              best.isEmpty ? 'Лучшая не определена' : 'Лучшая: ${best.join(', ')}',
            ),
            trailing: bestId != null && bestId != current
                ? TextButton(
                    onPressed:
                        _busy ? null : () => _run(() => zapret.setStrategy(bestId)),
                    child: const Text('Выбрать'),
                  )
                : null,
          ),
        for (final strategy in zapret.strategies)
          ListItem(
            title: Text(strategy.title),
            subtitle: report?.scores[strategy.title] != null
                ? Text(
                    '${report!.scores[strategy.title]}${best.contains(strategy.title) ? '  ★' : ''}',
                  )
                : null,
            trailing: strategy.id == current
                ? const Icon(Icons.check_rounded)
                : null,
            onTap: _busy || strategy.id == current
                ? null
                : () => _run(() => zapret.setStrategy(strategy.id)),
          ),
      ],
    );
  }

  Widget _options() => generateSectionV2(
        title: 'Настройки',
        items: [
          ListItem<String>.options(
            title: const Text('IPSet'),
            subtitle: Text(zapret.ipsetMode),
            delegate: OptionsDelegate<String>(
              title: 'IPSet',
              options: Zapret.ipsetModes,
              value: zapret.ipsetMode,
              textBuilder: (mode) => mode,
              onChanged: (mode) {
                if (mode == null || mode == zapret.ipsetMode) return;
                _run(() => zapret.setIpsetMode(mode));
              },
            ),
          ),
          ListItem(
            title: const Text('Открыть списки'),
            subtitle: Text(zapret.listsPath),
            onTap: () => Process.run('/usr/bin/open', [zapret.listsPath]),
          ),
          ListItem(
            title: const Text('Применить списки'),
            subtitle: const Text('Перезапустить zapret с текущими списками'),
            onTap: _busy ? null : () => _run(zapret.reload),
          ),
          ListItem(
            title: const Text('Обновить стратегии'),
            subtitle: const Text('Из релизов Flowseal/zapret-mac-discord-youtube'),
            onTap: _busy ? null : _update,
          ),
        ],
      );

  /// Direct (past the VPN) reachability of each service: what zapret gives.
  Widget _availability() {
    final scheme = Theme.of(context).colorScheme;
    return generateSectionV2(
      title: 'Доступность через zapret',
      actions: [
        TextButton(
          onPressed: _checking ? null : _checkServices,
          child: Text(_checking ? 'Проверяю…' : 'Проверить'),
        ),
      ],
      items: [
        for (final route in zapretRoutes)
          ListItem(
            title: Text(route.name),
            subtitle: Text(Uri.parse(route.testUrl).host),
            trailing: _services == null
                ? const Text('—')
                : _services![route.name] == null
                    ? Text('недоступен', style: TextStyle(color: scheme.error))
                    : Text(
                        '${_services![route.name]} мс',
                        style: TextStyle(color: scheme.tertiary),
                      ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!zapret.isAvailable) {
      return const Center(child: Text('zapret не встроен в эту сборку'));
    }
    return SingleChildScrollView(
      padding: baseInfoEdgeInsets,
      child: Column(
        children: [
          CommonCard(
            type: CommonCardType.filled,
            radius: 18,
            child: _status(),
          ),
          const SizedBox(height: 16),
          _availability(),
          const SizedBox(height: 16),
          _strategies(),
          const SizedBox(height: 16),
          _options(),
        ],
      ),
    );
  }
}
