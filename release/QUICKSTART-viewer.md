# Try the Windows viewer

Extract the whole ZIP to a directory you own and run `tasks_viewer.exe`.
Keep its DLLs, `data` directory and matching `tasks.exe` together. No Flutter
or Rust SDK is needed. The viewer targets Windows 11 x64.

If Windows reports a missing Visual C++ runtime DLL, install Microsoft's
x64 Visual C++ Redistributable:
https://aka.ms/vs/17/release/vc_redist.x64.exe.

In Settings, select the bundled CLI and your task data root. To create a
backlog, use the CLI quickstart in `QUICKSTART-cli.md`. For a disposable trial,
follow the architect walkthrough linked there.

The viewer enables "Start with Windows" on its first normal packaged launch.
Turn it off in Settings if you only want to try the viewer. Move the bundle
before enabling startup; its next normal launch updates the owned shortcut
after a move.
Updates are manual: close the viewer, extract a new bundle into a new directory,
and launch it. Your task database and settings remain outside the bundle.

Keyboard controls and NVDA verification:
https://github.com/MaxLogic/tasks-cli/blob/main/viewer/README.md.
Flutter dependency notices are in `THIRD_PARTY_NOTICES-flutter.txt` and in the
application's Flutter license registry. CLI notices are included separately.
Audio attribution and provenance are in `AUDIO-NOTICE.md` and the assets.
