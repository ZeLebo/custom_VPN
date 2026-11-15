import 'package:flclashx/common/common.dart';
import 'package:flclashx/widgets/dialog.dart';
import 'package:flutter/material.dart';

class SiteRuleDialog extends StatefulWidget {
  const SiteRuleDialog({super.key});

  @override
  State<SiteRuleDialog> createState() => _SiteRuleDialogState();
}

class _SiteRuleDialogState extends State<SiteRuleDialog> {
  final _input = TextEditingController();
  SiteRoute _route = SiteRoute.direct;
  String? _domain;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _preview(String value) {
    setState(() {
      try {
        _domain = normalizeSiteDomain(value);
        _error = null;
      } on FormatException catch (error) {
        _domain = null;
        _error = value.isEmpty ? null : error.message;
      }
    });
  }

  void _save() {
    if (_domain == null) return;
    Navigator.of(context).pop(SiteRule(domain: _domain!, route: _route));
  }

  @override
  Widget build(BuildContext context) => CommonDialog(
        title: 'Добавить сайт',
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: _domain == null ? null : _save,
            child: const Text('Сохранить'),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _input,
              autofocus: true,
              keyboardType: TextInputType.url,
              onChanged: _preview,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: 'Ссылка или домен',
                hintText: 'https://example.com/page?id=123',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _domain == null
                  ? 'Путь, параметры и номер порта будут убраны.'
                  : 'Будет сохранён: $_domain',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<SiteRoute>(
              initialValue: _route,
              decoration: const InputDecoration(labelText: 'Маршрут'),
              items: [
                for (final route in SiteRoute.values)
                  DropdownMenuItem(value: route, child: Text(route.label)),
              ],
              onChanged: (route) {
                if (route != null) setState(() => _route = route);
              },
            ),
            const SizedBox(height: 12),
            const Text(
              'Правило действует во всех приложениях, включая поддомены. '
              'Для youtube.com и discord.com также учитываются связанные домены. '
              '«Напрямую» обходит VPN и обработку Zapret.',
            ),
          ],
        ),
      );
}
