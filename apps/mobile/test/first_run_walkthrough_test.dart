import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/theme/colors.dart';
import 'package:scenova/theme/tokens.dart';
import 'package:scenova/widgets/first_run_walkthrough.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/harness.dart';

/// A video platform that opens the bundled clip and records what the walkthrough
/// asks of it, so the load, autoplay, looping, and reduce-motion behaviours are
/// exercised without a device.
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
            duration: const Duration(seconds: 10),
            size: const Size(720, 1280),
          ),
        );
      }
    });
    return events.stream;
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

/// Hosts the background full-bleed, the way Onboarding stacks it.
Widget host(Widget child) => MaterialApp(
  theme: AppTheme.build(
    brightness: Brightness.light,
    deviceClass: DeviceClass.mobile,
  ),
  home: Scaffold(body: child),
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

  testWidgets('runs on a seamless loop, silent', (tester) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(host(const FirstRunWalkthrough()));
    await open(tester);

    // The clip is put on a loop after it opens, muted, and started once.
    expect(platform.calls, contains('setLooping:true'));
    expect(platform.calls, contains('setVolume:0.0'));
    expect(platform.calls.where((call) => call == 'play').length, 1);
    // Nothing turns looping back off, so the loop closes without a seam.
    expect(
      platform.calls.lastWhere((call) => call.startsWith('setLooping')),
      'setLooping:true',
    );

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

    // The frame is drawn, but nothing plays and nothing loops.
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(platform.calls, isNot(contains('play')));
    expect(platform.calls, isNot(contains('setLooping:true')));

    await teardown(tester);
  });

  testWidgets('turning reduce motion on mid-view holds the clip', (
    tester,
  ) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(host(const FirstRunWalkthrough()));
    await open(tester);
    expect(platform.calls, contains('play'));

    await tester.pumpWidget(
      host(const FirstRunWalkthrough(reduceMotion: true)),
    );
    await open(tester);

    expect(platform.calls, contains('pause'));

    await teardown(tester);
  });

  testWidgets('turning reduce motion off resumes the seamless loop', (
    tester,
  ) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(
      host(const FirstRunWalkthrough(reduceMotion: true)),
    );
    await open(tester);
    expect(platform.calls, isNot(contains('play')));

    await tester.pumpWidget(host(const FirstRunWalkthrough()));
    await open(tester);

    expect(platform.calls, contains('setLooping:true'));
    expect(platform.calls, contains('play'));

    await teardown(tester);
  });

  testWidgets('shows the base surface when the clip cannot open', (
    tester,
  ) async {
    // No platform is registered, so the clip cannot be opened: the background
    // must fall back to the base surface rather than throw or leave a gap.
    await tester.pumpWidget(host(const FirstRunWalkthrough()));
    await open(tester);

    expect(find.byType(VideoPlayer), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox && widget.color == ScenovaColors.light.surface,
      ),
      findsOneWidget,
    );

    await teardown(tester);
  });

  testWidgets('stays out of the semantics tree', (tester) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(host(const FirstRunWalkthrough()));
    await open(tester);

    // Decorative motion behind the setup panel is never announced.
    expect(
      find.descendant(
        of: find.byType(FirstRunWalkthrough),
        matching: find.byType(ExcludeSemantics),
      ),
      findsOneWidget,
    );
    expect(find.byType(InkWell), findsNothing);

    await teardown(tester);
  });
}
