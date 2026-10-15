import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_design/scenova_design.dart';
import 'package:video_player/video_player.dart';

/// A clip the player can hold without a stream: an empty source is not
/// playable, so the surface keeps its still frame and no platform player is
/// opened.
class _StillClip implements ClipSource {
  const _StillClip({this.hasAudio = false});

  @override
  String get url => '';
  @override
  double get durationSeconds => 4;
  @override
  String get resolution => '360p';
  @override
  final bool hasAudio;
}

Future<void> pumpThemed(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ScenovaTheme.build(
        brightness: brightness,
        deviceClass: DeviceClass.mobile,
      ),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  group('Clip sources', () {
    test('a served clip and a device-kept clip are both playable', () {
      expect(isPlayableClipUrl('https://clips.example/come.mp4'), isTrue);
      expect(isPlayableClipUrl('http://10.0.2.2:8080/come.mp4'), isTrue);
      // A clip the device kept for offline replay opens from its own store.
      expect(
        isPlayableClipUrl('file:///data/user/0/app/files/clips/clip_come'),
        isTrue,
      );
    });

    test('a scripted or empty source is not playable', () {
      expect(isPlayableClipUrl('mock://clip/library-hit'), isFalse);
      expect(isPlayableClipUrl(''), isFalse);
    });
  });

  group('ClipPlayer', () {
    testWidgets('names what the surface is doing while it is not ready', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const ClipPlayer(status: ClipPlayerStatus.loading, caption: 'harbour'),
      );
      expect(find.text('Finding your clip'), findsOneWidget);

      await pumpThemed(
        tester,
        const ClipPlayer(
          status: ClipPlayerStatus.generating,
          caption: 'harbour',
        ),
      );
      expect(find.text('Making your clip'), findsOneWidget);

      await pumpThemed(
        tester,
        const ClipPlayer(
          status: ClipPlayerStatus.stillGenerating,
          caption: 'harbour',
        ),
      );
      expect(find.text('Still making your clip'), findsOneWidget);
    });

    testWidgets('offers a retry on the unavailable surface', (tester) async {
      var retried = false;
      await pumpThemed(
        tester,
        ClipPlayer(
          status: ClipPlayerStatus.unavailable,
          caption: 'harbour',
          onRetry: () => retried = true,
        ),
      );

      expect(find.text('No clip for this word yet.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(retried, isTrue);
    });

    testWidgets('takes the host\'s own line when the clip is withheld', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const ClipPlayer(
          status: ClipPlayerStatus.unavailable,
          caption: 'harbour',
          unavailableMessage: 'Saved clips need a connection to play.',
        ),
      );
      expect(
        find.text('Saved clips need a connection to play.'),
        findsOneWidget,
      );
    });

    testWidgets('a clip the platform cannot stream keeps the still frame', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        ClipPlayer(
          status: ClipPlayerStatus.ready,
          caption: 'harbour',
          clip: const _StillClip(),
          onTogglePlay: () {},
        ),
      );

      expect(find.byType(ClipStillFrame), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
    });

    testWidgets('a tap on the frame asks the host to play', (tester) async {
      var toggled = false;
      await pumpThemed(
        tester,
        ClipPlayer(
          status: ClipPlayerStatus.ready,
          caption: 'harbour',
          clip: const _StillClip(),
          onTogglePlay: () => toggled = true,
        ),
      );

      await tester.tap(find.byType(ClipPlayer));
      await tester.pump();
      expect(toggled, isTrue);
    });

    testWidgets('announces the frame as a play control for its word', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        ClipPlayer(
          status: ClipPlayerStatus.ready,
          caption: 'harbour',
          clip: const _StillClip(),
          onTogglePlay: () {},
        ),
      );

      expect(find.bySemanticsLabel('Play clip for harbour'), findsOneWidget);
    });

    testWidgets('holds on a still frame under reduce motion', (tester) async {
      await pumpThemed(
        tester,
        ClipPlayer(
          status: ClipPlayerStatus.ready,
          caption: 'harbour',
          clip: const _StillClip(),
          reduceMotion: true,
          onTogglePlay: () {},
        ),
      );

      expect(find.text('Tap to play'), findsOneWidget);
    });

    testWidgets('says a clip with audio is muted until sound is asked for', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        ClipPlayer(
          status: ClipPlayerStatus.ready,
          caption: 'harbour',
          clip: const _StillClip(hasAudio: true),
          onTogglePlay: () {},
        ),
      );
      expect(find.text('Muted'), findsOneWidget);

      await pumpThemed(
        tester,
        ClipPlayer(
          status: ClipPlayerStatus.ready,
          caption: 'harbour',
          clip: const _StillClip(hasAudio: true),
          soundOn: true,
          onTogglePlay: () {},
        ),
      );
      expect(find.text('Muted'), findsNothing);
    });

    testWidgets('draws its own controls, and Listen only when there is audio', (
      tester,
    ) async {
      var toggledSound = false;
      await pumpThemed(
        tester,
        ClipPlayer(
          status: ClipPlayerStatus.ready,
          caption: 'harbour',
          clip: const _StillClip(hasAudio: true),
          controls: true,
          onTogglePlay: () {},
          onToggleSound: () => toggledSound = true,
        ),
      );

      expect(find.text('Play'), findsOneWidget);
      expect(find.text('360p · 4 seconds'), findsOneWidget);
      await tester.tap(find.text('Listen'));
      await tester.pump();
      expect(toggledSound, isTrue);

      await pumpThemed(
        tester,
        ClipPlayer(
          status: ClipPlayerStatus.ready,
          caption: 'harbour',
          clip: const _StillClip(),
          controls: true,
          onTogglePlay: () {},
        ),
      );
      expect(find.text('Listen'), findsNothing);
    });
  });

  group('EmptyState', () {
    testWidgets('carries a headline, a line of guidance, and one action', (
      tester,
    ) async {
      var acted = false;
      await pumpThemed(
        tester,
        EmptyState(
          icon: AppIcons.history,
          headline: 'Nothing saved yet',
          body: 'Saved lookups appear here.',
          actionLabel: 'Look up a word',
          onAction: () => acted = true,
        ),
      );

      expect(find.text('Nothing saved yet'), findsOneWidget);
      expect(find.text('Saved lookups appear here.'), findsOneWidget);
      await tester.tap(find.text('Look up a word'));
      await tester.pump();
      expect(acted, isTrue);
    });

    testWidgets('leaves the action out when there is nowhere to go', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const EmptyState(
          icon: AppIcons.history,
          headline: 'Nothing saved yet',
          body: 'Saved lookups appear here.',
          actionLabel: 'Look up a word',
        ),
      );
      expect(find.text('Look up a word'), findsNothing);
    });
  });

  group('ErrorState', () {
    testWidgets('names the failure and offers a retry', (tester) async {
      var retried = false;
      await pumpThemed(
        tester,
        ErrorState(
          headline: 'That did not finish',
          body: 'Something went wrong.',
          onRetry: () => retried = true,
        ),
      );

      expect(find.text('That did not finish'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(retried, isTrue);
    });
  });

  group('StatusBadge', () {
    testWidgets('carries its state\'s words beside its colour', (tester) async {
      await pumpThemed(
        tester,
        const StatusBadge(
          label: 'Queued',
          icon: AppIcons.queued,
          family: ScenovaSemanticColors(
            element: ScenovaPalette.warning500Light,
            tint: ScenovaPalette.warning100Light,
            border: ScenovaPalette.warning300Light,
            pressed: ScenovaPalette.warning700Light,
            text: ScenovaPalette.warning900Light,
          ),
        ),
      );

      expect(find.text('Queued'), findsOneWidget);
      final container = tester.widget<Container>(
        find
            .ancestor(of: find.text('Queued'), matching: find.byType(Container))
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, ScenovaPalette.warning100Light);
      expect(
        (decoration.border! as Border).top.color,
        ScenovaPalette.warning300Light,
      );
    });
  });

  group('ScenovaButton', () {
    testWidgets('a disabled control takes no tap', (tester) async {
      var tapped = false;
      await pumpThemed(
        tester,
        ScenovaButton(
          label: 'Save',
          variant: ScenovaButtonVariant.primary,
          onPressed: null,
        ),
      );
      // The label is still on screen; the control just does not respond.
      expect(find.text('Save'), findsOneWidget);

      await pumpThemed(
        tester,
        ScenovaButton(
          label: 'Save',
          onPressed: () => tapped = true,
          isSubmitting: true,
        ),
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(tapped, isFalse);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('ScenovaButton — disabled tint', () {
    // The button table reduces a disabled control's background to its own
    // family's tinted shade. A destructive control must keep the error tint,
    // not borrow the primary one, in both themes.
    for (final brightness in Brightness.values) {
      final colors = ScenovaColors.resolve(brightness);
      testWidgets('a disabled Destructive keeps the error tint ($brightness)', (
        tester,
      ) async {
        await pumpThemed(
          tester,
          ScenovaButton(
            label: 'Retire',
            variant: ScenovaButtonVariant.destructive,
            onPressed: null,
          ),
          brightness: brightness,
        );

        final material = tester.widget<Material>(
          find
              .descendant(
                of: find.byType(ScenovaButton),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(material.color, colors.error.tint);
        expect(material.color, isNot(colors.primaryTint));

        await pumpThemed(
          tester,
          ScenovaButton(
            label: 'Retire',
            variant: ScenovaButtonVariant.primary,
            onPressed: null,
          ),
          brightness: brightness,
        );
        final primary = tester.widget<Material>(
          find
              .descendant(
                of: find.byType(ScenovaButton),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(primary.color, colors.primaryTint);
      });
    }
  });

  group('ScenovaButton — solid contrast', () {
    // The button table gives both solid variants the `on-solid` ink; the
    // accessibility target holds the label to 4.5:1 in both themes. This reads
    // the colours the button actually paints, not the token pair alone.
    for (final brightness in Brightness.values) {
      testWidgets('Primary and Destructive labels hold 4.5:1 ($brightness)', (
        tester,
      ) async {
        for (final variant in <ScenovaButtonVariant>[
          ScenovaButtonVariant.primary,
          ScenovaButtonVariant.destructive,
        ]) {
          await pumpThemed(
            tester,
            ScenovaButton(label: 'Act', variant: variant, onPressed: () {}),
            brightness: brightness,
          );

          final label = tester.widget<Text>(find.text('Act'));
          final material = tester.widget<Material>(
            find
                .descendant(
                  of: find.byType(ScenovaButton),
                  matching: find.byType(Material),
                )
                .first,
          );

          expect(
            _contrastRatio(label.style!.color!, material.color!),
            greaterThanOrEqualTo(4.5),
            reason: '$variant on $brightness',
          );
        }
      });
    }
  });

  group('SkeletonList', () {
    testWidgets('holds still when reduce motion is on', (tester) async {
      await pumpThemed(tester, const SkeletonList(rows: 3), reduceMotion: true);
      await tester.pump(const Duration(seconds: 2));

      expect(find.byType(SkeletonBlock), findsNWidgets(3));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('FocusRing', () {
    testWidgets('paints only while its control is focused', (tester) async {
      await pumpThemed(
        tester,
        const FocusRing(
          visible: true,
          radius: ScenovaRadius.md,
          child: SizedBox(width: 80, height: 32),
        ),
      );
      final painted = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(FocusRing),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(painted.foregroundPainter, isNotNull);

      await pumpThemed(
        tester,
        const FocusRing(
          visible: false,
          radius: ScenovaRadius.md,
          child: SizedBox(width: 80, height: 32),
        ),
      );
      final idle = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(FocusRing),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(idle.foregroundPainter, isNull);
    });
  });

  group('ConsoleShell', () {
    testWidgets('holds its chrome and hands the body the queue link', (
      tester,
    ) async {
      // The shell is the desktop posture; the default test window is narrower
      // than its sidebar and top bar.
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ScenovaTheme.build(
            brightness: Brightness.light,
            deviceClass: DeviceClass.desktop,
          ),
          home: ConsoleShell(
            operatorLabel: 'curator@example.com',
            openCount: 12,
            queueSelected: true,
            onOpenQueue: () => opened = true,
            onSignOut: () {},
            child: const Text('queue'),
          ),
        ),
      );

      expect(find.text('Scenova'), findsOneWidget);
      expect(find.text('Review console'), findsOneWidget);
      expect(find.text('curator@example.com'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('queue'), findsOneWidget);

      await tester.tap(find.text('Review queue'));
      await tester.pump();
      expect(opened, isTrue);
    });
  });
}

/// The WCAG 2.x contrast ratio between two opaque colours.
double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

double _relativeLuminance(Color color) {
  double channel(double value) => value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}
