import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flclashx/common/processes.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

Future<List<String>?> showAppPicker(BuildContext context) =>
    globalState.showCommonDialog<List<String>>(child: const _AppPicker());

class _AppPicker extends StatefulWidget {
  const _AppPicker();

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  late final Future<List<String>> _apps = _loadApps();
  final _pattern = TextEditingController();
  final _selectedPaths = <String>{};
  List<RunningProcess> _processes = [];
  bool _showProcesses = false;
  bool _processesLoaded = false;
  bool _loading = false;
  bool _onePattern = false;
  bool _byPath = false;
  bool _matchModeEdited = false;
  bool _patternEdited = false;
  String _query = '';

  List<RunningProcess> get _selected => _processes
      .where((process) => _selectedPaths.contains(process.path))
      .toList();

  List<String> get _values => _selected
      .map((process) => _byPath ? process.path : process.name)
      .toSet()
      .toList();

  String? get _patternError {
    if (_pattern.text.trim().isEmpty) return 'Введите шаблон';
    if (_pattern.text.contains(',')) {
      return 'Шаблон не должен содержать запятую';
    }
    if (isTooBroadPattern(_pattern.text)) {
      return 'Ловит все процессы: уточните шаблон или добавьте каждый отдельно';
    }
    return null;
  }

  @override
  void dispose() {
    _pattern.dispose();
    super.dispose();
  }

  void _suggestPattern() {
    if (_patternEdited || _selectedPaths.isEmpty) return;
    _pattern.text =
        _byPath ? suggestPathPattern(_values) : suggestNamePattern(_values);
  }

  void _selectionChanged() {
    if (_selectedPaths.isEmpty) {
      _byPath = false;
      _matchModeEdited = false;
      _patternEdited = false;
      _pattern.clear();
      return;
    }
    if (!_matchModeEdited) {
      final letters = RegExp(r'\p{L}', unicode: true);
      _byPath = _selected.any((process) => !letters.hasMatch(process.name));
    }
    _suggestPattern();
  }

  void _toggleProcess(RunningProcess process) {
    setState(() {
      if (!_selectedPaths.add(process.path)) {
        _selectedPaths.remove(process.path);
      }
      _selectionChanged();
    });
  }

  Future<void> _loadProcesses() async {
    setState(() {
      _loading = true;
      _processesLoaded = true;
    });
    final processes = await listProcesses();
    if (!mounted) return;
    setState(() {
      _processes = processes;
      _loading = false;
      _selectedPaths.retainAll(processes.map((process) => process.path));
      _selectionChanged();
    });
  }

  Future<List<String>> _loadApps() async {
    final home = Platform.environment['HOME'];
    final paths = <String>{};
    // Apps may be sorted into folders (/Applications/DEVELOPMENT/kitty.app);
    // bundles themselves are not entered.
    Future<void> scan(Directory directory, int depth) async {
      try {
        await for (final entry in directory.list(followLinks: false)) {
          if (entry is! Directory) continue;
          if (entry.path.endsWith('.app')) {
            paths.add(entry.path);
          } else if (depth < 3) {
            await scan(entry, depth + 1);
          }
        }
      } on FileSystemException {
        // unreadable folder
      }
    }

    for (final path in [
      '/Applications',
      if (home != null) p.join(home, 'Applications'),
      '/System/Applications',
    ]) {
      final directory = Directory(path);
      if (directory.existsSync()) await scan(directory, 0);
    }
    return paths.toList()
      ..sort((a, b) => p
          .basenameWithoutExtension(a)
          .toLowerCase()
          .compareTo(p.basenameWithoutExtension(b).toLowerCase()));
  }

  Future<void> _pickFile() async {
    final result = await globalState.safeRun(
      () => FilePicker.platform.pickFiles(initialDirectory: '/Applications'),
    );
    final path = result?.files.single.path;
    if (path != null && mounted) Navigator.of(context).pop([path]);
  }

  Future<void> _enterProcess() async {
    final value = await globalState.showCommonDialog<String>(
      child: InputDialog(
        title: 'Процесс или шаблон',
        value: '',
        hintText: 'curl, codex*, ~/.local/share/claude/versions/*',
        labelText: 'Имя или путь, * — любые символы',
        validator: (value) {
          if (value == null || value.trim().isEmpty) {
            return 'Введите имя процесса';
          }
          if (value.contains(',')) {
            return 'Имя процесса не должно содержать запятую';
          }
          return null;
        },
      ),
    );
    if (value == null || !mounted) return;
    var app = value.trim();
    final home = Platform.environment['HOME'];
    if (home != null && app.startsWith('~/')) {
      app = p.join(home, app.substring(2));
    }
    Navigator.of(context).pop([app]);
  }

