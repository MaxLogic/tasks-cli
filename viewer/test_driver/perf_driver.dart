import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  final output = Platform.environment['TASKS_VIEWER_MOTION_OUTPUT'];
  if (output == null || output.isEmpty) {
    throw StateError(
      'Set TASKS_VIEWER_MOTION_OUTPUT to the owned external evidence JSON path.',
    );
  }
  await integrationDriver(
    responseDataCallback: (data) async {
      await File(
        output,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    },
  );
}
