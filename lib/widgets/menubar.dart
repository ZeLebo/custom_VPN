import 'package:flclashx/common/native_menu.dart';
import 'package:flutter/material.dart';

class NativeMenuEditorTheme extends StatelessWidget {
  const NativeMenuEditorTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: nativeMenu.legacyPresentation,
        builder: (context, visible, child) => visible
            ? Theme(
                data: MenubarStyle.editorTheme(Theme.of(context)),
                child: child!)
            : child!,
        child: child,
      );
}

/// Shared geometry and surfaces of the compact macOS menu-bar interface.
abstract final class MenubarStyle {
  static const background = Color(0xff151d23);
  static const panel = Color(0xff232b31);
  static const raised = Color(0xff303a41);
  static const well = Color(0xff1a2228);
  static const border = Color(0xff364149);
  static const text = Color(0xffe8eef4);
  static const muted = Color(0xffacbac7);
  static const panelRadius = BorderRadius.all(Radius.circular(12));
  static const controlRadius = BorderRadius.all(Radius.circular(8));
  static const accents = <String, Color>{
    'Синий': Color(0xffa6d0fc),
    'Оранжевый': Color(0xfff2b078),
    'Мятный': Color(0xffa4d7bd),
    'Сиреневый': Color(0xffc4b5fa),
    'Розовый': Color(0xfff0a5bc),
  };

  /// Compact style shared by existing editors presented above the native menu.
  static ThemeData editorTheme(ThemeData base) {
    final dark = base.brightness == Brightness.dark;
    final surface = Color(dark ? 0xff242629 : 0xfff1f3f5);
    final card = Color(dark ? 0xff1e1e1e : 0xffffffff);
    final scheme = base.colorScheme.copyWith(
        surface: surface,
        surfaceContainer: card,
        surfaceContainerHighest: card,
        onSurface: Color(dark ? 0xffe2e2e2 : 0xff222222),
        onSurfaceVariant: Color(dark ? 0xffaaaaaa : 0xff6d6d6d));
    final original = base.textTheme.apply(
        fontFamily: '.SF Pro Text',
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface);
    final text = original.copyWith(
      headlineSmall: original.headlineSmall
          ?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
      titleLarge: original.titleLarge
          ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
      titleMedium: original.titleMedium?.copyWith(fontSize: 13),
      bodyLarge: original.bodyLarge?.copyWith(fontSize: 13),
      bodyMedium: original.bodyMedium?.copyWith(fontSize: 12),
      bodySmall: original.bodySmall
          ?.copyWith(fontSize: 11, color: scheme.onSurfaceVariant),
      labelLarge: original.labelLarge?.copyWith(fontSize: 12),
    );
    return base.copyWith(
      colorScheme: scheme,
      textTheme: text,
      scaffoldBackgroundColor: surface,
      canvasColor: card,
      iconTheme: IconThemeData(size: 18, color: scheme.onSurfaceVariant),
      visualDensity: VisualDensity.compact,
      appBarTheme: AppBarTheme(
          backgroundColor: surface,
          foregroundColor: scheme.onSurface,
          iconTheme: IconThemeData(size: 18, color: scheme.onSurface),
          titleTextStyle: text.titleLarge,
          toolbarHeight: 42,
          scrolledUnderElevation: 0),
      listTileTheme: ListTileThemeData(
          dense: true,
          minVerticalPadding: 7,
          titleTextStyle: text.bodyLarge,
          subtitleTextStyle: text.bodySmall,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12)),
      dialogTheme: DialogThemeData(
          backgroundColor: card,
          titleTextStyle: text.titleLarge,
          contentTextStyle: text.bodyMedium,
          insetPadding: const EdgeInsets.all(12),
          shape: const RoundedRectangleBorder(borderRadius: panelRadius)),
      inputDecorationTheme: const InputDecorationTheme(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          border: OutlineInputBorder(borderRadius: controlRadius)),
      segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        padding:
            const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
      )),
      scrollbarTheme: const ScrollbarThemeData(
          thumbVisibility: WidgetStatePropertyAll(false),
          trackVisibility: WidgetStatePropertyAll(false),
          thickness: WidgetStatePropertyAll(4)),
    );
  }

  static ThemeData theme(ThemeData base, Color accent) => base.copyWith(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        canvasColor: panel,
        cardColor: panel,
        colorScheme: ColorScheme.dark(
          primary: accent,
          onPrimary: const Color(0xff17261f),
          surface: background,
          onSurface: text,
          onSurfaceVariant: muted,
          outline: border,
          surfaceContainer: panel,
          surfaceContainerHighest: raised,
          error: const Color(0xfff1a9af),
        ),
        textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
        dividerColor: border,
        dividerTheme: const DividerThemeData(color: border, thickness: 1),
        iconTheme: const IconThemeData(size: 18, color: muted),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: const Size(32, 32),
            maximumSize: const Size(32, 32),
            padding: EdgeInsets.zero,
            foregroundColor: accent,
            shape: const RoundedRectangleBorder(borderRadius: controlRadius),
          ),
        ),
        switchTheme: SwitchThemeData(
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          trackOutlineColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? accent : muted,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: base.textTheme.labelLarge
                ?.copyWith(fontSize: 11, fontWeight: FontWeight.w500),
            shape: const RoundedRectangleBorder(borderRadius: controlRadius),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            side: const BorderSide(color: border),
            textStyle: base.textTheme.labelLarge?.copyWith(fontSize: 11),
            shape: const RoundedRectangleBorder(borderRadius: controlRadius),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          isDense: true,
          contentPadding: EdgeInsets.all(10),
          border: OutlineInputBorder(borderRadius: controlRadius),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: panel,
          shape: RoundedRectangleBorder(borderRadius: panelRadius),
        ),
      );
}

