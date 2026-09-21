# Tasks Viewer UI and UX design

Status: Ready for implementation alongside [spec.md](spec.md). This describes required behavior; no screen-reader or usability test has been executed yet.

## 1. Purpose and organization

The main workflow is: find a project, narrow its tasks, read a task, edit it if needed, and return to the same place. The interface uses three named regions: Projects, Tasks and Task details. There is one selected project and one selected task. A project UUID, not its displayed name or root path, determines identity.

Use a standard resizable Windows window titled "Tasks Viewer". When a task is selected append its ID and project name. Prefix "Unsaved changes" while editing dirty fields. Start in the last selected project if it still exists. Otherwise focus the Projects search box and show no task selected. Do not open a task automatically on a first launch.

The application is local. Do not show sign-in, sync indicators, cloud configuration or AI controls. Settings contains the CLI path, data root, text size, theme and Reset layout. Help contains a keyboard reference and the statistic definitions from spec.md.

## 2. Window layout and adaptation

At 1440x900 logical pixels, the starting layout is:

```text
Tasks Viewer                                Settings   Keyboard help
--------------------------------------------------------------------
Projects                 | Tasks                  | Task details
Search projects          | Search tasks           | T-042  P1  Todo
Project filters / Sort   | Task filters / Sort    | Full task title
12 projects              | 36 matching tasks      | Edit  Copy reference
                         |                        | Details | Dependencies
Virtual project list     | Virtual task list      | History | Project rules
                         |                        | Readable body / form
                         |                        |
Selected project summary |                        | Save / Cancel in edit
Enrich clipboard         |                        |
Preview enrichment       |                        |
--------------------------------------------------------------------
Refresh       Last refreshed time          Current operation/error
```

Use 300 logical pixels for Projects, 420 for Tasks, and remaining width for Task details. Start with 12-pixel panel padding and 8-pixel spacing. This wireframe shows hierarchy, not fixed positions for every control. Filters may wrap onto additional lines. Panel headings and toolbars stay visible when rows scroll.

Above 1280 logical pixels show three panes. At 1000..1279 show Projects and Tasks, with Task details replacing the Tasks pane when explicitly opened. Below 1000 show one pane and a labelled Projects/Tasks/Task details navigation control. Preserve all state across these layout changes. Enter on a project opens Tasks when those panes are not simultaneously visible; Enter on a task opens Task details. F6 continues to move between available regions and reveals the destination pane in reduced layouts. Do not silently hide the only route back.

Pane separators support pointer dragging. Settings also supplies labelled width inputs and Reset layout so resizing never requires dragging. Keep each visible pane at least 260 logical pixels; if that cannot fit, switch layout. At 200% text size, prefer the reduced layout before truncating controls. Dialogs fit within the current window and scroll their content, keeping action buttons reachable. The supported minimum test size is 800x600 logical pixels.

## 3. Visual language

Use the Flutter SDK theme and semantic controls, with system light/dark preference as default. Provide System, Light, Dark and follow-Windows-contrast-theme behavior. Do not invent a status palette that is the only way to distinguish states. Every status and priority is text. Progress always has a numeric or "Not applicable" label; the optional bar is redundant decoration for screen readers.

Default body text is 14 logical pixels; headings are 18. In-app text-size choices are 100%, 125%, 150%, 175%, 200%, combined with OS scaling. Respect system contrast settings through the Windows integration where Flutter does not expose them. Use the contrast/focus/size targets in spec.md section 9. Focus has a visible outline distinct from selection. Selection stays visible when focus moves to details, with an unfocused selection treatment that remains legible.

Task rows use two text lines at normal density; project rows use four in their default expanded view. Calculate row extent from the active text scale and row mode. Do not hard-code a pixel row height that clips scaled text. One-line title ellipsis is allowed only in collections; the complete title is in the accessible row name and details. Tooltip text is supplemental. Essential information must not require hover.

