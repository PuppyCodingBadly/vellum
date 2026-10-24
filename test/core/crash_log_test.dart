import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vellum/core/crash_log.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vellum-crash-log-');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('creates the data directory and appends timestamped stages', () {
    final nested = Directory(p.join(tempDir.path, 'data'));
    final log = CrashLog(nested);

    expect(log.stage('startup'), isTrue);
    expect(log.stage('run-app'), isTrue);

    final lines = log.file.readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines[0], endsWith('STAGE startup'));
    expect(lines[1], endsWith('STAGE run-app'));
    expect(RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(lines[0]), isTrue);
  });

  test('records the error and stack trace under the stage', () {
    final log = CrashLog(tempDir);
    final trace = StackTrace.fromString('#0  boom (package:vellum/x.dart:1:1)');

    expect(log.recordError('flutter', StateError('kaboom'), trace), isTrue);

    final text = log.file.readAsStringSync();
    expect(text, contains('ERROR [flutter] Bad state: kaboom'));
    expect(text, contains('#0  boom (package:vellum/x.dart:1:1)'));
    expect(text, endsWith('\n'));
  });

  test('truncates oversized stack traces', () {
    final log = CrashLog(tempDir);
    final trace = StackTrace.fromString('x' * (CrashLog.maxTraceLength + 100));

    log.recordError('zone', 'err', trace);

    final text = log.file.readAsStringSync();
    expect(text, contains('(truncated)'));
    expect(text.length, lessThan(CrashLog.maxTraceLength + 200));
  });

  test('returns false instead of throwing when the log cannot be written', () {
    final blocker = File(p.join(tempDir.path, 'blocker'))..writeAsStringSync('');
    final log = CrashLog(Directory(blocker.path));

    expect(log.stage('startup'), isFalse);
    expect(log.recordError('zone', 'err', StackTrace.current), isFalse);
  });

  testWidgets('a throwing button handler is logged and the app keeps running',
      (tester) async {
    final log = CrashLog(tempDir);
    final previousFlutterOnError = FlutterError.onError;
    final previousPlatformOnError = PlatformDispatcher.instance.onError;
    installCrashHandlers(log);
    addTearDown(() {
      FlutterError.onError = previousFlutterOnError;
      PlatformDispatcher.instance.onError = previousPlatformOnError;
    });

    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          TextButton(
            onPressed: () {
              taps++;
              throw StateError('handler blowup');
            },
            child: const Text('bad'),
          ),
          TextButton(
            onPressed: () => taps++,
            child: const Text('good'),
          ),
        ]),
      ),
    ));

    await tester.tap(find.text('bad'));
    await tester.pump();
    expect(
      log.file.readAsStringSync(),
      contains('ERROR [flutter] Bad state: handler blowup'),
    );

    // The session survives the throw: later interactions still work.
    await tester.tap(find.text('good'));
    await tester.pump();
    expect(taps, 2);
    expect(find.text('good'), findsOneWidget);
  });

  testWidgets('platform errors are logged and reported as handled',
      (tester) async {
    final log = CrashLog(tempDir);
    final previousFlutterOnError = FlutterError.onError;
    final previousPlatformOnError = PlatformDispatcher.instance.onError;
    installCrashHandlers(log);
    addTearDown(() {
      FlutterError.onError = previousFlutterOnError;
      PlatformDispatcher.instance.onError = previousPlatformOnError;
    });

    final handled = PlatformDispatcher.instance.onError!(
      StateError('uncaught async'),
      StackTrace.current,
    );

    expect(handled, isTrue);
    expect(
      log.file.readAsStringSync(),
      contains('ERROR [platform] Bad state: uncaught async'),
    );
  });
}
