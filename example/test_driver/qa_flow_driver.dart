import 'package:integration_test/integration_test_driver.dart';

/// Host-side driver for `flutter drive`. Simply delegates to the default
/// integration test driver which connects to the instrumented app.
Future<void> main() => integrationDriver();
