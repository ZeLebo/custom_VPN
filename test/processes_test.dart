import 'package:flclashx/common/processes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('wildcardMatch', () {
    test('matches exact names case-insensitively', () {
      expect(wildcardMatch('CODEX', 'codex'), isTrue);
      expect(wildcardMatch('codex', 'codex-host'), isFalse);
      expect(wildcardMatch('codex', 'my-codex'), isFalse);
      expect(wildcardMatch('', ''), isTrue);
      expect(wildcardMatch('', 'codex'), isFalse);
    });

    test('star matches zero or more characters, including slashes', () {
      expect(wildcardMatch('codex*', 'codex'), isTrue);
      expect(wildcardMatch('codex*', 'codex-code-mode-host'), isTrue);
      expect(wildcardMatch('/Apps/*/helper', '/apps/A/B/helper'), isTrue);
      expect(wildcardMatch('*', ''), isTrue);
      expect(wildcardMatch('*a', '*ba'), isTrue);
      expect(wildcardMatch('a**b*c', 'axybzc'), isTrue);
      expect(wildcardMatch('*ab?c', 'abXabYc'), isTrue);
      expect(wildcardMatch('a*b', 'abc'), isFalse);
    });

    test('question mark matches exactly one character', () {
      expect(wildcardMatch('a?c', 'AbC'), isTrue);
      expect(wildcardMatch('a?c', 'ac'), isFalse);
      expect(wildcardMatch('a?c', 'abbc'), isFalse);
      expect(wildcardMatch('a?b', 'a/b'), isTrue);
      expect(wildcardMatch('?', '😀'), isTrue);
    });

    test('treats regex punctuation literally', () {
      expect(wildcardMatch('Codex (*)', 'Codex (Renderer)'), isTrue);
      expect(wildcardMatch('a.b[1]', 'a.b[1]'), isTrue);
      expect(wildcardMatch('a.b[1]', 'axb1'), isFalse);
      expect(wildcardMatch('*', 'a\nb'), isTrue);
    });
  });

  group('suggestNamePattern', () {
    test('keeps a single or identical name exact', () {
      expect(suggestNamePattern(['codex']), 'codex');
      expect(suggestNamePattern(['codex', 'codex']), 'codex');
    });

    test('uses the longest common prefix', () {
      expect(suggestNamePattern(['codex', 'codex-code-mode-host']), 'codex*');
      expect(suggestNamePattern(['ab', 'abc', 'abd']), 'ab*');
    });

    test('uses the common suffix without overlapping the prefix', () {
      expect(suggestNamePattern(['Codex (Service)', 'Codex (Renderer)']),
          'Codex (*)');
      expect(suggestNamePattern(['aba', 'ababa']), 'aba*');
      expect(suggestNamePattern(['abc', 'xbc']), '*bc');
      expect(suggestNamePattern(['😀a', '😀b']), '😀*');
    });

    test('uses a star when there is no common prefix or suffix', () {
      expect(suggestNamePattern(['abc', 'xyz']), '*');
    });
  });

  group('suggestPathPattern', () {
    test('uses the directory even for a single executable', () {
      expect(suggestPathPattern(['/u/.local/share/claude/versions/2.1.309']),
          '/u/.local/share/claude/versions/*');
    });

    test('finds the deepest common directory by path components', () {
      expect(suggestPathPattern(['/u/bin/a', '/u/bin/b']), '/u/bin/*');
      expect(suggestPathPattern(['/u/bin/a', '/u/bin/helpers/b']), '/u/bin/*');
      expect(suggestPathPattern(['/u/bin/a', '/u/binary/b']), '/u/*');
      expect(suggestPathPattern(['/u/bin/a', '/u/bin/a']), '/u/bin/*');
    });

    test('falls back to the full-path pattern at the root', () {
      expect(suggestPathPattern(['/usr/bin/tool', '/opt/bin/tool']),
          suggestNamePattern(['/usr/bin/tool', '/opt/bin/tool']));
      expect(suggestPathPattern(['/a']), '/a');
      expect(suggestPathPattern(['/a', '/b']), '*');
    });
  });

  test('RunningProcess.name keeps the executable extension', () {
    expect(
      const RunningProcess(
        path: '/u/.local/share/claude/versions/2.1.309',
        network: false,
      ).name,
      '2.1.309',
    );
  });
}