## 4. Projects region

Order: heading, labelled "Search projects" field, state filter, sort controls, Clear filters, result count, list, Go to row, selected-project summary, clipboard buttons.

Search helper text: "Search name, path or project ID". A Clear search button has that exact accessible name. State filter labels map to spec values: All projects, With open tasks, With blocked tasks, Complete, Empty, Unavailable. Default All projects. Sort choices: Name, Open tasks, Total tasks, Blocked tasks, Started, Last task write, Progress. A separate Ascending/Descending control exposes current direction. Clear filters resets query/state only, preserving chosen sort.

Default row presentation:

```text
Project name                         50.0% complete
4 open / 10 total / 1 blocked         Project root
Started (first task): 12 Sep 2026
Last task write: 21 Sep 2026, 10:30
```

The selected-project summary shows all required statistics, Started (first recorded task), Last task write, sample time, UUID and every bound root. The project list defaults to Expanded rows, showing started and last-write dates in each row so dates can be compared without selecting each project. An optional Compact rows setting hides those two visible lines, while preserving the dates in accessible row names and the selected summary. At larger text sizes use additional stacked lines. The virtual-list extent must account for this setting. A "Copy project ID" button is available in the summary.

Accessible project row name includes name, open, total, blocked, progress, started and last write, with selected state and row position exposed separately where the Windows bridge supports them. Example content: "Parser tools. 4 open, 10 total, 1 blocked. Progress 50 percent. Started, first recorded task, 12 September 2026. Last task write, 21 September 2026, 10:30." Root and UUID are available in the summary rather than appended to every long announcement; duplicate names include the distinguishing root in their row names.

Dates display using the user's locale and local time, with full timestamp and timezone accessible in the summary. Relative dates may supplement the absolute date, never replace it. Missing dates read "No recorded tasks". Unavailable statistics read "Unavailable", with the error and Retry in the summary; do not speak zeros.

Selecting a row updates its summary and Tasks. In a full layout, focus remains on the project row. Switching while an editor is dirty first opens the unsaved-changes dialog; Cancel restores the original selected project and focus.

## 5. Tasks region

Order: heading including selected project name, search, filter controls, sort, Clear filters, result count, list, Go to row. Helper text: "Search task ID, title or body". Initial filter is Open tasks; initial sort is Priority ascending. Display active filters in plain text with individual labelled Remove buttons. A collapsed Filters button reports how many filters are active. Its popup exposes the same controls as an expanded filter area.

Filter controls:

- Scope radio group: Open tasks / All tasks.
- Status checklist: Draft, Todo, In progress, Blocked, Done, Cancelled. Selecting Done/Cancelled also selects All tasks and announces this once.
- Priority checklist: P0, P1, P2, P3.
- Label input: comma-separated labels with an Apply labels button; explain "Tasks must have all these labels". Needs human is a checkbox synchronized with the `needs-human` label.
- Readiness selector: Any / Runnable / Waiting for dependencies. Show "Blocked status and waiting for dependencies are different filters" as helper text.
- Sort selector: Priority, Task ID, Status, Title, Created, Last updated; separate direction control.

Clear filters returns Open scope, no statuses/priorities/labels, Any readiness and empty query, keeping sort. Show "36 matching tasks" and, during a fetch, "Loading tasks" separately. An empty filter result says "No tasks match these filters" with Clear filters. A project with no stored tasks says "This project has no tasks". A load failure uses Retry and its error, never either empty message.

Rows show ID, priority, status, title, labels and a dependency-waiting count. The accessible row name follows that order. Example: "T-042, P1, Todo, Fix import title parsing. Labels needs-human. Waiting on 2 dependencies." Expose selected/focused states distinctly and communicate "row 43 of 100000" through tested semantics or one nonduplicating position label.

