@TestOn('windows')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/cli_client.dart';

typedef _GetConsoleWindowNative = IntPtr Function();
typedef _GetConsoleWindow = int Function();

/// The console window of this test process, or 0 when it has none.
int _ownConsoleWindow() => DynamicLibrary.open('kernel32.dll')
    .lookupFunction<_GetConsoleWindowNative, _GetConsoleWindow>(
      'GetConsoleWindow',
    )();

/// The packaged viewer is a GUI app without a console. A console-subsystem
/// child such as tasks.exe must not get a console window of its own when the
/// production launcher starts it (Dart adds CREATE_NO_WINDOW). The child here
/// is powershell.exe, a console program like tasks.exe, that reports the
/// window of its console. The check is headless: no window may appear.
///
/// The check can only fail when this process has a console window itself:
/// without CREATE_NO_WINDOW the child would then share it and report it.
/// Without one (a GUI or detached runner) the check proves nothing, so it is
/// skipped.
void main() {
  final hasConsole = Platform.isWindows && _ownConsoleWindow() != 0;
  test(
    'SystemProcessLauncher gives a console child no console window',
    () async {
      final temp = await Directory.systemTemp.createTemp('viewer-console-');
      addTearDown(() => temp.delete(recursive: true));
      final script = File('${temp.path}${Platform.pathSeparator}probe.ps1');
      await script.writeAsString(r'''
Add-Type -Name W -Namespace P -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();'
"hwnd=$([P.W]::GetConsoleWindow())"
''');
      final handle = await const SystemProcessLauncher()
          .start('powershell.exe', <String>[
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            script.path,
          ]);
      await handle.closeStdin();
      final stderrText = handle.stderr.transform(utf8.decoder).join();
      final stdoutText = await handle.stdout.transform(utf8.decoder).join();
      expect(await handle.exitCode, 0, reason: await stderrText);
      expect(stdoutText.trim(), 'hwnd=0');
    },
    skip: hasConsole
        ? false
        : 'this runner has no console window; run from an interactive '
              'console to prove CREATE_NO_WINDOW',
  );
}
