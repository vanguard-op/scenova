import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/models/review_queue.dart';
import 'package:scenova_console/widgets/status_badge.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

void main() {
  group('ReviewStatusBadge', () {
    testWidgets('labels each state, so it never rests on colour alone', (
      tester,
    ) async {
      for (final state in ReviewState.values) {
        await pumpThemed(tester, ReviewStatusBadge(state: state));
        expect(find.text(state.label), findsOneWidget);
      }
    });

    testWidgets('takes its colour from the state\'s semantic family', (
      tester,
    ) async {
      for (final entry in <(ReviewState, ScenovaSemanticColors)>[
        (ReviewState.queued, ScenovaColors.light.warning),
        (ReviewState.reviewed, ScenovaColors.light.info),
        (ReviewState.actioned, ScenovaColors.light.success),
      ]) {
        await pumpThemed(tester, ReviewStatusBadge(state: entry.$1));
        final container = tester.widget<Container>(
          find
              .ancestor(
                of: find.text(entry.$1.label),
                matching: find.byType(Container),
              )
              .first,
        );
        final decoration = container.decoration! as BoxDecoration;
        expect(decoration.color, entry.$2.tint);
        expect((decoration.border! as Border).top.color, entry.$2.border);
      }
    });
  });
}
