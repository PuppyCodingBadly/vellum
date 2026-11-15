import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../plugins/plugin_controller.dart' show PluginInfo;
import 'theme.dart';

/// Plugins tab: lists loaded metadata and store plugins and lets the user
/// install or remove plugin archives.
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  AppState? _appState;
  bool _bootstrapped = false;
  bool _adding = false;
  String? _startError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = AppState.of(context);
    if (_bootstrapped) return;
    _bootstrapped = true;
    _startPlugins(_appState!);
  }

  /// Loads the plugins installed in the data directory.  A sidecar failure is
  /// kept and rendered as an error state with a retry, never as "no plugins".
  Future<void> _startPlugins(AppState appState) async {
    String? error;
    try {
      await appState.plugins.start();
    } catch (failure) {
      error = '$failure';
    }
    if (mounted) setState(() => _startError = error);
  }

  Future<void> _addPlugin() async {
    final appState = _appState;
    if (appState == null || _adding) return;
    setState(() => _adding = true);
    try {
      const typeGroup = XTypeGroup(
        label: 'Plugin archive',
        extensions: ['zip'],
      );
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      if (file == null || !mounted) return;
      final result = await appState.plugins.addPlugin(file.path);
      appState.showToast(
        result.kind == 'store'
            ? "Loaded store plugin '${result.name}' — see Get Books"
            : "Loaded plugin '${result.name}'",
      );
    } catch (e) {
      appState.showToast('Failed to load plugin: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _removePlugin(String name) async {
    final appState = _appState;
    if (appState == null) return;
    try {
      await appState.plugins.removePlugin(name);
      appState.showToast("Removed plugin '$name'");
    } catch (e) {
      appState.showToast("Failed to remove '$name': $e");
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppState.of(context);
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final palette = context.palette;
        final metadata = appState.plugins.metadataPlugins();
        final stores = appState.plugins.storePlugins();
        final isEmpty = metadata.isEmpty && stores.isEmpty;
        final Widget body;
        final startError = _startError;
        if (startError != null && isEmpty) {
          // Nothing loaded: the failure is the whole story, never "no plugins".
          body = _failure(palette, startError);
        } else if (isEmpty) {
          body = _empty(palette);
        } else {
          body = _installed(palette, metadata, stores);
        }
        return ColoredBox(
          color: palette.background,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  VellumSpace.xl,
                  VellumSpace.lg,
                  VellumSpace.xl,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Installed Plugins',
                                style: VellumType.display(
                                  30,
                                  weight: FontWeight.w600,
                                  height: 1.1,
                                  letterSpacing: -0.5,
                                  color: palette.text,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                'Calibre-compatible sources for metadata and stores.',
                                style: VellumType.ui(
                                  12.5,
                                  color: palette.textDim,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: VellumSpace.md),
                        FilledButton.icon(
                          onPressed: _adding ? null : _addPlugin,
                          icon: const Icon(Icons.add, size: 17),
                          label: const Text('Add Plugin…'),
                        ),
                      ],
                    ),
                    const SizedBox(height: VellumSpace.lg),
                    Expanded(child: body),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _installed(
    VellumPalette palette,
    List<PluginInfo> metadata,
    List<PluginInfo> stores,
  ) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (metadata.isNotEmpty) ...[
            _section('Metadata sources', palette),
            const SizedBox(height: VellumSpace.xs),
            _pluginList(palette, [
              for (final info in metadata)
                _PluginRow(
                  name: info.name.isEmpty ? 'Unnamed plugin' : info.name,
                  subtitle: info.version.isEmpty
                      ? info.description
                      : 'v${info.version} · ${info.description}',
                  onRemove: () => _removePlugin(info.name),
                ),
            ]),
          ],
          if (stores.isNotEmpty) ...[
            if (metadata.isNotEmpty) const SizedBox(height: VellumSpace.lg),
            _section('Stores', palette),
            const SizedBox(height: VellumSpace.xs),
            _pluginList(palette, [
              for (final store in stores)
                _PluginRow(
                  name: store.name.isEmpty ? 'Unnamed store' : store.name,
                  subtitle: store.description.isEmpty
                      ? 'Store plugin'
                      : 'Store plugin · ${store.description}',
                ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _section(String title, VellumPalette palette) {
    return Text(
      title,
      style: VellumType.display(
        19,
        weight: FontWeight.w600,
        height: 1.2,
        color: palette.text,
      ),
    );
  }

  Widget _pluginList(VellumPalette palette, List<Widget> rows) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: VellumRadius.largeAll,
        border: Border.all(color: palette.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: palette.line),
            rows[i],
          ],
        ],
      ),
    );
  }

  Widget _empty(VellumPalette palette) => _status(
    palette,
    icon: Icons.extension_outlined,
    title: 'No Plugins Installed',
    description: 'Add a plugin archive (.zip) to extend Vellum.',
  );

  Widget _failure(VellumPalette palette, String message) {
    final appState = _appState;
    return _status(
      palette,
      icon: Icons.error_outline,
      title: 'Plugins Unavailable',
      description: message,
      action: FilledButton(
        onPressed: appState == null ? null : () => _startPlugins(appState),
        child: const Text('Retry'),
      ),
    );
  }

  Widget _status(
    VellumPalette palette, {
    required IconData icon,
    required String title,
    required String description,
    Widget? action,
  }) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(VellumSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: palette.surfaceHigh,
                  shape: BoxShape.circle,
                  border: Border.all(color: palette.line),
                ),
                child: Icon(icon, size: 23, color: palette.textDim),
              ),
              const SizedBox(height: VellumSpace.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: VellumType.display(
                  22,
                  weight: FontWeight.w600,
                  height: 1.2,
                  color: palette.text,
                ),
              ),
              const SizedBox(height: VellumSpace.xs),
              Text(
                description,
                textAlign: TextAlign.center,
                style: VellumType.ui(13, height: 1.55, color: palette.textDim),
              ),
              if (action != null) ...[
                const SizedBox(height: VellumSpace.md),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One plugin list row; metadata plugins carry a remove button, store
/// plugins carry none.
class _PluginRow extends StatelessWidget {
  const _PluginRow({required this.name, required this.subtitle, this.onRemove});

  final String name;
  final String subtitle;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VellumSpace.md,
        vertical: 10,
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: palette.surfaceHigh,
              borderRadius: VellumRadius.smallAll,
              border: Border.all(color: palette.line),
            ),
            child: Icon(
              onRemove == null
                  ? Icons.storefront_outlined
                  : Icons.extension_outlined,
              size: 15,
              color: palette.textDim,
            ),
          ),
          const SizedBox(width: VellumSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VellumType.ui(
                    13.5,
                    weight: FontWeight.w600,
                    height: 1.35,
                    color: palette.text,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: VellumType.ui(
                      12,
                      height: 1.45,
                      color: palette.textDim,
                    ),
                  ),
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: 'Remove plugin',
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}
