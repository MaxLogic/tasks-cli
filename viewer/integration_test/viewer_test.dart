/// Windowed entry point for the end-to-end viewer scenarios.
///
/// Contract: viewer/spec.md section 11, which names
/// `flutter test integration_test/viewer_test.dart -d windows`. That command
/// builds and runs a real Windows window, so it is only run with explicit
/// approval; the identical cases run headless through
/// `test/integration/viewer_e2e_headless_test.dart`, which is what
/// `viewer/tool/verify-windows.ps1` uses by default. Only the binding differs
/// between the two entry points.
library;

import 'package:integration_test/integration_test.dart';

import '../test/integration/viewer_e2e_scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  viewerE2eScenarios();
}
