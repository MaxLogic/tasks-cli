/// Command scopes for modal dialogs.
///
/// A modal owns its own bindings and never forwards a background command
/// (viewer/design.md section 9). Installing [DialogCommandHost] inside the
/// dialog route is what makes that true structurally: the dialog scope is
/// closer to the focused control than the window scope, and an id the dialog
/// does not implement is consumed as a no-op instead of reaching the lists.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'commands.dart';

/// Runs one command id for a scope.
typedef CommandDispatch = KeyEventResult Function(String id);

/// Installs one dialog's shortcuts and actions.
class DialogCommandHost extends StatelessWidget {
  const DialogCommandHost({
    super.key,
    required this.scope,
    required this.onCommand,
    required this.child,
    this.onHotkeyHelp,
  });

  /// The dialog's own scope. Must satisfy [isDialogScope].
  final CommandScope scope;

  /// Handles ids owned by [scope] and the shared `dialogs.*` bindings.
  final CommandDispatch onCommand;

  /// Opens Help (F10) without activating the background window. The dialog
  /// keeps focus when Help closes.
  final Future<void> Function()? onHotkeyHelp;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    assert(isDialogScope(scope), 'DialogCommandHost needs a dialog scope.');
    return Shortcuts(
      shortcuts: shortcutMapForScope(scope),
      child: Actions(
        actions: commandActionsForScope(scope, _handle),
        child: child,
      ),
    );
  }

  KeyEventResult _handle(String id) {
    final spec = commandSpecById(id);
    if (spec == null) {
      return KeyEventResult.ignored;
    }
    if (spec.scope == CommandScope.dialogs || spec.scope == scope) {
      if (id == 'dialogs.hotkeyHelp' && onHotkeyHelp != null) {
        unawaited(onHotkeyHelp!());
        return KeyEventResult.handled;
      }
      return onCommand(id);
    }
    // Reserved window command that this dialog does not implement: keep the
    // key from reaching the background window, but take no action.
    return KeyEventResult.handled;
  }
}
