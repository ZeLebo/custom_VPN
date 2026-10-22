import 'dart:async';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';

/// Dashboard card: zapret on/off and the current strategy; tap opens the tab.
class ZapretButton extends StatefulWidget {
  const ZapretButton({super.key});

  @override
  State<ZapretButton> createState() => _ZapretButtonState();
}

class _ZapretButtonState extends State<ZapretButton> {
  bool _running = false;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final running = await zapret.isRunning();
    if (mounted && running != _running) setState(() => _running = running);
  }

  Future<void> _toggle(bool value) async {
    setState(() => _busy = true);
    final error = await (value ? zapret.start() : zapret.stop());
    if (error == null) await zapret.recheckRoutes();
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) context.showNotifier(error);
  }

  String get _strategyTitle {
    for (final strategy in zapret.strategies) {
      if (strategy.id == zapret.strategy) return strategy.title;
    }
    return zapret.strategy;
  }

  @override
  Widget build(BuildContext context) {
    if (!zapret.isAvailable) return const SizedBox.shrink();
    return SizedBox(
      height: getWidgetHeight(1),
      child: CommonCard(
        onPressed: () => globalState.appController.toPage(PageLabel.zapret),
        info: Info(
          label: 'Zapret',
          iconData: _running ? Icons.shield_rounded : Icons.shield_outlined,
        ),
        child: Container(
          padding: baseInfoEdgeInsets.copyWith(top: 4, bottom: 8, right: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: TooltipText(
                  text: Text(
                    _busy ? 'Применяю…' : _running ? _strategyTitle : 'Выключен',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.adjustSize(-2)
                        .toLight,
                  ),
                ),
              ),
              Switch(
                value: _running,
                onChanged: _busy ? null : _toggle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
