/// One rule of the running config, e.g. `DOMAIN-SUFFIX,youtube.com,Zapret YouTube`.
class RuntimeRule {
  factory RuntimeRule.parse(String raw) {
    var rest = raw.trim();
    // trailing options like ",no-resolve" / ",src" are not part of the target
    for (final option in const [',no-resolve', ',src']) {
      if (rest.endsWith(option)) {
        rest = rest.substring(0, rest.length - option.length);
      }
    }
    final first = rest.indexOf(',');
    if (first < 0) return RuntimeRule._(rest, '', '');
    final last = rest.lastIndexOf(',');
    return RuntimeRule._(
      rest.substring(0, first),
      first == last ? '' : rest.substring(first + 1, last),
      rest.substring(last + 1),
    );
  }

  const RuntimeRule._(this.type, this.payload, this.target);

  final String type;
  final String payload;
  final String target;

  bool matches(String query) {
    final q = query.toLowerCase();
    return type.toLowerCase().contains(q) ||
        payload.toLowerCase().contains(q) ||
        target.toLowerCase().contains(q);
  }
}
