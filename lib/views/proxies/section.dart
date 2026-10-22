import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sections of the Proxies tab.
enum ProxiesSection { proxies, profiles, rules }

final proxiesSectionProvider =
    StateProvider<ProxiesSection>((ref) => ProxiesSection.proxies);

/// True while the Proxies tab is open on [section]; sections use it instead of
/// isCurrentPage to own the app bar (actions, search, FAB).
final proxiesSectionActiveProvider =
    Provider.family<bool, ProxiesSection>((ref, section) =>
        ref.watch(currentPageLabelProvider) == PageLabel.proxies &&
        ref.watch(proxiesSectionProvider) == section);
