import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/views/views.dart';
import 'package:flutter/material.dart';

class Navigation {

  factory Navigation() {
    _instance ??= Navigation._internal();
    return _instance!;
  }

  Navigation._internal();
  static Navigation? _instance;

  List<NavigationItem> getItems({
    bool openLogs = false,
    bool hasProxies = false,
  }) => [
      const NavigationItem(
        keep: false,
        icon: Icon(Icons.home_rounded),
        label: PageLabel.dashboard,
        view: DashboardView(
          key: GlobalObjectKey(PageLabel.dashboard),
        ),
      ),
      // Proxies, profiles and rules share one tab (PageLabel.profiles is
      // reached through it, see AppController.toProfiles).
      const NavigationItem(
        icon: Icon(Icons.travel_explore_rounded),
        label: PageLabel.proxies,
        view: ProxiesHubView(
          key: GlobalObjectKey('proxies-hub'),
        ),
      ),
      const NavigationItem(
        icon: Icon(Icons.swap_horiz_rounded),
        label: PageLabel.connections,
        view: ConnectionsView(
          key: GlobalObjectKey(
            PageLabel.connections,
          ),
        ),
        description: "connectionsDesc",
        modes: [NavigationItemMode.desktop, NavigationItemMode.more],
      ),
      const NavigationItem(
        icon: Icon(Icons.shield_rounded),
        label: PageLabel.zapret,
        view: ZapretView(
          key: GlobalObjectKey(
            PageLabel.zapret,
          ),
        ),
        // mobile = the compact menubar window
        modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
      ),
      const NavigationItem(
        icon: Icon(Icons.storage),
        label: PageLabel.resources,
        description: "resourcesDesc",
        view: ResourcesView(
          key: GlobalObjectKey(
            PageLabel.resources,
          ),
        ),
        modes: [NavigationItemMode.more],
      ),
      NavigationItem(
        icon: const Icon(Icons.adb),
        label: PageLabel.logs,
        view: const LogsView(
          key: GlobalObjectKey(
            PageLabel.logs,
          ),
        ),
        description: "logsDesc",
        modes: openLogs
            ? [NavigationItemMode.desktop, NavigationItemMode.more]
            : [],
      ),
      const NavigationItem(
        icon: Icon(Icons.settings_rounded),
        label: PageLabel.tools,
        view: ToolsView(
          key: GlobalObjectKey(
            PageLabel.tools,
          ),
        ),
        modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
      ),
    ];
}

final navigation = Navigation();
