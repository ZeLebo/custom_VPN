import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// One channel for native menu state, commands and existing Flutter editors.
final nativeMenu = NativeMenuChannel();

class NativeMenuChannel {
  static const channel = MethodChannel('customvpn/menubar');
  bool attached = false;
  bool legacyVisible = false;
  final legacyPresentation = ValueNotifier(false);
  int _revision = 0;
  int nextRevision() => ++_revision;

  void listen(Future<Object?> Function(MethodCall) handler) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'attach') attached = true;
      return handler(call);
    });
  }

  void detach() {
    attached = false;
    legacyVisible = false;
    legacyPresentation.value = false;
    channel.setMethodCallHandler(null);
  }

  Future<void> publish(String method, Object? value) async {
    if (attached) await channel.invokeMethod<void>(method, value);
  }

  void presentationChanged({required bool visible}) {
    legacyVisible = visible;
    legacyPresentation.value = visible;
    unawaited(publish('legacyVisible', {
      'visible': visible,
      'revision': nextRevision(),
    }).catchError((Object error) {
      debugPrint('Native menu presentation: $error');
    }));
  }
}

/// Any existing editor, import or permission dialog remains visible, including
/// dialogs opened by deep links rather than by the native menu itself.
class NativeMenuNavigationObserver extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];
  void _changed() =>
      nativeMenu.presentationChanged(visible: _routes.length > 1);
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    }
    _changed();
  }
}
