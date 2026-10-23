import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

Future<String?> showAppPicker(BuildContext context) =>
    globalState.showCommonDialog<String>(child: const _AppPicker());

class _AppPicker extends StatefulWidget {
  const _AppPicker();

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  late final Future<List<String>> _apps = _loadApps();
  String _query = '';

  Future<List<String>> _loadApps() async {
    final home = Platform.environment['HOME'];
    final paths = <String>{};
    for (final path in [
      '/Applications',
      '/Applications/Utilities',
      if (home != null) p.join(home, 'Applications'),
      '/System/Applications',
      '/System/Applications/Utilities',
    ]) {
      final directory = Directory(path);
      if (!directory.existsSync()) continue;
      await for (final entry in directory.list()) {
        if (entry is Directory && entry.path.endsWith('.app')) {
          paths.add(entry.path);
        }
      }
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
    if (path != null && mounted) Navigator.of(context).pop(path);
  }

  Future<void> _enterProcess() async {
    final value = await globalState.showCommonDialog<String>(
      child: InputDialog(
        title: 'Имя процесса',
        value: '',
        hintText: 'curl',
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
    if (value != null && mounted) Navigator.of(context).pop(value.trim());
  }

  @override
  Widget build(BuildContext context) => CommonDialog(
        title: 'Добавить приложение',
        overrideScroll: true,
        actions: [
          TextButton(onPressed: _pickFile, child: const Text('Выбрать…')),
          TextButton(
            onPressed: _enterProcess,
            child: const Text('Имя процесса…'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
        ],
        child: SizedBox(
          height: 400,
          child: Column(
            children: [
              TextField(
                decoration: const InputDecoration(hintText: 'Поиск'),
                onChanged: (value) =>
                    setState(() => _query = value.toLowerCase()),
              ),
              Expanded(
                child: FutureBuilder<List<String>>(
                  future: _apps,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const Center(
                        child: Text('Не удалось загрузить приложения'),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
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
                          onTap: () => Navigator.of(context).pop(path),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
}
