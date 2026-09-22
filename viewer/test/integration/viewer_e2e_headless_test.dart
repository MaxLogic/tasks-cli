/// Headless entry point for the end-to-end viewer scenarios.
///
/// Runs under the plain `flutter test` binding (flutter_tester): it creates no
/// window and the only keys involved are posted to the widget tree by the test
/// binding, so the machine stays usable while it runs. The harness
/// `viewer/tool/verify-windows.ps1` supplies the fixture through
/// `--dart-define=TASKS_VIEWER_E2E_FIXTURE`; without it every case skips with
/// the prerequisite named.
library;

import 'viewer_e2e_scenarios.dart';

void main() {
  viewerE2eScenarios();
}