class MenuPanel extends StatelessWidget {
  const MenuPanel({
    super.key,
    required this.child,
    this.primary = false,
    this.padding = const EdgeInsets.all(12),
  });
  final Widget child;
  final bool primary;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: MenubarStyle.panel,
          gradient: primary
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xff2d393f), Color(0xff232c32)],
                )
              : null,
          border: Border.all(color: MenubarStyle.border),
          borderRadius: MenubarStyle.panelRadius,
        ),
        child: child,
      );
}

class MenuPower extends StatelessWidget {
  const MenuPower({
    super.key,
    required this.enabled,
    required this.label,
    required this.onPressed,
  });
  final bool enabled;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        toggled: enabled,
        child: IconButton.filledTonal(
          tooltip: '${enabled ? 'Выключить' : 'Включить'} $label',
          onPressed: onPressed,
          style: IconButton.styleFrom(
            minimumSize: const Size(40, 40),
            maximumSize: const Size(40, 40),
            backgroundColor: enabled
                ? Theme.of(context).colorScheme.primary.withValues(alpha: .09)
                : MenubarStyle.raised,
            foregroundColor: enabled
                ? Theme.of(context).colorScheme.primary
                : MenubarStyle.muted,
            side: BorderSide(
              color: enabled
                  ? Theme.of(context).colorScheme.primary
                  : MenubarStyle.border,
            ),
            shape: const CircleBorder(),
          ),
          icon: const Icon(Icons.power_settings_new_rounded, size: 20),
        ),
      );
}

class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.label,
    required this.trailing,
    this.icon,
    this.onTap,
    this.detail,
    this.divider = true,
  });
  final String label;
  final Widget trailing;
  final IconData? icon;
  final VoidCallback? onTap;
  final String? detail;
  final bool divider;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 46),
        decoration: BoxDecoration(
          border: divider
              ? const Border(bottom: BorderSide(color: MenubarStyle.border))
              : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: MenubarStyle.controlRadius,
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 16),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child:
                            Text(label, style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (detail != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 112),
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10, color: MenubarStyle.muted),
                  ),
                ),
              ),
            trailing,
          ],
        ),
      );
}