Use a semantic single-selection list, not an editable grid. This avoids inventing cell-navigation behavior for a visual table. If columns are visually aligned, every row still exposes a complete labelled summary; do not advertise a table role unless true header/cell relationships and keyboard behavior have been implemented and verified. Both collections use the same navigation component.

## 6. Selection and virtual-list navigation

Tab enters the collection at its selected row, or the first row if none is selected. Tab again leaves the collection; it must not visit thousands of rows. Within a list, Up/Down moves one logical row; Page Up/Down moves the number of whole rows fitting the viewport; Home/End selects first/last filtered row. Enter opens the selected object's next region. At a boundary the selection stays in place, without repeated speech.

Keep the focused row mounted until the pending target row has been fetched and made focusable. During an unloaded jump, focus remains in the list region, with a pending target index. Once data arrives, scroll and focus exactly that row. Do not momentarily send focus to the window root. Key repeats may replace the pending target; obsolete loads must not steal focus. Failed page load retains the last real selection and offers Retry in the region.

The list itself is one traversal stop, but row semantics must remain discoverable using NVDA navigation/review. Use stable item identity and correct total count/index semantics. Do not keep every visited row alive merely to preserve focus. Do not use a permanent "Loading" row as a substitute for the fetched item's semantics. The spec's End and Go to row tests must prove that unbuilt rows are reachable.

Changing a filter/sort keeps focus on the initiating control. Clear a selection that no longer belongs to the result set, except the spec's post-save retained detail case. Announce the final matching count once after debounce. Arrow selection changes do not announce the whole detail body or move to its tabs.

## 7. Task details and editor

The header exposes ID, full title, status and priority. Actions: Edit, Copy reference, Back when a dependency navigation stack exists. Copy reference writes `T-042: Full title` as plain text and announces "Task reference copied". It never enriches existing clipboard text implicitly.

Tabs use standard tab semantics with selected state. Left/Right changes the focused tab, Enter/Space activates it, Tab moves into its panel. Details contains read-only metadata and a labelled selectable multiline body control. It must support NVDA caret reading and ordinary Ctrl+A/C shortcuts. A Find in body field searches literal text with Next/Previous, match count and wrap notification; Esc returns to the body selection. Body Find does not change the task-list query. The source is shown as Markdown text, with no code execution or automatic URL launching.

Dependencies: virtual rows with ID, full title, status, waiting indicator; Open dependency button/Enter and Back restore task navigation. History: virtual events with ID, time, operation and resulting version; selecting an event opens a labelled read-only multiline snapshot. Project rules: full selectable read-only text and rules version. Empty dependencies/history/rules each have a specific message.

Edit replaces Details with a form, preserving the selected task. Focus starts in Title with caret position preserved when returning from a dialog. Form order: Title, Status, Priority, Labels, Dependencies, Body, Save, Cancel. Body is multiline; Tab leaves it, Shift+Tab goes back, and Ctrl+Enter inserts a literal tab only if implemented and documented in Help. Do not trap Tab for indentation. Enter adds a newline in Body and never saves implicitly.

Use permanent labels, validation helper text and per-field error text. Validate on blur and on Save; do not announce a new error on every keystroke. Invalid Save focuses the first invalid field and announces the error summary once. Keep all entered fields. Save/Ctrl+S follows spec.md section 7; a busy state speaks "Saving T-042" once and disables duplicate saves.

Successful save speaks "Saved T-042, version N" after confirmation and returns to read mode with focus on Edit. If still editing after a no-op, resolve to read mode and speak "No changes needed". Cancel with actual changes uses the same dirty guard; cancelling that dialog returns to the previous field and caret. Read-only task metadata must not look editable.

## 8. Dialogs and recovery

All dialogs have a name, initial focus, contained traversal, a keyboard dismissal rule and a deterministic return target. Escape is equivalent to the safe Cancel/Close action, never Discard. Hidden background controls must not receive focus while modal.

