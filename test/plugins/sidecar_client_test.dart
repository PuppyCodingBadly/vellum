import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vellum/plugins/sidecar_client.dart';

/// Polls [condition] until it holds, so tests can wait for stream delivery
/// without guessing a fixed delay.
Future<void> eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition did not become true within 5s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final fixturePath = File(
    '${Directory.current.path}/test/plugins/fixtures/echo_bridge.py',
  ).absolute.path;
  final crashFixturePath = File(
    '${Directory.current.path}/test/plugins/fixtures/crash_bridge.py',
  ).absolute.path;

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
        throwsA(
          isA<SidecarException>().having(
            (e) => e.message,
            'message',
            contains('kaboom'),
          ),
        ),
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
      // One crash is an ordinary crash, not a crash loop.
      expect(client.isHealthy, isTrue);
    });

    test('consecutive timeouts replace the wedged process', () async {
      var restarts = 0;
      final client = makeClient(timeout: const Duration(milliseconds: 250));
      addTearDown(client.dispose);
      client.onRestart = () async => restarts++;
      expect(await client.ping(), 'pong');

      // The first process takes the request and never answers, as a wedged
      // sidecar does. Three timeouts in a row identify it and kill it.
      for (var i = 0; i < 3; i++) {
        await expectLater(
          client.call('stall', const {}),
          throwsA(isA<TimeoutException>()),
        );
      }
      expect(restarts, 1);
      // The replacement process answers, and the clincher: the stall method
      // no longer blocks because it is running in a new process.
      expect(
        await client.call(
          'stall',
          const {},
          timeout: const Duration(seconds: 5),
        ),
        'awake',
      );
      expect(
        await client.call(
          'ping',
          const {},
          timeout: const Duration(seconds: 5),
        ),
        'pong',
      );
      expect(restarts, 1);
    });

    test('a crash loop stops after the restart budget', () async {
      final counter = File('${tmp.path}/starts.log');
      int starts() =>
          counter.existsSync() ? counter.readAsLinesSync().length : 0;

      final client = SidecarClient(
        command: ['python3', crashFixturePath, counter.path],
        timeout: const Duration(seconds: 5),
      );
      addTearDown(client.dispose);

      // Every request spawns the process, which dies at once and is retried
      // once. The initial spawn plus three restarts is the whole budget.
      for (var i = 0; i < 3; i++) {
        await expectLater(client.ping(), throwsA(isA<SidecarException>()));
      }
      expect(starts(), 4);
      expect(client.isHealthy, isFalse);

      // Stays down instead of respawning on every call...
      await expectLater(
        client.ping(),
        throwsA(
          isA<SidecarException>().having(
            (e) => e.message,
            'message',
            contains('start()'),
          ),
        ),
      );
      expect(starts(), 4);

      // ...until an explicit start() clears the unhealthy state.
      await client.start();
      expect(client.isHealthy, isTrue);
      await eventually(() => starts() == 5);
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
        client.call('ping', const {}),
        throwsA(isA<SidecarException>()),
      );
    });

    test(
      'stderr log is bounded and resets when the process restarts',
      () async {
        final client = makeClient();
        addTearDown(client.dispose);
        expect(await client.call('stderr', {'lines': 250}), 'ok');
        // Ready line plus 250 noise lines: only the newest 200 survive.
        await eventually(
          () =>
              client.stderrLog.length == 200 &&
              client.stderrLog.last == 'noise 249',
        );
        expect(client.stderrLog, hasLength(200));
        expect(client.stderrLog, isNot(contains('echo_bridge ready')));
        expect(client.stderrLog.first, 'noise 50');
        expect(() => client.stderrLog.add('injected'), throwsUnsupportedError);

        // A new process clears the buffer: the dead process's noise must not
        // masquerade as the current one's.
        expect(await client.call('die', const {}), 'survived');
        await eventually(
          () =>
              client.stderrLog.length == 1 &&
              client.stderrLog.single == 'echo_bridge ready',
        );
        expect(client.stderrLog, ['echo_bridge ready']);
      },
    );
  });

  group('findSidecarMain', () {
    late Directory app;
    late Directory launchedFrom;

    setUp(() {
      app = Directory('${tmp.path}/app')..createSync();
      launchedFrom = Directory('${tmp.path}/launched-from')..createSync();
    });

    String plantSidecar(Directory root) {
      final dir = Directory('${root.path}/sidecar')
        ..createSync(recursive: true);
      return (File('${dir.path}/main.py')..writeAsStringSync('pass')).path;
    }

    String executable() =>
        (File('${app.path}/vellum')..writeAsStringSync('')).path;

    test('bundled sidecar wins over a planted working-directory copy', () {
      final bundled = plantSidecar(app);
      plantSidecar(launchedFrom);

      final found = SidecarClient.findSidecarMain(
        executablePath: executable(),
        workingDirectory: launchedFrom.path,
        allowWorkingDirectory: true,
      );

      expect(found, File(bundled).resolveSymbolicLinksSync());
    });

    test('release resolution ignores the working directory', () {
      plantSidecar(launchedFrom);

      expect(
        SidecarClient.findSidecarMain(
          executablePath: executable(),
          workingDirectory: launchedFrom.path,
          allowWorkingDirectory: false,
        ),
        isNull,
      );
    });

    test('the debug fallback still finds a working-directory checkout', () {
      final planted = plantSidecar(launchedFrom);

      expect(
        SidecarClient.findSidecarMain(
          executablePath: executable(),
          workingDirectory: launchedFrom.path,
          allowWorkingDirectory: true,
        ),
        File(planted).resolveSymbolicLinksSync(),
      );
    });

    test('a sidecar linked outside the root is rejected', () {
      final outside = Directory('${tmp.path}/outside')..createSync();
      final target = plantSidecar(outside);
      Link('${app.path}/sidecar').createSync(outside.path);

      expect(File(target).existsSync(), isTrue);
      expect(
        SidecarClient.findSidecarMain(
          executablePath: executable(),
          allowWorkingDirectory: false,
        ),
        isNull,
      );
    });

    test('a non-regular main.py is rejected', () {
      Directory('${app.path}/sidecar/main.py').createSync(recursive: true);

      expect(
        SidecarClient.findSidecarMain(
          executablePath: executable(),
          allowWorkingDirectory: false,
        ),
        isNull,
      );
    });
  });
}
