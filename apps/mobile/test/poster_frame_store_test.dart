import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/poster_frame_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// The poster frame is derived from a saved clip and kept on the device beside
/// its entry. These cover the paths that carry risk: a derivation that succeeds,
/// one that produces nothing, one that fails, and the sweep that keeps the
/// frames bounded by the history that owns them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('fc_native_video_thumbnail');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Bytes standing in for a decoded frame; the store only encodes and decodes
  /// them.
  final Uint8List frame = Uint8List.fromList(<int>[
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0x00,
  ]);

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    // The platform decoder is absent in a test; the default answers nothing.
    messenger.setMockMethodCallHandler(channel, (call) async => null);
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  void mockDecoder(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  test('capture derives a frame from the clip and keeps it', () async {
    final calls = <MethodCall>[];
    mockDecoder((call) async {
      calls.add(call);
      return frame;
    });

    final store = DevicePosterFrameStore();
    final key = await store.capture(
      clipUrl: 'https://clips.example/come.mp4',
      key: 'come-1',
    );

    expect(key, 'come-1');
    expect(calls.single.method, 'saveThumbnailToBytes');
    expect(calls.single.arguments['srcFile'], 'https://clips.example/come.mp4');
    expect(calls.single.arguments['srcFileUri'], isTrue);
    // The frame is derived card-sized, not at the clip's own resolution.
    expect(calls.single.arguments['width'], kPosterFrameWidth);
    expect(calls.single.arguments['height'], kPosterFrameHeight);
    expect(await store.frame('come-1'), frame);
  });

  test(
    'a source that is not a stream is never handed to the decoder',
    () async {
      var called = false;
      mockDecoder((call) async {
        called = true;
        return frame;
      });

      final store = DevicePosterFrameStore();
      final key = await store.capture(
        clipUrl: 'mock://clip/library-hit',
        key: 'come-1',
      );

      expect(key, isNull);
      expect(called, isFalse);
      expect(await store.frame('come-1'), isNull);
    },
  );

  test('a derivation that produces no frame keeps none', () async {
    final store = DevicePosterFrameStore();

    final key = await store.capture(
      clipUrl: 'https://clips.example/come.mp4',
      key: 'come-1',
    );

    expect(key, isNull);
    expect(await store.frame('come-1'), isNull);
  });

  test('a decoder that fails keeps no frame rather than throwing', () async {
    mockDecoder((call) async => throw PlatformException(code: 'PluginError'));

    final store = DevicePosterFrameStore();

    expect(
      await store.capture(
        clipUrl: 'https://clips.example/come.mp4',
        key: 'come-1',
      ),
      isNull,
    );
  });

  test('a kept frame survives a relaunch', () async {
    mockDecoder((call) async => frame);
    await DevicePosterFrameStore().capture(
      clipUrl: 'https://clips.example/come.mp4',
      key: 'come-1',
    );

    // A second store reads the same device document, as the next launch does.
    expect(await DevicePosterFrameStore().frame('come-1'), frame);
  });

  test('removing an entry removes its frame', () async {
    mockDecoder((call) async => frame);
    final store = DevicePosterFrameStore();
    await store.capture(clipUrl: 'https://clips.example/come.mp4', key: 'a');
    await store.capture(clipUrl: 'https://clips.example/bank.mp4', key: 'b');

    await store.remove('a');

    expect(await store.frame('a'), isNull);
    expect(await store.frame('b'), frame);
  });

  test('clearing history removes every frame', () async {
    mockDecoder((call) async => frame);
    final store = DevicePosterFrameStore();
    await store.capture(clipUrl: 'https://clips.example/come.mp4', key: 'a');
    await store.capture(clipUrl: 'https://clips.example/bank.mp4', key: 'b');

    await store.clear();

    expect(await store.frame('a'), isNull);
    expect(await store.frame('b'), isNull);
  });

  test('a frame for an entry the device no longer keeps is swept', () async {
    mockDecoder((call) async => frame);
    final store = DevicePosterFrameStore();
    await store.capture(clipUrl: 'https://clips.example/come.mp4', key: 'a');
    await store.capture(clipUrl: 'https://clips.example/bank.mp4', key: 'b');

    await store.pruneTo(<String>['b']);

    expect(await store.frame('a'), isNull);
    expect(await store.frame('b'), frame);
  });

  test('a frame the device cannot read reads as none', () async {
    await SharedPreferencesAsync().setString(
      'history.poster.come-1',
      'not base64',
    );

    expect(await DevicePosterFrameStore().frame('come-1'), isNull);
  });

  test('the in-memory store keeps what a scripted capture derives', () async {
    final store = InMemoryPosterFrameStore(onCapture: (clipUrl) async => frame);

    expect(
      await store.capture(clipUrl: 'https://clips.example/come.mp4', key: 'a'),
      'a',
    );
    expect(await store.frame('a'), frame);
  });

  test('the in-memory store derives nothing by default', () async {
    final store = InMemoryPosterFrameStore();

    expect(
      await store.capture(clipUrl: 'https://clips.example/come.mp4', key: 'a'),
      isNull,
    );
    expect(await store.frame('a'), isNull);
  });
}