| Dialog/state | Content and actions | Initial/return focus |
| --- | --- | --- |
| Unsaved changes | Task ID/title; Save, Discard, Cancel | Cancel initially; cancel returns to initiating field/row |
| Version conflict | Base/current versions; changed fields; Return to editor, Reload current and discard draft, Review against current | Return to editor; review opens field choices with explicit labels |
| Review against current | Per conflicting field, Mine/Current choices, full selectable values; Apply choices, Cancel | First unresolved field; Apply returns to editor and does not save |
| Restore draft | Project/task identity, base/current versions, Restore draft, Discard | Restore draft; proceeds to editor |
| Enrichment preview | Captured project identity, original and result text, replacement/unknown counts; Close | Preview heading then text in traversal; Close returns to Preview enrichment |
| Settings | CLI/root paths, Test connection, theme/text size/pane widths; Save, Cancel | First setting; return to Settings button |
| Keyboard help | Searchable/selectable shortcut list; Close | Help heading; return to initiating control |

Errors remain visible until resolved or explicitly dismissed; essential instructions must not vanish in a toast. A status region speaks one final outcome at a polite priority. Validation/conflict failures are announced immediately but do not repeatedly interrupt reading. The Status area is reachable with F6 and includes error details and Retry. Never expose the whole task/clipboard payload as a status message.

Missing CLI: show its path, Browse and Test connection. Incompatible CLI: name required/actual protocol and offer Settings. Unavailable project: retain its row, show error and Retry. Failed refresh: keep last confirmed data, identify it as stale. Unknown save outcome: show reconciliation state with draft preserved, not "Save failed". Offline networking is irrelevant; no connectivity banner is needed for this local application.

## 9. Keyboard map

All shortcuts have visible button/control equivalents and appear in Help. Handle app shortcuts through Flutter Actions/Shortcuts; text-editing keys belong to the focused text field. Never intercept NVDA modifier combinations.

| Key | Action |
| --- | --- |
| F6 / Shift+F6 | Next/previous region: Projects, Tasks, Task details, Status; reveal pane in reduced layout |
| Ctrl+1 / Ctrl+2 / Ctrl+3 | Focus Projects list / Tasks list / current Task details tab; no selection means focus region heading |
| Ctrl+F | Focus the current collection's search; in Task details focus Find in body |
| Ctrl+Shift+F | Focus Tasks search from anywhere |
| F5 | Refresh workspace, preserving draft and focus |
| F2 | Edit selected task when in Tasks or Task details |
| Ctrl+S | Save active editor; otherwise no action |
| Alt+Left | Back from dependency detail or reduced-layout child pane; never intercept text-caret commands |
| Escape | Close active popup/dialog safely; otherwise no destructive action |
| F1 | Keyboard help |
| Tab / Shift+Tab | Next/previous control, one stop per collection |
| Up/Down, Page Up/Down, Home/End | Collection navigation only when collection has focus |
| Enter | Open selected row; activate focused button; newline inside multiline fields |
| Space | Activate button/checkbox; normal space in text fields |

Do not bind a global clipboard-enrichment shortcut by default. The explicit project-toolbar buttons make the project context clear. Standard text selection/copy/paste/undo must work without custom app overrides.

## 10. Accessibility implementation checks

Use actual semantic buttons, text fields, checkboxes, tabs and lists. An icon-only action needs a name matching its purpose. Add selected, expanded, checked, enabled, read-only and busy states where relevant. Do not mark a read-only body disabled: the user must still focus, select and copy it. Labels must not disappear when fields contain values.

Keep collection result counts and logical row indexes correct after filtering, paging and refresh. Speak a list item's identifying content once, not once from a wrapper and again from every decorative child. Do not exclude a text editor's native semantics in an attempt to reduce speech. Loading and errors use a single tested status mechanism; avoid combining an explicit announcement and a live region for the same event.

