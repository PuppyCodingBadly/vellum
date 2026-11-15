import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'theme.dart';

/// Picks a library directory; injectable so tests avoid the platform dialog.
typedef DirectoryPicker =
    Future<String?> Function({
      String? initialDirectory,
      String? confirmButtonText,
    });

/// Application preferences: library location, appearance, and reader options.
class PreferencesDialog extends StatefulWidget {
  const PreferencesDialog({super.key, this.chooseDirectory = getDirectoryPath});

  /// Directory picker used by "Choose…"; production uses the platform dialog.
  final DirectoryPicker chooseDirectory;

  @override
  State<PreferencesDialog> createState() => _PreferencesDialogState();
}

class _PreferencesDialogState extends State<PreferencesDialog> {
  final TextEditingController _hexController = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _hexController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _chooseLibraryDirectory(AppState app) async {
    String? directory;
    try {
      directory = await widget.chooseDirectory(
        initialDirectory: app.libraryDir,
        confirmButtonText: 'Choose',
      );
    } catch (_) {
      app.showToast('Cannot use that directory');
      return;
    }
    if (directory == null || directory.isEmpty || !mounted) return;
    String? error;
    try {
      error = await app.switchLibraryDirectory(directory);
    } catch (failure) {
      // The switch can throw before it returns its own message.
      error = '$failure';
    }
    if (!mounted) return;
    app.showToast(error ?? 'Library location changed to $directory');
  }

  Future<void> _importCalibre(AppState app) => app.chooseAndImportCalibre();

  String? _normalizeHex(String value) {
    final match = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(value.trim());
    if (match == null) return null;
    return '#${match.group(1)!.toLowerCase()}';
  }

  Future<void> _showCustomAccent(AppState app) async {
    _hexController.text = app.accentName.startsWith('#')
        ? app.accentName
        : '#3584e4';
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
    final palette = context.palette;

    return Dialog(
      insetPadding: const EdgeInsets.all(VellumSpace.md),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                VellumSpace.lg,
                VellumSpace.md,
                VellumSpace.sm,
                VellumSpace.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Preferences',
                      style: VellumType.display(
                        24,
                        weight: FontWeight.w600,
                        height: 1.15,
                        letterSpacing: -0.3,
                        color: palette.text,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: palette.line),
            Flexible(
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(
                    VellumSpace.lg,
                    0,
                    VellumSpace.lg,
                    VellumSpace.xl,
                  ),
                  child: ListenableBuilder(
                    listenable: app,
                    builder: (context, _) => _buildBody(context, app),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppState app) {
    final palette = context.palette;
    final scheme = switch (app.config.get('color_scheme')) {
      'light' => 'light',
      'dark' => 'dark',
      _ => 'system',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Library', palette, first: true),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Library directory'),
          subtitle: Text(
            app.libraryDir,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: VellumType.mono(11.5, color: palette.textDim),
          ),
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
            onPressed: app.calibreImportRunning
                ? null
                : () => _importCalibre(app),
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
        _sectionTitle('Appearance', palette),
        const SizedBox(height: VellumSpace.xs),
        Row(
          children: [
            Expanded(
              child: Text(
                'Color scheme',
                style: VellumType.ui(13.5, color: palette.text),
              ),
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
        const SizedBox(height: VellumSpace.md),
        Text('Accent color', style: VellumType.ui(13.5, color: palette.text)),
        const SizedBox(height: VellumSpace.sm),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final entry in VellumAccents.named.entries)
              _buildSwatch(app, palette, entry.key, entry.value),
            // A custom accent is not one of the named swatches; show it so the
            // colour in effect stays visible and checkmarked.
            if (app.accentName.startsWith('#'))
              _buildSwatch(app, palette, app.accentName, app.accentColor),
            OutlinedButton.icon(
              onPressed: () => _showCustomAccent(app),
              icon: const Icon(Icons.palette_outlined, size: 17),
              label: const Text('Custom…'),
            ),
          ],
        ),
        _sectionTitle('Reader', palette),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Reflow PDF pages'),
          subtitle: const Text(
            'Wrap the original type to the window; pages without a text '
            'layer stay as images',
          ),
          value: app.pdfReflow,
          onChanged: (value) => app.pdfReflow = value,
        ),
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

  Widget _sectionTitle(
    String title,
    VellumPalette palette, {
    bool first = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: VellumSpace.md, bottom: 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!first) ...[
          Divider(height: 1, color: palette.line),
          const SizedBox(height: VellumSpace.md),
        ],
        Text(
          title,
          style: VellumType.ui(
            12.5,
            weight: FontWeight.w600,
            height: 1.2,
            color: palette.text,
          ),
        ),
      ],
    ),
  );

  Widget _buildSwatch(
    AppState app,
    VellumPalette palette,
    String name,
    Color color,
  ) {
    final selected = app.accentName == name;
    final label = name.isEmpty
        ? name
        : '${name[0].toUpperCase()}${name.substring(1)}';
    final onColor = readableInkOn(color);
    return Tooltip(
      message: label,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => app.setAccentColor(name),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? palette.text : Colors.transparent,
                    width: 1.5,
                  ),
                ),
              ),
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                child: selected
                    ? Icon(Icons.check, size: 15, color: onColor)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
