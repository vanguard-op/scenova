import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/theme/tokens.dart';
import 'package:scenova/widgets/app_icons.dart';
import 'package:scenova/widgets/brand_mark.dart';
import 'package:scenova/widgets/first_run_walkthrough.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/harness.dart';

/// A video platform that opens the bundled clip and records what the walkthrough
/// asks of it, so the load, autoplay, silence, one-shot, and reduce-motion
/// behaviours are exercised without a device.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events =
      <int, StreamController<VideoEvent>>{};

  /// Every call the controller made, in order.
  final List<String> calls = <String>[];

  /// The creation options the clip was opened with.
  VideoCreationOptions? creation;

  int _nextId = 1;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    creation = options;
    final id = _nextId++;
    _events[id] = StreamController<VideoEvent>.broadcast();
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final events = _events[playerId]!;
    // The controller subscribes as soon as this returns, so the initialized
    // event lands on a live listener.
    scheduleMicrotask(() {
      if (!events.isClosed) {
        events.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 12),
            size: const Size(1080, 1920),
          ),
        );
      }
    });
    return events.stream;
  }

  /// Emits an event to the open player, so a test can drive completion.
  void emit(VideoEvent event) {
    for (final events in _events.values) {
      if (!events.isClosed) events.add(event);
    }
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async =>
      calls.add('setLooping:$looping');

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      calls.add('setVolume:$volume');

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> seekTo(int playerId, Duration position) async =>
      calls.add('seekTo:${position.inMilliseconds}');

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    final events = _events.remove(playerId);
    await events?.close();
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();
}

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.build(
    brightness: Brightness.light,
    deviceClass: DeviceClass.mobile,
  ),
  home: Scaffold(body: Center(child: child)),
);

/// Pumps the microtasks the clip opens over, without advancing far enough for
/// the player's position timer to fire.
Future<void> open(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  late VideoPlayerPlatform original;

  setUp(() => original = VideoPlayerPlatform.instance);
  tearDown(() => VideoPlayerPlatform.instance = original);

  testWidgets('opens the bundled walkthrough asset, not the store preview', (
    tester,
  ) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(host(const FirstRunWalkthrough()));
    await open(tester);

    expect(platform.creation?.dataSource.asset, FirstRunWalkthrough.assetPath);
    expect(platform.creation?.dataSource.sourceType, DataSourceType.asset);

    await teardown(tester);
  });

  testWidgets('plays one silent pass and never loops', (tester) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(host(const FirstRunWalkthrough()));
    await open(tester);

    expect(platform.calls, contains('play'));
    expect(platform.calls, contains('setVolume:0.0'));
    expect(platform.calls, contains('setLooping:false'));
    expect(platform.calls, isNot(contains('setLooping:true')));
    expect(platform.calls.where((call) => call == 'play').length, 1);

    await teardown(tester);
  });

  testWidgets('holds on a still frame when reduce motion is on', (
    tester,
  ) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(
      host(const FirstRunWalkthrough(reduceMotion: true)),
    );
    await open(tester);

    expect(platform.calls, isNot(contains('play')));
    expect(findIcon(AppIcons.play), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('plays on tap when reduce motion is on', (tester) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(
      host(const FirstRunWalkthrough(reduceMotion: true)),
    );
    await open(tester);

    await tester.tap(find.byType(FirstRunWalkthrough));
    await open(tester);

    expect(platform.calls, contains('play'));

    await teardown(tester);
  });

  testWidgets('pauses on tap while it plays', (tester) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(host(const FirstRunWalkthrough()));
    await open(tester);
    expect(platform.calls, contains('play'));

    await tester.tap(find.byType(FirstRunWalkthrough));
    await open(tester);

    expect(platform.calls, contains('pause'));

    await teardown(tester);
  });

  testWidgets('offers a replay once the clip ends', (tester) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(host(const FirstRunWalkthrough()));
    await open(tester);

    platform.emit(VideoEvent(eventType: VideoEventType.completed));
    await open(tester);

    expect(findIcon(AppIcons.replay), findsOneWidget);
    expect(findIcon(AppIcons.play), findsNothing);

    await teardown(tester);
  });

  testWidgets('holds the mark when the clip cannot open', (tester) async {
    // No platform is registered, so the clip cannot be opened: the surface must
    // fall back rather than throw or leave an empty box.
    await tester.pumpWidget(host(const FirstRunWalkthrough()));
    await open(tester);

    expect(find.byType(BrandMark), findsOneWidget);
    expect(findIcon(AppIcons.play), findsNothing);

    await teardown(tester);
  });
}
