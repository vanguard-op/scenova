import 'package:flutter/widgets.dart';

import '../config.dart';
import 'operator_auth.dart';
import 'review_api.dart';

/// The collaborators the console wires together.
@immutable
class ConsoleServices {
  const ConsoleServices({required this.auth, required this.reviewApi});

  /// The operator's identity (`C-014` auth).
  final OperatorAuth auth;

  /// The review surface (`C-014`).
  final ReviewApi reviewApi;

  /// Wires the console from its build-time configuration.
  ///
  /// The identity follows [ConsoleConfig.useFirebaseAuth]: a release build
  /// authenticates through the identity provider, a local debug run through the
  /// gateway's own development verifier. The review API follows
  /// [ConsoleConfig.useMockReviewApi]. A live gateway is refused in the clear
  /// before the first request, so the operator's token is never sent over
  /// plaintext (`NFR-022`).
  factory ConsoleServices.fromConfig({
    OperatorAuth? auth,
    ReviewApi? reviewApi,
  }) {
    final resolvedAuth =
        auth ??
        (ConsoleConfig.useFirebaseAuth
            ? FirebaseOperatorAuth()
            : DevOperatorAuth());
    if (reviewApi != null) {
      return ConsoleServices(auth: resolvedAuth, reviewApi: reviewApi);
    }
    if (ConsoleConfig.useMockReviewApi) {
      return ConsoleServices(
        auth: resolvedAuth,
        reviewApi: MockReviewApi(latency: ConsoleConfig.mockLatency),
      );
    }
    ConsoleConfig.ensureSecureApi(ConsoleConfig.reviewApiBaseUrl);
    return ConsoleServices(
      auth: resolvedAuth,
      reviewApi: HttpReviewApi(
        baseUrl: ConsoleConfig.reviewApiBaseUrl,
        idTokenProvider: resolvedAuth.idToken,
      ),
    );
  }
}

/// Provides the console's services to the tree.
///
/// The screens read the collaborators from here rather than taking them through
/// every constructor, so a screen is built the same way wherever it appears.
class ConsoleScope extends InheritedWidget {
  const ConsoleScope({super.key, required this.services, required super.child});

  final ConsoleServices services;

  static ConsoleServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ConsoleScope>();
    assert(scope != null, 'ConsoleScope is missing above this widget.');
    return scope!.services;
  }

  /// The services when a [ConsoleScope] is above this widget, or null.
  ///
  /// A screen that can also be driven by an injected controller — a test, or a
  /// host that already holds one — reads the scope this way rather than
  /// requiring it.
  static ConsoleServices? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConsoleScope>()?.services;

  @override
  bool updateShouldNotify(ConsoleScope oldWidget) =>
      services != oldWidget.services;
}
