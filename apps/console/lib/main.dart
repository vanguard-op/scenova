import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app.dart';
import 'services/console_services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The console's screens are real paths — `/review`, `/review/entry/:entryId`
  // — and Hosting rewrites every unknown path to the SPA entry point, so a
  // bookmark or a pasted link opens the screen it names.
  if (kIsWeb) usePathUrlStrategy();
  runApp(ConsoleApp(services: ConsoleServices.fromConfig()));
}
