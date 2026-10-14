import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/theme/colors.dart';
import 'package:scenova/theme/tokens.dart';
import 'package:scenova/widgets/setup_sheet.dart';

import 'support/harness.dart';

/// The handle's touch region, from the branding sizing scale.
final double handleExtent = ScenovaSizing.mobile.buttonHeight;

/// The sheet's bottom padding below the content, from the layout spacing scale.
final double bottomPad = ScenovaSpacing.mobile.lg;

/// What stays on screen once the panel is lowered: the handle, the slice of the
/// setup content that keeps the panel's purpose apparent, and the panel's own
/// padding under the content.
final double loweredStrip =
    handleExtent +
    ScenovaSpacing.mobile.xxxl +
    ScenovaSpacing.mobile.xl +
    bottomPad;

/// Sizes the test window so a layout resolves against known numbers.
void useWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Hosts the sheet over a stand-in background, the way Onboarding stacks it.
Widget host({
  required Widget child,
  bool reduceMotion = false,
  Brightness brightness = Brightness.light,
}) {
  return MaterialApp(
    theme: AppTheme.build(
      brightness: brightness,
      deviceClass: DeviceClass.mobile,
    ),
    home: Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // A stand-in for the walkthrough clip, so the reveal is measurable.
            const ColoredBox(color: Color(0xFF2E8A5B)),
            SetupSheet(
              availableHeight: constraints.maxHeight,
              reduceMotion: reduceMotion,
              child: child,
            ),
          ],
        ),
      ),
    ),
  );
}

/// The sheet's drag handle, found without needing semantics enabled.
Finder handle() => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == 'Setup panel',
);

/// The solid surface the sheet paints, found by its shadow.
BoxDecoration sheetDecoration(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(SetupSheet),
        matching: find.byType(DecoratedBox),
      ),
    )
    .map((widget) => widget.decoration)
    .whereType<BoxDecoration>()
    .firstWhere((decoration) => decoration.boxShadow?.isNotEmpty ?? false);

SetupSheetState sheetState(WidgetTester tester) =>
    tester.state<SetupSheetState>(find.byType(SetupSheet));

double sheetTop(WidgetTester tester) =>
    tester.getTopLeft(find.byType(SetupSheet)).dy;

double sheetHeight(WidgetTester tester) =>
    tester.getRect(find.byType(SetupSheet)).height;