  Widget _processList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final processes = _processes
        .where((process) =>
            process.name.toLowerCase().contains(_query) ||
            process.path.toLowerCase().contains(_query))
        .toList();
    return ListView.builder(
      itemCount: processes.length,
      itemBuilder: (context, index) {
        final process = processes[index];
        return ListItem(
          dense: true,
          padding: EdgeInsets.zero,
          leading: Checkbox(
            value: _selectedPaths.contains(process.path),
            onChanged: (_) => _toggleProcess(process),
          ),
          title: Text(process.name),
          subtitle: Text(
            process.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: process.network
              ? const Tooltip(
                  message: 'Есть соединения',
                  child: Icon(Icons.public, size: 16),
                )
              : null,
          onTap: () => _toggleProcess(process),
        );
      },
    );
  }

  Widget _selectionPanel() {
    final pattern = _pattern.text.trim();
    final matches = _onePattern && _patternError == null
        ? _processes
            .where((process) => wildcardMatch(
                  pattern,
                  _byPath ? process.path : process.name,
                ))
            .toList()
        : <RunningProcess>[];
    final extra = matches
        .where((process) => !_selectedPaths.contains(process.path))
        .toList();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
              segments: const [
                ButtonSegment(value: false, label: Text('Каждый отдельно')),
                ButtonSegment(value: true, label: Text('Одним шаблоном')),
              ],
              selected: {_onePattern},
              onSelectionChanged: (value) => setState(() {
                _onePattern = value.first;
                _suggestPattern();
              }),
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('По имени')),
                ButtonSegment(value: true, label: Text('По пути')),
              ],
              selected: {_byPath},
              onSelectionChanged: (value) => setState(() {
                _byPath = value.first;
                _matchModeEdited = true;
                _suggestPattern();
              }),
            ),
            const SizedBox(height: 8),
            if (_onePattern) ...[
              TextField(
                controller: _pattern,
                decoration: InputDecoration(
                  labelText: 'Шаблон',
                  errorText: _patternError,
                ),
                onChanged: (_) => setState(() => _patternEdited = true),
              ),
              Text('Совпадает: ${matches.length}'),
              if (matches.isNotEmpty)
                Text(matches.take(6).map((process) => process.name).join(', ')),
              if (extra.isNotEmpty)
                Text(
                  'Также поймает: '
                  '${extra.map((process) => process.name).join(', ')}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ] else
              Text('Добавится ${_values.length} правил'),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _onePattern && _patternError != null
                  ? null
                  : () => Navigator.of(context).pop(
                        _onePattern ? [pattern] : _values,
                      ),
              child: const Text('Добавить'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => CommonDialog(
        title: 'Добавить приложение',
        overrideScroll: true,
        actions: [
          TextButton(onPressed: _pickFile, child: const Text('Выбрать…')),
          TextButton(
            onPressed: _enterProcess,
            child: const Text('Процесс или шаблон…'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
        ],
        child: SizedBox(
          height: 520,
          child: Column(
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Приложения')),
                  ButtonSegment(value: true, label: Text('Процессы')),
                ],
                selected: {_showProcesses},
                onSelectionChanged: (value) async {
                  setState(() => _showProcesses = value.first);
                  if (_showProcesses && !_processesLoaded) {
                    await _loadProcesses();
                  }
                },
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(hintText: 'Поиск'),
                      onChanged: (value) =>
                          setState(() => _query = value.toLowerCase()),
                    ),
                  ),
                  if (_showProcesses)
                    IconButton(
                      tooltip: 'Обновить',
                      onPressed: _loading ? null : _loadProcesses,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                ],
              ),
              Expanded(
                child: _showProcesses
                    ? _processList()
                    : FutureBuilder<List<String>>(
                        future: _apps,
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return const Center(
                              child: Text('Не удалось загрузить приложения'),
                            );
                          }
                          if (!snapshot.hasData) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                          final apps = snapshot.data!
                              .where((path) => p
                                  .basenameWithoutExtension(path)
                                  .toLowerCase()
                                  .contains(_query))
                              .toList();
                          return ListView.builder(
                            itemCount: apps.length,
                            itemBuilder: (context, index) {
                              final path = apps[index];
                              return ListItem(
                                dense: true,
                                title: Text(p.basenameWithoutExtension(path)),
                                subtitle: Text(
                                  path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => Navigator.of(context).pop([path]),
                              );
                            },
                          );
                        },
                      ),
              ),
              if (_showProcesses && _selectedPaths.isNotEmpty)
                _selectionPanel(),
            ],
          ),
        ),
      );
}
