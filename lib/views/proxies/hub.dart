import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/views/profiles/profiles.dart';
import 'package:flclashx/views/proxies/proxies.dart';
import 'package:flclashx/views/proxies/rules.dart';
import 'package:flclashx/views/proxies/section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Proxies tab: proxies, profiles and active rules in one place.
class ProxiesHubView extends ConsumerWidget {
  const ProxiesHubView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(proxiesSectionProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<ProxiesSection>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: ProxiesSection.proxies,
                  label: Text(appLocalizations.proxies),
                ),
                ButtonSegment(
                  value: ProxiesSection.profiles,
                  label: Text(appLocalizations.profiles),
                ),
                const ButtonSegment(
                  value: ProxiesSection.rules,
                  label: Text('Правила'),
                ),
              ],
              selected: {section},
              onSelectionChanged: (value) =>
                  ref.read(proxiesSectionProvider.notifier).state = value.first,
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: section.index,
            children: const [
              ProxiesView(key: GlobalObjectKey(PageLabel.proxies)),
              ProfilesView(key: GlobalObjectKey(PageLabel.profiles)),
              RulesView(),
            ],
          ),
        ),
      ],
    );
  }
}
