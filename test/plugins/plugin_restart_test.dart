import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vellum/plugins/plugin_controller.dart';
import 'package:vellum/plugins/sidecar_client.dart';

void main() {
  test('plugin registry is reloaded before retried requests after a crash',
      () async {
    final tmp = Directory.systemTemp.createTempSync('plugin-restart-');
    final counter = File(p.join(tmp.path, 'loads.log'));
    final marker = File(p.join(tmp.path, 'died.marker'));
    final pluginDir = Directory(p.join(tmp.path, 'plugins'))..createSync();
    final fixture = File(
      p.join(Directory.current.path, 'test/plugins/fixtures/restart_bridge.py'),
    ).absolute.path;

    final client = SidecarClient(
      command: ['python3', fixture, counter.path, marker.path],
      timeout: const Duration(seconds: 10),
    );
    final controller = PluginController(pluginDir: pluginDir.path, client: client);
    try {
      await controller.start();
      expect(controller.metadataPlugins().single.name, 'FakeMeta');
      expect(counter.readAsLinesSync(), hasLength(1));

      // The request is in flight when the process dies; the client respawns
      // and retries it, and the controller must restore the registry first.
      expect(await client.call('die', const {}), 'survived');
      expect(counter.readAsLinesSync(), hasLength(2));

      // Without the reload the fresh process would answer
      // "plugin registry empty"; the controller's own API proves it answers.
      final hits = await controller.metadataSearch(title: 'x');
      expect(hits, hasLength(1));
      expect(hits.single['source'], 'FakeMeta');
    } finally {
      controller.dispose();
      await client.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  });
}
