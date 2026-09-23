import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/platform/project_launch.dart';

void main() {
  test(
    'project launch passes a path as one argument without a shell',
    () async {
      final calls = <(String, List<String>)>[];
      final launcher = ProjectLauncher(
        start: (executable, arguments) async {
          calls.add((executable, arguments));
        },
      );
      const root = r'C:\Work space\A & B';

      await launcher.open(ProjectLaunchTarget.explorer, root);
      await launcher.open(ProjectLaunchTarget.alacritty, root);
      await launcher.open(ProjectLaunchTarget.terminal, root);

      expect(calls.length, 3);
      expect(calls[0].$1, 'explorer.exe');
      expect(calls[0].$2, <String>[root]);
      expect(calls[1].$1, 'alacritty.exe');
      expect(calls[1].$2, <String>['--working-directory', root]);
      expect(calls[2].$1, 'wt.exe');
      expect(calls[2].$2, <String>['-d', root]);
    },
  );

  test('project launch refuses an unbound path', () async {
    final launcher = ProjectLauncher(
      start: (_, _) async => fail('No process should start.'),
    );
    await expectLater(
      launcher.open(ProjectLaunchTarget.explorer, ''),
      throwsA(isA<FileSystemException>()),
    );
  });
}
