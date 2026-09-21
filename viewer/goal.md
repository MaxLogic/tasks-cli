# Implement Tasks Viewer

Copy the following command into Codex from `F:\projects\MaxLogic\tasks-cli`. This file does not start a goal by itself.

```text
/goal Implement and deliver the Windows x64 Flutter/Dart Tasks Viewer end-to-end according to viewer/spec.md and viewer/design.md, including the additive Rust CLI endpoints, accessible virtual project/task lists, project statistics, complete task reading/editing, optimistic conflicts and draft recovery, project-scoped clipboard actions, portable release packaging, and all required tests.

Read AGENTS.md, viewer/spec.md, viewer/design.md and the relevant root spec.md/source contracts before implementation. Treat viewer/spec.md as the new viewer contract and root spec.md as the storage/legacy CLI contract; reconcile contradictions explicitly. Follow the dependency-ordered implementation slices and proof schedule. Use the project-local Rust skills for Rust changes and the applicable Flutter/UX, testing, PowerShell and Git guidance. Prove the initial virtual-list/text-editor/dialog workflow with the actual Windows build and NVDA before completing the collection UI.

Done means every requirement and V01..V10 in viewer/spec.md passes against the final candidate, every NVDA walkthrough in viewer/design.md is executed successfully, performance targets have recorded measurements, and target/viewer-release contains a launch-tested portable bundle with the matching tasks.exe and SHA-256 manifest. Deliver viewer/README.md and viewer/verification-report.md with exact toolchains, source identity, commands, test counts, raw evidence paths, actual NVDA observations, performance results and first-failure/rerun history. A mock, screenshot, skipped test, unexecuted manual checklist or executable build alone is not completion.

Work autonomously on in-scope source, tests, fixture generators, verification scripts and documentation. Make the required local commits for verified coherent milestones, staging only owned changes. Preserve unrelated work. Do not push, publish, migrate live backlogs, initialize real project stores, change real TASKS.md/.tasks.json files, or replace an in-use executable. Use explicit unique synthetic task/settings roots for every automated test. Native Linux CLI tests must use Linux-owned stores; verify Windows-store delegation with the two real binaries. Keep the viewer local and route task data through tasks.exe rather than opening SQLite from Dart.

Run the focused checks while implementing, the specified intermediate Flutter batch, and the final Flutter, Windows Rust, Ubuntu/WSL Rust, integration, packaged-release, performance and NVDA gates at their defined checkpoints. Retain full evidence under target/evidence/viewer. Do not reduce test scope, weaken durability, drop accessibility or silently change acceptance targets to obtain a pass.

Continue until the completion criteria hold. At checkpoints report what is verified, what remains and the next action. If a required tool, interactive NVDA session or permission is unavailable, finish independent authorized work, preserve the exact failing/unavailable evidence and report the smallest external action needed. Never mark the goal complete while a required runtime/manual gate remains unavailable or failed. Do not claim a save or test succeeded without its required evidence.
```

The completion details live in the two linked specifications so this command stays below the 4,000-character objective limit. Runtime prerequisites are listed in spec.md section 13; the implementation scope excludes the features listed in spec.md section 2.
