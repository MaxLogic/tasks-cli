# tasks-cli 0.1.0

First public release of the shared task backlog for coding agents and the
architect coordinating them.

- One project backlog across branches, worktrees and coding sessions.
- Version-checked edits, task history, dependency readiness and a `to-verify`
  handoff before acceptance.
- Local SQLite storage with optional self-hosted HTTPS access.
- Separate Windows x64 and Linux x64 CLI downloads, plus a Windows 11 x64
  viewer. The project owner has tested the viewer with NVDA.

Download the archive for your platform and `SHA256SUMS.txt`. Each archive
includes a quickstart, license and dependency notices. The Linux CLI is built
on Ubuntu 22.04 and requires glibc 2.35 or newer. The viewer ZIP includes its
matching CLI and Flutter runtime; Windows may also need the Microsoft x64
Visual C++ Redistributable linked in its quickstart.

macOS and other architectures have not been built or tested. Task assignment
is coordinated by the architect; there is no built-in assignee or task lease.

Start with the [installation guide](https://github.com/MaxLogic/tasks-cli/blob/main/installation.md)
and [architect walkthrough](https://github.com/MaxLogic/tasks-cli/blob/main/integration/architect-workflow.md).
