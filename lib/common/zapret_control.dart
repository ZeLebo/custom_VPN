import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart';

/// Exchanges data with the installed daemon. This path never elevates privileges.
class ZapretControl {
  ZapretControl({
    required this.dataRoot,
    required this.statusFile,
    this.timeout = const Duration(seconds: 30),
  });

  final String dataRoot;
  final File statusFile;
  final Duration timeout;
  Future<void> _pending = Future.value();

  Map<String, dynamic>? get status {
    if (!statusFile.existsSync()) return null;
    final value =
        jsonDecode(statusFile.readAsStringSync()) as Map<String, dynamic>;
    if (value['version'] != 1) {
      throw StateError('Несовместимая версия службы Zapret');
    }
    return value;
  }

  bool matches(Map<String, dynamic> settings) {
    final current = status;
    return current != null &&
        current['error'] == '' &&
        current['state'] ==
            (settings['enabled'] == true ? 'running' : 'stopped') &&
        jsonEncode(current['settings']) == jsonEncode(settings);
  }

  Future<void> apply(Map<String, dynamic> settings) {
    final next = _pending.then((_) => _apply(settings));
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> _apply(Map<String, dynamic> settings) async {
    final id =
        '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 30)}';
    final file = File(join(dataRoot, 'control-request.json'));
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(
        jsonEncode({
          'version': 1,
          'id': id,
          'settings': settings,
        }),
        flush: true);
    await pending.rename(file.path);
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      final current = status;
      if (current?['id'] == id) {
        final error = current!['error'] as String;
        if (error.isNotEmpty) throw StateError(error);
        if (!matches(settings)) {
          throw StateError('Служба Zapret не применила запрошенные настройки');
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException(
        'Служба Zapret не подтвердила применение настроек', timeout);
  }
}
