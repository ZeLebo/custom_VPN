import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/common/zapret_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late File status;
  late ZapretControl control;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('custom-vpn-control-test-');
    status = File('${temp.path}/status.json');
    control = ZapretControl(
        dataRoot: temp.path,
        statusFile: status,
        timeout: const Duration(seconds: 2));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, dynamic> settings(int revision, {bool enabled = true}) => {
        'enabled': enabled,
        'strategy': 'general-simple-fake',
        'ipset': 'none',
        'sites': [
          {'host': '$revision.example.com', 'exact': false, 'route': 'direct'}
        ],
        'customHosts': [],
        'udpBypassPorts': [],
        'vpnServers': ['1.1.1.1'],
      };

  Future<Map<String, dynamic>> waitRequest({String? after}) async {
    final file = File('${temp.path}/control-request.json');
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      if (file.existsSync()) {
        final req = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        if (req['id'] != after) return req;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('No new control request');
  }

  void acknowledge(Map<String, dynamic> req, {String error = ''}) {
    final data = req['settings'] as Map;
    File('${status.path}.tmp')
      ..writeAsStringSync(jsonEncode({
        'version': 1,
        'id': req['id'],
        'state': data['enabled'] == true ? 'running' : 'stopped',
        'settings': data,
        'error': error,
      }))
      ..renameSync(status.path);
  }

  test('applies repeated updates and reuses state after app restart', () async {
    String? lastID;
    for (var revision = 0; revision < 5; revision++) {
      final desired = settings(revision);
      final pending = control.apply(desired);
      final req = await waitRequest(after: lastID);
      expect(req['version'], 1);
      expect(req['settings'], desired);
      expect(control.matches(desired), isFalse);
      acknowledge(req);
      await pending;
      lastID = req['id'] as String;
      expect(control.matches(desired), isTrue);
    }
    final restarted = ZapretControl(dataRoot: temp.path, statusFile: status);
    expect(restarted.matches(settings(4)), isTrue);
  });

  test('serializes concurrent changes and ignores a stale acknowledgement',
      () async {
    final first = control.apply(settings(1));
    final second = control.apply(settings(2));
    final req1 = await waitRequest();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect((await waitRequest())['id'], req1['id']);
    acknowledge(req1);
    await first;
    final req2 = await waitRequest(after: req1['id'] as String);
    var completed = false;
    final watched = second.then((_) => completed = true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(completed, isFalse);
    acknowledge(req2);
    await watched;
    expect(control.matches(settings(2)), isTrue);
  });

  test('reports daemon failure and can retry afterwards', () async {
    final pending = control.apply(settings(1));
    final failure = expectLater(pending, throwsStateError);
    final req = await waitRequest();
    acknowledge(req, error: 'Engine config rejected');
    await failure;
    final retry = control.apply(settings(2));
    final next = await waitRequest(after: req['id'] as String);
    acknowledge(next);
    await retry;
    expect(control.matches(settings(2)), isTrue);
  });

  test('stopping is acknowledged without uninstalling the daemon', () async {
    final desired = settings(1, enabled: false);
    final pending = control.apply(desired);
    acknowledge(await waitRequest());
    await pending;
    expect(control.matches(desired), isTrue);
    expect(status.existsSync(), isTrue);
  });

  test('missing acknowledgement times out without pretending success',
      () async {
    final client = ZapretControl(
        dataRoot: temp.path,
        statusFile: status,
        timeout: const Duration(milliseconds: 120));
    await expectLater(
        client.apply(settings(1)), throwsA(isA<TimeoutException>()));
    expect(client.matches(settings(1)), isFalse);
  });

  test('an incompatible installed controller is an explicit error', () {
    status.writeAsStringSync('{"version":2}');
    expect(() => control.status, throwsStateError);
  });
}
