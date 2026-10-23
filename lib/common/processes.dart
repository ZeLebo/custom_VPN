import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

class RunningProcess {
  const RunningProcess({required this.path, required this.network});

  final String path;
  final bool network;

  String get name => p.posix.basename(path);
}

/// Unique executable paths, with network processes first, then sorted by name.
Future<List<RunningProcess>> listProcesses() async {
  if (!Platform.isMacOS) return [];
  try {
    final lib = DynamicLibrary.process();
    final listPids = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)>('proc_listallpids');
    final pidPath = lib.lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)>('proc_pidpath');
    final count = listPids(nullptr, 0);
    if (count <= 0) return [];
    final capacity = count + count ~/ 4 + 32;
    final pids = calloc<Int32>(capacity);
    final paths = <int, String>{};
    try {
      final buffer = calloc<Uint8>(4096);
      try {
        final total = listPids(pids.cast(), capacity * sizeOf<Int32>());
        for (var i = 0; i < total && i < capacity; i++) {
          final pid = pids[i];
          if (pidPath(pid, buffer.cast(), 4096) <= 0) continue;
          paths[pid] = buffer.cast<Utf8>().toDartString();
        }
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(pids);
    }

    final networkPids = <int>{};
    try {
      final result = await Process.run(
        '/usr/sbin/lsof',
        ['-nP', '-iTCP', '-iUDP', '-Fp'],
      ).timeout(const Duration(seconds: 5));
      if (result.exitCode == 0) {
        for (final line in (result.stdout as String).split('\n')) {
          if (!line.startsWith('p')) continue;
          final pid = int.tryParse(line.substring(1));
          if (pid != null) networkPids.add(pid);
        }
      }
    } catch (_) {
      // Socket visibility is optional; keep the executable list on failure.
    }
    final networkPaths = {
      for (final pid in networkPids)
        if (paths.containsKey(pid)) paths[pid]!,
    };
    return [
      for (final path in paths.values.toSet())
        RunningProcess(path: path, network: networkPaths.contains(path)),
    ]..sort((a, b) {
        if (a.network != b.network) return a.network ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  } catch (_) {
    return [];
  }
}

/// Case-insensitive mihomo glob: `*` includes `/`, `?` matches one character.
bool wildcardMatch(String pattern, String value) {
  final glob = pattern.toLowerCase().runes.toList();
  final text = value.toLowerCase().runes.toList();
  var patternIndex = 0;
  var valueIndex = 0;
  var starIndex = -1;
  var starValueIndex = 0;
  while (valueIndex < text.length) {
    if (patternIndex < glob.length &&
        glob[patternIndex] != 0x2a &&
        (glob[patternIndex] == 0x3f ||
            glob[patternIndex] == text[valueIndex])) {
      patternIndex++;
      valueIndex++;
    } else if (patternIndex < glob.length && glob[patternIndex] == 0x2a) {
      starIndex = patternIndex++;
      starValueIndex = valueIndex;
    } else if (starIndex >= 0) {
      patternIndex = starIndex + 1;
      valueIndex = ++starValueIndex;
    } else {
      return false;
    }
  }
  while (patternIndex < glob.length && glob[patternIndex] == 0x2a) {
    patternIndex++;
  }
  return patternIndex == glob.length;
}

/// Common prefix and non-overlapping suffix, joined by a single `*`.
String suggestNamePattern(List<String> values) {
  if (values.every((value) => value == values.first)) return values.first;
  final names = values.map((value) => value.runes.toList()).toList();
  final shortest = names.map((name) => name.length).reduce(
        (a, b) => a < b ? a : b,
      );
  var prefix = 0;
  while (prefix < shortest &&
      names.every((name) => name[prefix] == names.first[prefix])) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < shortest - prefix &&
      names.every((name) =>
          name[name.length - suffix - 1] ==
          names.first[names.first.length - suffix - 1])) {
    suffix++;
  }
  return '${String.fromCharCodes(names.first.take(prefix))}*'
      '${String.fromCharCodes(names.first.skip(names.first.length - suffix))}';
}

/// Deepest common directory; avoid suggesting the root-wide `/*`.
String suggestPathPattern(List<String> paths) {
  var directory = p.posix.dirname(paths.first);
  for (final path in paths.skip(1)) {
    final parent = p.posix.dirname(path);
    while (directory != '/' &&
        directory != parent &&
        !p.posix.isWithin(directory, parent)) {
      directory = p.posix.dirname(directory);
    }
  }
  if (directory != '/') return p.posix.join(directory, '*');
  final pattern = suggestNamePattern(paths);
  return pattern == '/*' ? '*' : pattern;
}
