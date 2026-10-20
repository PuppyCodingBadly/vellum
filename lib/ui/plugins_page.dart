import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = AppState.of(context);
    if (_bootstrapped) return;
    _bootstrapped = true;
    _startPlugins(_appState!);
  }

  /// Loads the plugins already installed in the data directory, ignoring
  /// sidecar failures so the page always renders.
  Future<void> _startPlugins(AppState appState) async {
    try {
      await appState.plugins.start();
    } catch (_) {
      // Listing simply stays empty until the sidecar recovers.
    }
    if (mounted) setState(() {});
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
        final metadata = appState.plugins.metadataPlugins();
        final stores = appState.plugins.storePlugins();
        final isEmpty = metadata.isEmpty && stores.isEmpty;
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Installed Plugins',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _adding ? null : _addPlugin,
                        child: const Text('Add Plugin…'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: isEmpty
                        ? const _StatusPage(
                            icon: Icons.extension_outlined,
                            title: 'No Plugins Installed',
                            description:
                                'Add a plugin archive (.zip) to extend Vellum.',
                          )
                        : ListView(
                            padding: const EdgeInsets.only(bottom: 18),
                            children: [
                              for (final info in metadata)
                                _PluginRow(
                                  name: info.name.isEmpty
                                      ? 'Unnamed plugin'
                                      : info.name,
                                  subtitle: info.version.isEmpty
                                      ? info.description
                                      : 'v${info.version} · '
                                          '${info.description}',
                                  onRemove: () => _removePlugin(info.name),
                                ),
                              for (final store in stores)
                                _PluginRow(
                                  name: store.name.isEmpty
                                      ? 'Unnamed store'
                                      : store.name,
                                  subtitle: store.description.isEmpty
                                      ? 'Store plugin'
                                      : 'Store plugin · '
                                          '${store.description}',
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One plugin list row; metadata plugins carry a remove button, store
/// plugins carry none.
class _PluginRow extends StatelessWidget {
  const _PluginRow({
    required this.name,
    required this.subtitle,
    this.onRemove,
  });

  final String name;
  final String subtitle;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(name),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        trailing: onRemove == null
            ? null
            : IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove plugin',
                onPressed: onRemove,
              ),
      ),
    );
  }
}

/// Centered icon/title/description page used for empty plugin state.
class _StatusPage extends StatelessWidget {
  const _StatusPage({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
