import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/app.dart';
import 'package:scenova_console/models/review_queue.dart';
import 'package:scenova_console/services/console_services.dart';
import 'package:scenova_console/services/operator_auth.dart';
import 'package:scenova_console/services/review_api.dart';
import 'package:scenova_console/theme/app_theme.dart';

/// Sizes the test window to the console's Desktop device class, so a screen
/// lays out as designed rather than as a narrow window.
void useDesktopWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// An operator identity whose session the test controls, and which records the
/// sign-outs the console asks for.
class FakeOperatorAuth implements OperatorAuth {
  FakeOperatorAuth({OperatorSession? session}) {
    _session = session;
  }

  OperatorSession? _session;
  final StreamController<OperatorSession?> _changes =
      StreamController<OperatorSession?>.broadcast();

  /// How many times the console signed out.
  int signOuts = 0;

  /// How many times the identity provider was asked to sign in.
  int signIns = 0;

  /// The next outcome a sign-in returns, so the second-factor step can be
  /// driven without a provider.
  SignInOutcome outcome = const SignedIn();

  /// The failure a sign-in throws, when one is scripted.
  OperatorAuthException? signInFailure;

  /// The failure a second-factor submission throws, when one is scripted.
  OperatorAuthException? secondFactorFailure;

  /// Codes submitted to the second factor.
  final List<String> submittedCodes = <String>[];

  void setSession(OperatorSession? session) {
    _session = session;
    _changes.add(session);
  }

  @override
  OperatorSession? get current => _session;

  @override
  Stream<OperatorSession?> get changes => _changes.stream;

  @override
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
  }) async {
    signIns++;
    final failure = signInFailure;
    if (failure != null) throw failure;
    // The same validation the development verifier applies, so the screen's
    // empty-field path is exercised.
    if (email.trim().isEmpty) {
      throw const OperatorAuthException('Enter your email address.');
    }
    if (password.isEmpty) {
      throw const OperatorAuthException('Enter your password.');
    }
    if (outcome is SignedIn) {
      _session = OperatorSession(subject: email, email: email);
      _changes.add(_session);
    }
    return outcome;
  }

  @override
  Future<void> submitSecondFactor(String code) async {
    submittedCodes.add(code);
    final failure = secondFactorFailure;
    if (failure != null) throw failure;
    _session = const OperatorSession(
      subject: 'operator',
      email: 'curator@example.com',
    );
    _changes.add(_session);
  }

  @override
  void cancelSecondFactor() {}

  @override
  Future<String?> idToken() async => 'dev:curator:mfa:test';

  @override
  Future<void> signOut() async {
    signOuts++;
    _session = null;
    _changes.add(null);
  }

  void dispose() => _changes.close();
}

/// A review service that answers from a script, and records the queries.
class ScriptedReviewApi implements ReviewApi {
  ScriptedReviewApi({this.result, this.error});

  /// The page every request resolves to.
  ReviewQueuePage? result;

  /// The failure every request throws, when one is scripted.
  ReviewApiException? error;

  /// Every query the console sent.
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  @override
  Future<ReviewQueuePage> queue({
    ReviewReason? reason,
    ReviewState? state,
    String? word,
    int page = 1,
  }) async {
    requests.add(<String, Object?>{
      'reason': reason?.wireValue,
      'state': state?.wireValue,
      'word': word,
      'page': page,
    });
    final failure = error;
    if (failure != null) throw failure;
    // The service answers for the page it was asked for, as the real one does.
    final base = result ?? emptyPage;
    return ReviewQueuePage(
      items: base.items,
      openCount: base.openCount,
      page: page,
      pageCount: base.pageCount,
    );
  }
}

/// A review service whose first response the test completes, for the loading
/// state.
class DelayedReviewApi implements ReviewApi {
  final Completer<ReviewQueuePage> completer = Completer<ReviewQueuePage>();

  @override
  Future<ReviewQueuePage> queue({
    ReviewReason? reason,
    ReviewState? state,
    String? word,
    int page = 1,
  }) => completer.future;
}

/// A queue with nothing in it.
const ReviewQueuePage emptyPage = ReviewQueuePage(
  items: <QueueItem>[],
  openCount: 0,
  page: 1,
  pageCount: 1,
);

/// A queue page carrying [items], with a count and paging the test sets.
ReviewQueuePage pageOf(
  List<QueueItem> items, {
  int? openCount,
  int page = 1,
  int pageCount = 1,
}) {
  return ReviewQueuePage(
    items: items,
    openCount: openCount ?? items.length,
    page: page,
    pageCount: pageCount,
  );
}

/// A queue item, for seeding a page.
QueueItem queueItem({
  String entryId = 'entry-bank-2',
  String lemma = 'bank',
  String senseLabel = '2',
  String reason = 'wrong_meaning',
  Duration age = const Duration(hours: 3),
  ReviewState state = ReviewState.queued,
}) {
  return QueueItem(
    entryId: entryId,
    lemma: lemma,
    senseLabel: senseLabel,
    reason: reason,
    queuedAt: DateTime.now().toUtc().subtract(age),
    state: state,
  );
}

/// Wires the console with the given collaborators and pumps it.
Future<ConsoleServices> pumpConsole(
  WidgetTester tester, {
  required OperatorAuth auth,
  required ReviewApi reviewApi,
}) async {
  useDesktopWindow(tester);
  final services = ConsoleServices(auth: auth, reviewApi: reviewApi);
  await tester.pumpWidget(ConsoleApp(services: services));
  await tester.pump();
  return services;
}

/// Pumps a widget under the console's real theme, without the app shell.
Future<void> pumpThemed(WidgetTester tester, Widget child) async {
  useDesktopWindow(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness: Brightness.light),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
}

/// Tears the tree down so no controller or timer outlives the test.
Future<void> teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}
