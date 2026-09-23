import 'dart:ui' as ui;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// One screen-reader accessibility defect found in the rendered semantics tree.
final class SemanticsAuditFailure {
  const SemanticsAuditFailure({
    required this.nodeId,
    required this.problem,
    required this.description,
  });

  final int nodeId;
  final String problem;
  final String description;

  @override
  String toString() => 'node $nodeId ($description): $problem';
}

/// Audits every semantics tree currently rendered by the widget test binding.
///
/// This complements Flutter's [labeledTapTargetGuideline]. It catches controls
/// whose final, merged semantics node has no accessible name or exposes a role
/// or state without the action a screen-reader user needs to operate it.
List<SemanticsAuditFailure> auditRenderedSemantics(WidgetTester tester) {
  final failures = <SemanticsAuditFailure>[];

  for (final view in tester.binding.renderViews) {
    final root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root == null) {
      failures.add(
        const SemanticsAuditFailure(
          nodeId: 0,
          problem: 'the render view has no semantics tree',
          description: 'render view',
        ),
      );
      continue;
    }
    _visit(root, failures);
  }

  return failures;
}

/// True when a visible route scope exposes [label] as its screen-reader name.
bool renderedHasNamedRoute(WidgetTester tester, String label) {
  for (final view in tester.binding.renderViews) {
    final root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root != null && _hasNamedRoute(root, label)) {
      return true;
    }
  }
  return false;
}

bool _hasNamedRoute(SemanticsNode node, String label) {
  final data = node.getSemanticsData();
  if (!data.flagsCollection.isHidden &&
      data.flagsCollection.namesRoute &&
      data.label.trim() == label) {
    return true;
  }
  var found = false;
  if (!data.flagsCollection.isHidden) {
    node.visitChildren((child) {
      found = found || _hasNamedRoute(child, label);
      return !found;
    });
  }
  return found;
}

/// Fails with all rendered-tree defects, not only the first one.
void expectAccessibleSemantics(WidgetTester tester) {
  final failures = auditRenderedSemantics(tester);
  expect(
    failures,
    isEmpty,
    reason: failures.isEmpty
        ? null
        : 'Rendered semantics defects:\n${failures.join('\n')}',
  );
}

void _visit(SemanticsNode node, List<SemanticsAuditFailure> failures) {
  final data = node.getSemanticsData();
  if (!data.flagsCollection.isHidden && !node.isMergedIntoParent) {
    _auditNode(node, data, failures);
  }
  if (!data.flagsCollection.isHidden) {
    node.visitChildren((child) {
      _visit(child, failures);
      return true;
    });
  }
}

void _auditNode(
  SemanticsNode node,
  SemanticsData data,
  List<SemanticsAuditFailure> failures,
) {
  final flags = data.flagsCollection;
  final isEnabled = flags.isEnabled != ui.Tristate.isFalse;
  final hasName =
      data.label.trim().isNotEmpty || data.tooltip.trim().isNotEmpty;
  final hasDirectAction = <ui.SemanticsAction>{
    ui.SemanticsAction.tap,
    ui.SemanticsAction.longPress,
    ui.SemanticsAction.increase,
    ui.SemanticsAction.decrease,
    ui.SemanticsAction.dismiss,
  }.any(data.hasAction);

  void report(String problem) {
    failures.add(
      SemanticsAuditFailure(
        nodeId: node.id,
        problem: problem,
        description: _describe(data),
      ),
    );
  }

  if (hasDirectAction && !hasName) {
    report('interactive control has no accessible name or tooltip');
  }
  if (flags.isTextField && !hasName) {
    report('text field has no accessible name');
  }
  if (flags.scopesRoute && !_routeScopeHasName(node)) {
    report('route scope has no accessible name');
  }
  if (isEnabled &&
      (flags.isButton || flags.isLink) &&
      !data.hasAction(ui.SemanticsAction.tap)) {
    report('enabled button or link has no tap action');
  }
  if (isEnabled &&
      (flags.isChecked != ui.CheckedState.none ||
          flags.isToggled != ui.Tristate.none) &&
      !data.hasAction(ui.SemanticsAction.tap)) {
    report('enabled checked or toggled control has no tap action');
  }
  if (isEnabled &&
      flags.isSlider &&
      (!data.hasAction(ui.SemanticsAction.increase) ||
          !data.hasAction(ui.SemanticsAction.decrease))) {
    report('enabled slider lacks increase or decrease actions');
  }
}

bool _routeScopeHasName(SemanticsNode node) {
  final data = node.getSemanticsData();
  if (!data.flagsCollection.isHidden &&
      data.flagsCollection.namesRoute &&
      data.label.trim().isNotEmpty) {
    return true;
  }
  var found = false;
  if (!data.flagsCollection.isHidden) {
    node.visitChildren((child) {
      found = found || _routeScopeHasName(child);
      return !found;
    });
  }
  return found;
}

String _describe(SemanticsData data) {
  final name = data.label.trim().isNotEmpty
      ? data.label.trim()
      : data.tooltip.trim().isNotEmpty
      ? data.tooltip.trim()
      : '<unnamed>';
  final roles = <String>[
    if (data.flagsCollection.isButton) 'button',
    if (data.flagsCollection.isLink) 'link',
    if (data.flagsCollection.isTextField) 'text field',
    if (data.flagsCollection.isSlider) 'slider',
    if (data.flagsCollection.isChecked != ui.CheckedState.none) 'checkable',
    if (data.flagsCollection.isToggled != ui.Tristate.none) 'toggle',
  ];
  return roles.isEmpty ? '"$name"' : '"$name", ${roles.join(', ')}';
}
