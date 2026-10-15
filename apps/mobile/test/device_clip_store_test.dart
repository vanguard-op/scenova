import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scenova/services/clip_store.dart';

/// A saved lookup keeps the clip itself on the device, so it replays with no
/// connection. These cover the paths that carry risk: a fetch that succeeds,
/// one that is refused, one that fails, the round-trip that survives a
/// relaunch, and the sweep that keeps the clips bounded by the history that
/// owns them.
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('scenova-clips');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  /// A client answering every request with [body] and [status].
  http.Client client({
    List<int> body = const <int>[1, 2, 3],
    int status = 200,
  }) {
    return MockClient((request) async => http.Response.bytes(body, status));
  }

  test('a clip is fetched and kept on the device', () async {
    final store = DeviceClipStore(
      client: client(),
      directoryOverride: directory,
    );

    final key = await store.save(
      clipUrl: 'https://clips.example/come.mp4',
      key: 'come-1',
    );

    expect(key, 'come-1');
    final source = await store.source('come-1');
    expect(source, isNotNull);
    // The device keeps the clip as a file the shared Clip Player opens without
    // a connection.
    expect(Uri.parse(source!).scheme, 'file');
    expect(await File.fromUri(Uri.parse(source)).readAsBytes(), <int>[1, 2, 3]);
  });

  test('a kept clip survives a relaunch', () async {
    await DeviceClipStore(
      client: client(),
      directoryOverride: directory,
    ).save(clipUrl: 'https://clips.example/come.mp4', key: 'come-1');

    // A second store reads the same device directory, as the next launch does.
    final source = await DeviceClipStore(directoryOverride: directory)
        .source('come-1');

    expect(source, isNotNull);
  });

  test('a source that is not a stream is never fetched', () async {
    var called = false;
    final store = DeviceClipStore(
      client: MockClient((request) async {
        called = true;
        return http.Response.bytes(<int>[1], 200);
      }),
      directoryOverride: directory,
    );

    final key = await store.save(
      clipUrl: 'mock://clip/library-hit',
      key: 'come-1',
    );

    expect(key, isNull);
    expect(called, isFalse);
    expect(await store.source('come-1'), isNull);
  });

  test('a fetch the service refuses keeps no clip', () async {
    final store = DeviceClipStore(
      client: client(status: 404),
      directoryOverride: directory,
    );

    expect(
      await store.save(
        clipUrl: 'https://clips.example/come.mp4',
        key: 'come-1',
      ),
      isNull,
    );
    expect(await store.source('come-1'), isNull);
  });

  test('an empty response keeps no clip', () async {
    final store = DeviceClipStore(
      client: client(body: const <int>[]),
      directoryOverride: directory,
    );

    expect(
      await store.save(
        clipUrl: 'https://clips.example/come.mp4',
        key: 'come-1',
      ),
      isNull,
    );
  });

  test('a fetch that fails keeps no clip rather than throwing', () async {
    final store = DeviceClipStore(
      client: MockClient(
        (request) async => throw const SocketException('down'),
      ),
      directoryOverride: directory,
    );

    expect(
      await store.save(
        clipUrl: 'https://clips.example/come.mp4',
        key: 'come-1',
      ),
      isNull,
    );
  });

  test('removing an entry removes its clip', () async {
    final store = DeviceClipStore(
      client: client(),
      directoryOverride: directory,
    );
    await store.save(clipUrl: 'https://clips.example/come.mp4', key: 'a');
    await store.save(clipUrl: 'https://clips.example/bank.mp4', key: 'b');

    await store.remove('a');

    expect(await store.source('a'), isNull);
    expect(await store.source('b'), isNotNull);
  });

  test('clearing history removes every clip', () async {
    final store = DeviceClipStore(
      client: client(),
      directoryOverride: directory,
    );
    await store.save(clipUrl: 'https://clips.example/come.mp4', key: 'a');
    await store.save(clipUrl: 'https://clips.example/bank.mp4', key: 'b');

    await store.clear();

    expect(await store.source('a'), isNull);
    expect(await store.source('b'), isNull);
  });

  test('a clip for an entry the device no longer keeps is swept', () async {
    final store = DeviceClipStore(
      client: client(),
      directoryOverride: directory,
    );
    await store.save(clipUrl: 'https://clips.example/come.mp4', key: 'a');
    await store.save(clipUrl: 'https://clips.example/bank.mp4', key: 'b');

    await store.pruneTo(<String>['b']);

    expect(await store.source('a'), isNull);
    expect(await store.source('b'), isNotNull);
  });

  test('a clip the device no longer holds reads as none', () async {
    final store = DeviceClipStore(directoryOverride: directory);

    expect(await store.source('never-saved'), isNull);
  });

  test('the in-memory store keeps what a scripted save produces', () async {
    final store = InMemoryClipStore(
      onSave: (clipUrl) async => 'file:///tmp/come.mp4',
    );

    expect(
      await store.save(clipUrl: 'https://clips.example/come.mp4', key: 'a'),
      'a',
    );
    expect(await store.source('a'), 'file:///tmp/come.mp4');
  });

  test('the in-memory store keeps nothing by default', () async {
    final store = InMemoryClipStore();

    expect(
      await store.save(clipUrl: 'https://clips.example/come.mp4', key: 'a'),
      isNull,
    );
    expect(await store.source('a'), isNull);
  });
}
