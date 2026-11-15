import 'package:flclashx/common/site_rules.dart';
import 'package:flclashx/providers/app.dart';
import 'package:flclashx/views/proxies/site_rule_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DialogSize extends ViewSize {
  @override
  Size build() => const Size(400, 640);
}

void main() {
  Future<void> openDialog(
    WidgetTester tester, {
    ValueChanged<SiteRule?>? onSaved,
  }) async {
    tester.view.physicalSize = const Size(400, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [viewSizeProvider.overrideWith(_DialogSize.new)],
      child: MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      final rule = await showDialog<SiteRule>(
                        context: context,
                        builder: (_) => const SiteRuleDialog(),
                      );
                      onSaved?.call(rule);
                    },
                    child: const Text('Открыть'),
                  ),
                )),
      ),
    ));
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
  }

  testWidgets('previews the cleaned host and saves the direct exception',
      (tester) async {
    SiteRule? saved;
    await openDialog(tester, onSaved: (rule) => saved = rule);
    final save = find.widgetWithText(TextButton, 'Сохранить');
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    await tester.enterText(find.byType(TextField),
        'https://Shop.Example.com:8443/posts/123?id=456#comments');
    await tester.pump();
    expect(find.text('Будет сохранён: shop.example.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved?.domain, 'shop.example.com');
    expect(saved?.route, SiteRoute.direct);
  });

  testWidgets('allows selecting Zapret with VPN fallback', (tester) async {
    SiteRule? saved;
    await openDialog(tester, onSaved: (rule) => saved = rule);
    await tester.enterText(find.byType(TextField), 'example.com/path');
    await tester.tap(find.byType(DropdownButtonFormField<SiteRoute>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zapret → VPN').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(saved?.route, SiteRoute.zapret);
  });

  testWidgets('rejects invalid input before saving', (tester) async {
    await openDialog(tester);
    await tester.enterText(find.byType(TextField), 'example.com,DIRECT');
    await tester.pump();
    expect(find.text('Введите домен, например example.com'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Сохранить'))
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
  });
}
