import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

/// Application preferences: library location, appearance, and reader options.
class PreferencesDialog extends StatefulWidget {
  const PreferencesDialog({super.key});

  @override
  State<PreferencesDialog> createState() => _PreferencesDialogState();
}

class _PreferencesDialogState extends State<PreferencesDialog> {
  final TextEditingController _hexController = TextEditingController();

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  Future<void> _chooseLibraryDirectory(AppState app) async {
    String? directory;
    try {
      directory = await getDirectoryPath(
        initialDirectory: app.libraryDir,
        confirmButtonText: 'Choose',
      );
    } catch (_) {
      app.showToast('Cannot use that directory');
      return;
    }
    if (directory == null || directory.isEmpty || !mounted) return;
    final error = await app.switchLibraryDirectory(directory);
    if (!mounted) return;
    if (error != null) {
      app.showToast('Cannot use that directory');
    } else {
      app.showToast('Library location changed to $directory');
    }
  }

  Future<void> _importCalibre(AppState app) => app.chooseAndImportCalibre();

  String? _normalizeHex(String value) {
    final match = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(value.trim());
    if (match == null) return null;
    return '#${match.group(1)!.toLowerCase()}';
  }

  Future<void> _showCustomAccent(AppState app) async {
    _hexController.text =
        app.accentName.startsWith('#') ? app.accentName : '#3584e4';
    String? error;
    final color = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Custom accent color'),
          content: TextField(
            controller: _hexController,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Hex color',
              hintText: '#rrggbb',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final normalized = _normalizeHex(_hexController.text);
                if (normalized == null) {
                  setDialogState(() => error = 'Enter a color as #rrggbb');
                  return;
                }
                Navigator.of(dialogContext).pop(normalized);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (color != null) app.setAccentColor(color);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final theme = Theme.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Preferences', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: ListenableBuilder(
                  listenable: app,
                  builder: (context, _) => _buildBody(context, app),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppState app) {
    final theme = Theme.of(context);
    final scheme = switch (app.config.get('color_scheme')) {
      'light' => 'light',
      'dark' => 'dark',
      _ => 'system',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Library', theme),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Library directory'),
          subtitle: Text(app.libraryDir),
          trailing: TextButton(
            onPressed: () => _chooseLibraryDirectory(app),
            child: const Text('Choose…'),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Import calibre library'),
          subtitle: const Text(
            'Add books from a folder containing metadata.db',
          ),
          trailing: TextButton(
            onPressed:
                app.calibreImportRunning ? null : () => _importCalibre(app),
            child: const Text('Import…'),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show hidden books'),
          subtitle: const Text(
            'Hidden books stay in the library but are left out of the grid',
          ),
          value: app.showHidden,
          onChanged: (value) => app.setShowHidden(value),
        ),
        _sectionTitle('Appearance', theme),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text('Color scheme', style: theme.textTheme.bodyLarge),
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('System')),
                ButtonSegment(value: 'light', label: Text('Light')),
                ButtonSegment(value: 'dark', label: Text('Dark')),
              ],
              selected: {scheme},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  app.setColorScheme(selection.first),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Accent color', style: theme.textTheme.bodyLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final entry in AppState.accentPalette.entries)
              _buildSwatch(app, theme, entry.key, entry.value),
            OutlinedButton.icon(
              onPressed: () => _showCustomAccent(app),
              icon: const Icon(Icons.palette_outlined, size: 18),
              label: const Text('Custom…'),
            ),
          ],
        ),
        _sectionTitle('Reader', theme),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Page turn animation'),
          subtitle: const Text(
            'Slide between pages (disable on low-end hardware)',
          ),
          value: app.readerAnimation,
          onChanged: (value) => app.readerAnimation = value,
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, ThemeData theme) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Text(
          title,
          style: theme.textTheme.titleMedium
              ?.copyWith(color: theme.colorScheme.primary),
        ),
      );

  Widget _buildSwatch(
    AppState app,
    ThemeData theme,
    String name,
    Color color,
  ) {
    final selected = app.accentName == name;
    final label = name.isEmpty
        ? name
        : '${name[0].toUpperCase()}${name.substring(1)}';
    return Tooltip(
      message: label,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => app.setAccentColor(name),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  border: selected
                      ? Border.all(color: theme.colorScheme.onSurface, width: 3)
                      : null,
                ),
              ),
              if (selected)
                const Icon(Icons.check, size: 20, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}