void main() {
  testWidgets('rests at the height of its content with the clip visible above', (
    tester,
  ) async {
    useWindow(tester, const Size(400, 900));
    await tester.pumpWidget(
      host(child: const SizedBox(height: 500, width: double.infinity)),
    );
    await tester.pump();

    // The sheet is its handle, its content, and the padding under the content.
    expect(sheetHeight(tester), closeTo(handleExtent + 500 + bottomPad, 0.5));
    // The clip's upper band stays visible above it.
    expect(
      sheetTop(tester),
      closeTo(900 - (handleExtent + 500 + bottomPad), 0.5),
    );
    expect(sheetTop(tester), greaterThan(0));

    await teardown(tester);
  });

  testWidgets(
    'the panel is solid at rest and at every position it can rest at',
    (tester) async {
      useWindow(tester, const Size(400, 900));
      await tester.pumpWidget(
        host(child: const SizedBox(height: 500, width: double.infinity)),
      );
      await tester.pump();

      final atRest = sheetDecoration(tester);
      expect(atRest.color, ScenovaColors.light.surface);
      expect(atRest.color!.a, 1.0);
      expect(atRest.boxShadow, isNotEmpty);

      // The panel stays opaque once it is dragged down to its lowered position.
      await tester.drag(handle(), const Offset(0, 600));
      await tester.pumpAndSettle();

      final revealed = sheetDecoration(tester);
      expect(revealed.color, ScenovaColors.light.surface);
      expect(revealed.color!.a, 1.0);
      // Never a translucent or blurred surface over the clip.
      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SetupSheet),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );

      await teardown(tester);
    },
  );

  testWidgets('the panel is solid in the dark theme too', (tester) async {
    useWindow(tester, const Size(400, 900));
    await tester.pumpWidget(
      host(
        brightness: Brightness.dark,
        child: const SizedBox(height: 500, width: double.infinity),
      ),
    );
    await tester.pump();

    final decoration = sheetDecoration(tester);
    expect(decoration.color, ScenovaColors.dark.surface);
    expect(decoration.color!.a, 1.0);

    await teardown(tester);
  });

  testWidgets('dragging down reveals the clip and lowers the panel', (
    tester,
  ) async {
    useWindow(tester, const Size(400, 900));
    await tester.pumpWidget(
      host(child: const SizedBox(height: 500, width: double.infinity)),
    );
    await tester.pump();

    final restTop = sheetTop(tester);

    await tester.drag(handle(), const Offset(0, 600));
    await tester.pumpAndSettle();

    expect(sheetState(tester).isLowered, isTrue);
    expect(sheetHeight(tester), closeTo(loweredStrip, 0.5));
    expect(sheetTop(tester), closeTo(900 - loweredStrip, 0.5));
    expect(sheetTop(tester), greaterThan(restTop));

    await teardown(tester);
  });

  testWidgets('the lowered panel keeps a slice of the setup content visible', (
    tester,
  ) async {
    useWindow(tester, const Size(400, 900));
    await tester.pumpWidget(
      host(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Setup content'),
            const SizedBox(height: 480, width: double.infinity),
          ],
        ),
      ),
    );
    await tester.pump();

    await tester.drag(handle(), const Offset(0, 600));
    await tester.pumpAndSettle();

    final sheet = tester.getRect(find.byType(SetupSheet));
    final viewport = tester.getRect(find.byType(SingleChildScrollView));

    // The panel is not reduced to its handle: setup content stays between the
    // handle and the padding, so the reader sees the panel carries setup.
    expect(sheet.height, greaterThan(handleExtent + bottomPad));
    expect(viewport.top, closeTo(sheet.top + handleExtent, 0.5));
    expect(viewport.bottom, closeTo(sheet.bottom - bottomPad, 0.5));
    // It is the head of the content that shows, not a slice from its middle.
    final head = tester.getRect(find.text('Setup content'));
    expect(head.top, closeTo(viewport.top, 0.5));
    expect(head.bottom, lessThanOrEqualTo(viewport.bottom));

    await teardown(tester);
  });

  testWidgets('dragging up returns the setup content to full height', (
    tester,
  ) async {
    useWindow(tester, const Size(400, 900));
    await tester.pumpWidget(
      host(child: const SizedBox(height: 500, width: double.infinity)),
    );
    await tester.pump();

    final restTop = sheetTop(tester);

    await tester.drag(handle(), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(sheetState(tester).isLowered, isTrue);

    await tester.drag(handle(), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(sheetState(tester).isLowered, isFalse);
    expect(sheetTop(tester), closeTo(restTop, 0.5));

    await teardown(tester);
  });

  testWidgets('the whole panel moves under the drag when the content fits', (
    tester,
  ) async {
    useWindow(tester, const Size(400, 900));
    await tester.pumpWidget(
      host(child: const SizedBox(height: 500, width: double.infinity)),
    );
    await tester.pump();

    final restTop = sheetTop(tester);

    // A drag on the content area, not just the handle.
    await tester.drag(find.byType(SetupSheet), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(sheetState(tester).isLowered, isTrue);
    expect(sheetTop(tester), greaterThan(restTop));

    await teardown(tester);
  });

  testWidgets('settles without a bounce', (tester) async {
    useWindow(tester, const Size(400, 900));
    await tester.pumpWidget(
      host(child: const SizedBox(height: 500, width: double.infinity)),
    );
    await tester.pump();

    final restTop = sheetTop(tester);

    // Past the halfway point, so the sheet settles at its lowered position.
    await tester.drag(handle(), const Offset(0, 320));

    final tops = <double>[];
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      tops.add(sheetTop(tester));
    }

    // The sheet approaches its rest in one movement: never past it, never back.
    final settled = tops.last;
    expect(settled, greaterThan(restTop));
    expect(tops.reduce(math.max), lessThanOrEqualTo(settled + 0.5));
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThanOrEqualTo(tops[i - 1] - 0.5));
    }
    expect(sheetState(tester).isLowered, isTrue);

    await teardown(tester);
  });

  testWidgets('under reduce motion it still moves and lands without a bounce', (
    tester,
  ) async {
    useWindow(tester, const Size(400, 900));
    await tester.pumpWidget(
      host(
        reduceMotion: true,
        child: const SizedBox(height: 500, width: double.infinity),
      ),
    );
    await tester.pump();

    await tester.drag(handle(), const Offset(0, 320));
    await tester.pump();

    // The panel follows the drag and lands at its rest in one step.
    expect(sheetState(tester).isLowered, isTrue);
    expect(sheetTop(tester), closeTo(900 - loweredStrip, 0.5));

    await tester.drag(handle(), const Offset(0, -320));
    await tester.pump();

    expect(sheetState(tester).isLowered, isFalse);
    expect(
      sheetTop(tester),
      closeTo(900 - (handleExtent + 500 + bottomPad), 0.5),
    );

    await teardown(tester);
  });

  testWidgets(
    'the content scrolls inside the sheet when taller than the room',
    (tester) async {
      useWindow(tester, const Size(400, 400));
      await tester.pumpWidget(
        host(child: const SizedBox(height: 900, width: double.infinity)),
      );
      await tester.pump();

      // The sheet keeps a band of the clip visible rather than filling the screen.
      expect(
        sheetHeight(tester),
        closeTo(400 - ScenovaSpacing.mobile.xxxl, 0.5),
      );

      // The content scrolls inside it rather than being cut off.
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.maxScrollExtent, greaterThan(0));

      await teardown(tester);
    },
  );

  testWidgets('the handle offers the rest positions without a drag', (
    tester,
  ) async {
    useWindow(tester, const Size(400, 900));
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      host(child: const SizedBox(height: 500, width: double.infinity)),
    );
    await tester.pump();

    tester.semantics.tap(find.semantics.byLabel('Setup panel'));
    await tester.pumpAndSettle();
    expect(sheetState(tester).isLowered, isTrue);

    tester.semantics.tap(find.semantics.byLabel('Setup panel'));
    await tester.pumpAndSettle();
    expect(sheetState(tester).isLowered, isFalse);

    semantics.dispose();
    await teardown(tester);
  });

  testWidgets('stays lowered when the content changes height', (tester) async {
    useWindow(tester, const Size(400, 900));
    await tester.pumpWidget(
      host(child: const SizedBox(height: 500, width: double.infinity)),
    );
    await tester.pump();

    await tester.drag(handle(), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(sheetState(tester).isLowered, isTrue);

    // The content grows while the panel is lowered.
    await tester.pumpWidget(
      host(child: const SizedBox(height: 700, width: double.infinity)),
    );
    await tester.pumpAndSettle();

    // The panel still sits at its lowered position over the clip, and still
    // keeps its slice of the content visible.
    expect(sheetState(tester).isLowered, isTrue);
    expect(sheetHeight(tester), closeTo(loweredStrip, 0.5));
    expect(sheetTop(tester), closeTo(900 - loweredStrip, 0.5));

    await teardown(tester);
  });
}
