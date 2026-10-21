import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vellum/plugins/sidecar_client.dart';

void main() {
  final fixturePath = File(
          '${Directory.current.path}/test/plugins/fixtures/echo_bridge.py')
      .absolute
      .path;

  late Directory tmp;
  late String markerPath;

  SidecarClient makeClient({Duration? timeout}) => SidecarClient(
        command: ['python3', fixturePath, markerPath],
        timeout: timeout ?? const Duration(seconds: 10),
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sidecar_client_test');
    markerPath = '${tmp.path}/died.marker';
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('SidecarClient protocol', () {
    test('ping returns pong', () async {
      final client = makeClient();
      addTearDown(client.dispose);
      expect(await client.ping(), 'pong');
    });

    test('loadAll returns typed plugin listing', () async {
      final client = makeClient();
      addTearDown(client.dispose);
      final loaded = await client.loadAll('/tmp/plugins');
      expect(loaded.metadata, hasLength(1));
      expect(loaded.metadata.single.name, 'FakeMeta');
      expect(loaded.metadata.single.version, '1.0');
      expect(loaded.metadata.single.description, 'fake metadata plugin');
      expect(loaded.stores, hasLength(1));
      expect(loaded.stores.single.name, 'FakeStore');
    });

    test('error key raises SidecarException', () async {
      final client = makeClient();
      addTearDown(client.dispose);
      expect(
        () => client.call('boom', const {}),
        throwsA(isA<SidecarException>()
            .having((e) => e.message, 'message', contains('kaboom'))),
      );
    });

    test('concurrent in-flight requests are matched by id', () async {
      final client = makeClient();
      addTearDown(client.dispose);
      // Slow request issued first; fast ones must overtake it and every
      // future must still resolve with its own value.
      final slow = client
          .call('delayed', {'seconds': 0.4, 'value': 'slow-one'})
          .then((v) => v as String);
      final fast1 = client
          .call('delayed', {'seconds': 0.05, 'value': 'fast-one'})
          .then((v) => v as String);
      final fast2 = client.ping();
      final results = await Future.wait([slow, fast1, fast2]);
      expect(results, ['slow-one', 'fast-one', 'pong']);
    });

    test('request timeout raises TimeoutException', () async {
      final client = makeClient(timeout: const Duration(milliseconds: 300));
      addTearDown(client.dispose);
      expect(
        () => client.call('slow', {'seconds': 5}),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('process dying mid-request is restarted once and retried', () async {
      final client = makeClient();
      addTearDown(client.dispose);
      // Warm the process up.
      expect(await client.ping(), 'pong');
      // 'die' kills the first process; the retry lands on the restarted
      // process (marker file now exists) and survives.
      final result = await client.call('die', const {});
      expect(result, 'survived');
      expect(await File(markerPath).exists(), isTrue);
      // The client is still usable afterwards.
      expect(await client.ping(), 'pong');
    });

    test('dispose while the process is spawning fails the call', () async {
      final client = makeClient();
      addTearDown(client.dispose);
      // call() kicks off Process.start and yields; dispose() runs before
      // the spawn completes, so the late process must be killed and the
      // waiting call failed instead of leaked.
      final future = client.call('ping', const {});
      await client.dispose();
      await expectLater(future, throwsA(isA<SidecarException>()));
      // No process was adopted: the client stays disposed and spawns nothing.
      await expectLater(
          client.call('ping', const {}), throwsA(isA<SidecarException>()));
    });

    test('stderr is captured into the log buffer', () async {
      final client = makeClient();
      addTearDown(client.dispose);
      await client.ping();
      // Give the stderr stream a moment to flush.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(client.stderrLog.join('\n'), contains('echo_bridge ready'));
    });
  });
}
