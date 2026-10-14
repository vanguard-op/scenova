import 'package:firebase_core/firebase_core.dart';

import '../config.dart';

/// Initialises the Firebase client from the build's project configuration.
///
/// The operator's identity (`C-014` auth) needs the client. It initialises
/// once: whichever seam asks first creates the app and any other adopts it.
///
/// The project configuration is a public project identifier, never a secret
/// that grants server access. When the build carries one it is passed
/// explicitly; when it does not, the client is initialised with no options and
/// `firebase_core` reads Hosting's `/__/firebase/init.json` at runtime, so the
/// deployed console needs no config baked into the bundle.
Future<FirebaseApp> initializeFirebaseClient() async {
  final existing = Firebase.apps;
  if (existing.isNotEmpty) return existing.first;
  if (!ConsoleConfig.hasFirebaseClientConfig) {
    return Firebase.initializeApp();
  }
  return Firebase.initializeApp(
    options: FirebaseOptions(
      projectId: ConsoleConfig.firebaseProjectId,
      authDomain: ConsoleConfig.firebaseAuthDomain,
      apiKey: ConsoleConfig.firebaseApiKey,
      appId: ConsoleConfig.firebaseAppId,
      messagingSenderId: ConsoleConfig.firebaseMessagingSenderId,
    ),
  );
}
