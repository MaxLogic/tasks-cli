@TestOn('windows')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/cli_client.dart';

typedef _GetConsoleWindowNative = IntPtr Function();
typedef _GetConsoleWindow = int Function();
typedef _AttachConsoleNative = Int32 Function(Uint32);
typedef _AttachConsole = int Function(int);
typedef _FreeConsoleNative = Int32 Function();
typedef _FreeConsole = int Function();

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
/// Attach the tester to the caller's console, which may be hidden. An
/// inheritStdio control child must report that same window, while the production
/// launcher child must report none. Without a console owner the check is skipped.
void main() {
  // CREATE_NO_WINDOW leaves flutter_tester attached to a windowless console.
  // Free that attachment before attaching to the caller's real console.
  final kernel = DynamicLibrary.open('kernel32.dll');
  final consoleOwner = Platform.environment['TASKS_VIEWER_CONSOLE_OWNER_PID'];
  final attach = kernel.lookupFunction<_AttachConsoleNative, _AttachConsole>(
    'AttachConsole',
    isLeaf: true,
  );
  final free = kernel.lookupFunction<_FreeConsoleNative, _FreeConsole>(
    'FreeConsole',
    isLeaf: true,
  );
  var attached = false;
  if (_ownConsoleWindow() == 0) {
    free();
    attached =
        attach(consoleOwner == null ? 0xffffffff : int.parse(consoleOwner)) !=
        0;
  }
  final consoleWindow = _ownConsoleWindow();
  final hasConsole = consoleWindow != 0;
  if (attached && !hasConsole) {
    free();
    attached = false;
  }
  final requireConsole =
      consoleOwner != null ||
      Platform.environment['TASKS_VIEWER_REQUIRE_CONSOLE'] == '1';
  test(
    'SystemProcessLauncher gives a console child no console window',
    () async {
      if (attached) {
        addTearDown(free);
      }
      expect(hasConsole, isTrue, reason: 'Console proof was required.');
      final temp = await Directory.systemTemp.createTemp('viewer-console-');
      addTearDown(() => temp.delete(recursive: true));
      final script = File('${temp.path}${Platform.pathSeparator}probe.ps1');
      await script.writeAsString(r'''
param([string]$OutPath)
Add-Type -Name W -Namespace P -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();'
$value = "hwnd=$([P.W]::GetConsoleWindow())"
if ($OutPath) { Set-Content -LiteralPath $OutPath -Value $value } else { $value }
''');
      final inheritedResult = File('${temp.path}/inherited.txt');
      final inherited = await Process.start('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-OutPath',
        inheritedResult.path,
      ], mode: ProcessStartMode.inheritStdio);
      expect(await inherited.exitCode, 0);
      expect(
        (await inheritedResult.readAsString()).trim(),
        'hwnd=$consoleWindow',
        reason: 'The control child must inherit the test console window.',
      );
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
      stdout.writeln(
        'console_window_proof: passed (inherited=$consoleWindow, normal=0)',
      );
    },
    skip: hasConsole || requireConsole
        ? false
        : 'this runner has no console window; run from an interactive '
              'console to prove CREATE_NO_WINDOW',
  );
}
