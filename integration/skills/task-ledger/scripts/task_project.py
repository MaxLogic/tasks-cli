"""Resolve tracked project identity and call tasks with an explicit UUID.

This wrapper never edits task storage itself and never bootstraps a project.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import uuid


def identity(cwd):
    root_result = subprocess.run(["git", "-C", str(cwd), "rev-parse", "--show-toplevel"], capture_output=True, text=True, encoding="utf-8")
    git_project = root_result.returncode == 0
    if git_project:
        root = Path(root_result.stdout.strip())
    else:
        resolved = cwd.resolve()
        root = next((item for item in [resolved, *resolved.parents] if (item / ".tasks.json").is_file()), None)
        if root is None:
            raise ValueError("missing .tasks.json in this non-Git project or its ancestors; explicit setup required")
    path = root / ".tasks.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ValueError(f"missing or invalid {path}: {error}") from error
    if not isinstance(data, dict) or set(data) != {"project_id"} or not isinstance(data["project_id"], str):
        raise ValueError(".tasks.json must contain only a string project_id")
    try:
        project = str(uuid.UUID(data["project_id"]))
    except ValueError as error:
        raise ValueError(".tasks.json project_id must be a UUID") from error
    if data["project_id"] != project:
        raise ValueError(".tasks.json project_id must be canonical lowercase UUID text")
    if git_project:
        tracked = subprocess.run(["git", "-C", str(root), "ls-files", "--error-unmatch", "--", ".tasks.json"], capture_output=True)
        if tracked.returncode:
            raise ValueError(".tasks.json is not tracked; finish explicit project setup first")
    return root, project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--tasks-exe", default="tasks")
    parser.add_argument("--data-root")
    parser.add_argument("--windows-exe")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    try:
        if not command or command[0] not in {"list", "show", "search", "history", "rules", "create", "update", "unlocks", "doctor", "export", "backup"}:
            raise ValueError("use a task command; init, bind and migration require explicit setup outside this wrapper")
        prohibited = {"--project", "--data-root", "--windows-exe", "--route-root", "--format"}
        value_options = {"--title", "--body-file", "--expect-version", "--status", "--priority", "--labels", "--deps", "--label", "--after", "--limit", "--offset", "--event", "--out", "--file"}
        index = 1
        while index < len(command):
            arg = command[index]
            if arg == "--":
                break
            flag = arg.split("=", 1)[0]
            if flag in prohibited:
                raise ValueError("identity/routing/output overrides are not allowed in the task command")
            index += 2 if flag in value_options and "=" not in arg else 1
        root, project = identity(args.cwd)
        prefix = [args.tasks_exe, "--project", project, "--format", "json"]
        if args.data_root:
            prefix += ["--data-root", args.data_root]
        if args.windows_exe:
            prefix += ["--windows-exe", args.windows_exe]
        probe = subprocess.run(prefix + ["rules", "show"], cwd=root, capture_output=True, text=True, encoding="utf-8")
        if probe.returncode:
            raise ValueError("identity validation failed: " + (probe.stderr or probe.stdout).strip())
        result = json.loads(probe.stdout)
        if result.get("project_id") != project:
            raise ValueError("identity validation failed: CLI returned a different project")
        return subprocess.run(prefix + command, cwd=args.cwd).returncode
    except (ValueError, OSError) as error:
        print(f"task-project: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
