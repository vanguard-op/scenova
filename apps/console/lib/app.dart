import 'dart:async';

import 'package:flutter/material.dart';

import 'models/review_queue.dart';
import 'screens/review_entry_screen.dart';
import 'screens/review_queue_controller.dart';
import 'screens/review_queue_screen.dart';
import 'screens/sign_in_screen.dart';
import 'services/console_services.dart';
import 'services/operator_auth.dart';
import 'theme/app_theme.dart';
import 'widgets/console_shell.dart';

/// The console application: the theme, the operator gate, and the shell.
class ConsoleApp extends StatelessWidget {
  const ConsoleApp({super.key, required this.services});

  final ConsoleServices services;

  @override
  Widget build(BuildContext context) {
    return ConsoleScope(
      services: services,
      child: MaterialApp(
        title: 'Scenova review console',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(brightness: Brightness.light),
        darkTheme: AppTheme.build(brightness: Brightness.dark),
        themeMode: ThemeMode.system,
        home: const ConsoleGate(),
      ),
    );
  }
}

/// Shows the identity-provider sign-in until there is an operator session, then
/// the console.
///
/// A session that ends while the console is open — the token expires, or the
/// service refuses it — returns the operator here rather than leaving a screen
/// that can only fail (`docs/Scenova/screens/09-review-queue.md` →
/// Unauthenticated).
class ConsoleGate extends StatefulWidget {
  const ConsoleGate({super.key});

  @override
  State<ConsoleGate> createState() => _ConsoleGateState();
}

class _ConsoleGateState extends State<ConsoleGate> {
  StreamSubscription<OperatorSession?>? _subscription;
  OperatorSession? _session;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final auth = ConsoleScope.of(context).auth;
    _session = auth.current;
    _subscription = auth.changes.listen(
      (session) {
        if (mounted) setState(() => _session = session);
      },
      // A provider that cannot be reached leaves the operator on the sign-in
      // screen rather than throwing out of the stream; the next attempt reports
      // its own failure.
      onError: (Object _) {},
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) {
      return SignInScreen(auth: ConsoleScope.of(context).auth);
    }
    return ConsoleHome(session: session);
  }
}

/// The console's landing surface: the shell around the review queue, with the
/// entry it drills down into.
///
/// One queue controller feeds the table and the sidebar's open count, so the
/// count the sidebar shows is the count the table is paging through.
class ConsoleHome extends StatefulWidget {
  const ConsoleHome({super.key, required this.session});

  final OperatorSession session;

  @override
  State<ConsoleHome> createState() => _ConsoleHomeState();
}

class _ConsoleHomeState extends State<ConsoleHome> {
  ReviewQueueController? _queue;
  QueueItem? _openEntry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_queue != null) return;
    final services = ConsoleScope.of(context);
    _queue = ReviewQueueController(
      api: services.reviewApi,
      // A session that ends mid-request returns the operator to sign-in rather
      // than a screen that can only fail (`C-014`, 401).
      onSessionExpired: () => unawaited(services.auth.signOut()),
    );
    unawaited(_queue!.load());
  }

  @override
  void dispose() {
    _queue?.dispose();
    super.dispose();
  }

  void _openQueue() => setState(() => _openEntry = null);

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    if (queue == null) return const SizedBox.shrink();
    final auth = ConsoleScope.of(context).auth;

    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        final entry = _openEntry;
        return ConsoleShell(
          operatorLabel: widget.session.label,
          openCount: queue.status == ReviewQueueStatus.loaded
              ? queue.openCount
              : null,
          queueSelected: entry == null,
          onOpenQueue: _openQueue,
          onSignOut: () => unawaited(auth.signOut()),
          child: entry == null
              ? ReviewQueueScreen(
                  controller: queue,
                  onOpenEntry: (item) => setState(() => _openEntry = item),
                  onSignOut: () => unawaited(auth.signOut()),
                )
              : ReviewEntryScreen(item: entry, onBack: _openQueue),
        );
      },
    );
  }
}
