import 'package:firebase_core/firebase_core.dart';

import '../firebase_options.dart';

/// Initialises the Firebase client from the build's project configuration.
///
/// The identity (`C-001`/`C-002` auth) and the device push token (`C-008`) both
/// need the client. It initialises once: whichever seam asks first creates the
/// app and the other adopts it, so a lookup and a notify offer share one client
/// and one subject (D-011).
///
/// The project configuration is the committed `firebase_options.dart`, so the
/// client carries only public project identifiers — never a secret that grants
/// server access (architecture → "Authentication & Authorization").
Future<FirebaseApp> initializeFirebaseClient() async {
  final existing = Firebase.apps;
  if (existing.isNotEmpty) return existing.first;
  return Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
}