Use Semantics widget tests to inspect names/states/order, Windows UI Automation inspection to verify the actual platform tree, and NVDA to verify speech, caret access and task completion. These are separate evidence sources. Flutter's [input guidance](https://docs.flutter.dev/ui/adaptive-responsive/input) describes focus and keyboard support; the behavior in this document must still be verified in the chosen SDK and Windows build.

## 11. Required manual NVDA walkthroughs

Use only a synthetic fixture store and synthetic clipboard text. Record Windows, Flutter and NVDA versions, build hash, keyboard layout, display/text scaling and active NVDA mode. Capture speech output or a precise transcript plus observed focus targets. Do not call a walkthrough passed merely because controls appear in an accessibility tree. Expected spoken content may vary in wording, but must communicate the listed identity, role, state and result without duplicate noise.

### A. Project and task discovery, including virtualization

1. Launch the build with NVDA already running. Hear window identity and first focused control without a mouse click or special accessibility enable button.
2. Search a project by path, filter With open tasks, sort Open tasks descending. Hear labels, state and final result count. Tab into the list and identify its selected row and statistics.
3. Navigate with arrows and Page Down across at least two page boundaries. Use End and Go to row to reach task row 100,000. Hear the correct actual task ID, selected state and position; no blank/unreachable row or focus loss.
4. Reverse direction, change sort, clear filters and open a task. Verify body loading does not interrupt row reading. F6 moves predictably among regions; Shift+F6 reverses it.
5. Repeat with a 1000-project fixture and expanded project rows. Verify all requested statistics are readable and project selection routes to the correct UUID.

### B. Read complete content and navigate references

1. Open a task whose body is 1 MiB and contains Unicode, Markdown headings and long lines. Navigate body by line, word and character with NVDA; find a marker near its end and copy it exactly.
2. Open Dependencies, follow one, then Back. Verify original task, row focus and filters return.
3. Read a paginated history event and its full snapshot; read project rules. Empty panels announce their own empty states. No tab or panel traps keyboard focus.

### C. Edit, conflict and recovery

1. F2, edit all six fields, clear labels/dependencies, and deliberately exceed a validation boundary. Save; hear the field error with draft preserved and focus on that field.
2. Correct the values and save. Hear one success announcement after commit; use real CLI show/history to confirm the fields and one atomic change.
3. Start another edit, update the same task using a second real CLI process, then save the viewer draft. Read Base/Mine/Current, choose values, return to editor and save again. Verify no force overwrite or automatic retry occurred.
4. Exercise Save/Discard/Cancel when switching projects and closing. Cancel must restore original focus and caret. Restart with a saved recovery draft and restore it against a changed current version.
5. Simulate lost save acknowledgement in the test harness. Hear "outcome unknown" and reconciliation, without duplicated writes.

### D. Clipboard and failure states

1. Put known, unknown and repeated T-IDs into a synthetic plain-text clipboard. Preview in project A; read counts and result. Close and verify clipboard unchanged.
2. Enrich clipboard in project A, then invoke again. Hear replacement then unchanged outcomes. Repeat in project B with the same numeric IDs and different titles; verify captured project scope.
3. Trigger no-text/locked/changed clipboard failures through the controlled fixture. Hear the relevant recovery action; no false success.
4. Make one project unavailable, then make the CLI unavailable. Verify error scope, reachable Settings/Retry and focus restoration after recovery.

### E. Layout and Windows behavior

1. Complete search, selection, edit, conflict and clipboard actions at 100%, 150% and 200% Windows display scaling, including 200% in-app text size at the minimum window size.
2. Repeat critical navigation in light, dark and a Windows contrast theme. Focus, selection, labels and validation remain distinguishable.
3. Start NVDA after the app is already open and verify the same controls become accessible. Close/reopen a dialog, minimize/restore and move between panes; focus must not disappear or reset unexpectedly.

Passing all walkthroughs demonstrates the exercised NVDA workflows on the recorded configuration. Any untested configuration remains explicitly unverified; automated semantics alone cannot justify claiming full NVDA accessibility.
