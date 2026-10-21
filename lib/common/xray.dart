import 'dart:convert';

/// Some panels (e.g. Remnawave with an xray template) serve subscriptions as
/// an xray-core JSON array of full configs regardless of User-Agent, which
/// mihomo can't parse ("cannot unmarshal !!seq into config.RawConfig").
/// Converts such a subscription into a mihomo config: every supported proxy
/// outbound becomes a proxy, all of them in one select group, `MATCH` to it.
/// Returns null when [text] is not an xray JSON array.
String? xrayToMihomo(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('[')) return null;
  final Object? data;
  try {
    data = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (data is! List) return null;

  final proxies = <Map<String, dynamic>>[];
  final names = <String>{};
  for (final config in data.whereType<Map>()) {
    final outbounds = config['outbounds'];
    if (outbounds is! List) continue;
    final remarks = (config['remarks'] ?? 'Proxy').toString();
    for (final outbound in outbounds.whereType<Map>()) {
      final proxy = _proxy(outbound);
      if (proxy == null) continue;
      var name = remarks;
      for (var i = 2; names.contains(name); i++) {
        name = '$remarks $i';
      }
      names.add(name);
      proxies.add({'name': name, ...proxy});
    }
  }
  if (proxies.isEmpty) return null;

  const group = 'Proxy';
  // JSON is valid YAML, so mihomo reads this as is.
  return jsonEncode({
    'proxies': proxies,
    'proxy-groups': [
      {
        'name': group,
        'type': 'select',
        'proxies': [for (final proxy in proxies) proxy['name']],
      },
    ],
    'rules': ['MATCH,$group'],
  });
}

Map<String, dynamic>? _proxy(Map outbound) {
  final settings = outbound['settings'];
  if (settings is! Map) return null;
  final Map<String, dynamic> proxy;
  switch (outbound['protocol']) {
    case 'vless':
      final server = _first(settings['vnext']);
      final user = _first(server?['users']);
      if (server == null || user == null) return null;
      proxy = {
        'type': 'vless',
        'server': server['address'],
        'port': server['port'],
        'uuid': user['id'],
        if (_nonEmpty(user['flow'])) 'flow': user['flow'],
        if (_nonEmpty(settings['packetEncoding']))
          'packet-encoding': settings['packetEncoding'],
      };
    case 'vmess':
      final server = _first(settings['vnext']);
      final user = _first(server?['users']);
      if (server == null || user == null) return null;
      proxy = {
        'type': 'vmess',
        'server': server['address'],
        'port': server['port'],
        'uuid': user['id'],
        'alterId': user['alterId'] ?? 0,
        'cipher': _nonEmpty(user['security']) ? user['security'] : 'auto',
      };
    case 'trojan':
      final server = _first(settings['servers']);
      if (server == null) return null;
      proxy = {
        'type': 'trojan',
        'server': server['address'],
        'port': server['port'],
        'password': server['password'],
      };
    case 'shadowsocks':
      final server = _first(settings['servers']);
      if (server == null) return null;
      proxy = {
        'type': 'ss',
        'server': server['address'],
        'port': server['port'],
        'cipher': server['method'],
        'password': server['password'],
      };
    default:
      return null;
  }
  proxy['udp'] = true;
  final stream = outbound['streamSettings'];
  if (stream is Map && !_applyStream(proxy, stream)) return null;
  return proxy;
}

/// Maps xray streamSettings onto mihomo fields; false for unsupported setups.
bool _applyStream(Map<String, dynamic> proxy, Map stream) {
  final isTrojan = proxy['type'] == 'trojan';
  switch (stream['security']) {
    case null || 'none' || '':
      break;
    case 'tls':
      final tls = stream['tlsSettings'] is Map ? stream['tlsSettings'] as Map : {};
      if (!isTrojan) proxy['tls'] = true;
      if (_nonEmpty(tls['serverName'])) {
        proxy[isTrojan ? 'sni' : 'servername'] = tls['serverName'];
      }
      if (tls['allowInsecure'] == true) proxy['skip-cert-verify'] = true;
      if (_nonEmpty(tls['fingerprint'])) {
        proxy['client-fingerprint'] = tls['fingerprint'];
      }
      if (tls['alpn'] is List && (tls['alpn'] as List).isNotEmpty) {
        proxy['alpn'] = tls['alpn'];
      }
    case 'reality':
      final reality =
          stream['realitySettings'] is Map ? stream['realitySettings'] as Map : {};
      if (!isTrojan) proxy['tls'] = true;
      if (_nonEmpty(reality['serverName'])) {
        proxy[isTrojan ? 'sni' : 'servername'] = reality['serverName'];
      }
      proxy['reality-opts'] = {
        'public-key': reality['publicKey'],
        if (_nonEmpty(reality['shortId'])) 'short-id': reality['shortId'],
      };
      proxy['client-fingerprint'] =
          _nonEmpty(reality['fingerprint']) ? reality['fingerprint'] : 'chrome';
    default:
      return false;
  }

  switch (stream['network']) {
    case null || 'tcp' || 'raw':
      final tcp = stream['tcpSettings'] ?? stream['rawSettings'];
      final header = tcp is Map ? tcp['header'] : null;
      if (header is Map && header['type'] != null && header['type'] != 'none') {
        return false;
      }
    case 'ws':
      final ws = stream['wsSettings'] is Map ? stream['wsSettings'] as Map : {};
      final host = ws['host'] ?? (ws['headers'] is Map ? ws['headers']['Host'] : null);
      proxy['network'] = 'ws';
      proxy['ws-opts'] = {
        'path': ws['path'] ?? '/',
        if (_nonEmpty(host)) 'headers': {'Host': host},
      };
    case 'httpupgrade':
      final upgrade = stream['httpupgradeSettings'] is Map
          ? stream['httpupgradeSettings'] as Map
          : {};
      proxy['network'] = 'ws';
      proxy['ws-opts'] = {
        'path': upgrade['path'] ?? '/',
        if (_nonEmpty(upgrade['host'])) 'headers': {'Host': upgrade['host']},
        'v2ray-http-upgrade': true,
      };
    case 'grpc':
      final grpc =
          stream['grpcSettings'] is Map ? stream['grpcSettings'] as Map : {};
      proxy['network'] = 'grpc';
      proxy['grpc-opts'] = {'grpc-service-name': grpc['serviceName'] ?? ''};
    default:
      return false;
  }
  return true;
}

Map? _first(Object? list) =>
    list is List && list.isNotEmpty && list.first is Map ? list.first as Map : null;

bool _nonEmpty(Object? value) => value != null && value.toString().isNotEmpty;
