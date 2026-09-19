"""Disposable, real CLI and Git worktree proof. No default store access."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / "integration/skills/task-ledger/scripts/task_project.py"
EXE = Path(os.environ.get("TASKS_TEST_EXE", REPO / "target/release/tasks.exe"))


class IdentityTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tasks-identity-")
        self.base = Path(self.tmp.name)
        self.root = self.base / "main"
        self.root.mkdir()
        self.store = self.base / "store"
        self.run_cmd(["git", "init", str(self.root)])
        result = self.run_cmd([str(EXE), "--data-root", str(self.store), "--format", "json", "init", "--root", str(self.root)])
        self.project = json.loads(result.stdout)["project_id"]
        (self.root / ".tasks.json").write_text(json.dumps({"project_id": self.project}), encoding="utf-8")
        self.run_cmd(["git", "-C", str(self.root), "add", ".tasks.json"])
        self.run_cmd(["git", "-C", str(self.root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "identity fixture"])

    def tearDown(self):
        # All paths belong to the unique TemporaryDirectory created above.
        for child in self.base.rglob("*"):
            if child.is_file():
                child.chmod(0o600)
        self.tmp.cleanup()

    def run_cmd(self, args, expected=0):
        result = subprocess.run(args, text=True, encoding="utf-8", capture_output=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def invoke(self, cwd, *args, expected=0):
        return self.run_cmd([sys.executable, "-B", str(HELPER), "--cwd", str(cwd), "--tasks-exe", str(EXE), "--data-root", str(self.store), "--", *args], expected)

    def test_main_and_unbound_worktree_use_identical_project(self):
        worktree = self.base / "worktree"
        self.run_cmd(["git", "-C", str(self.root), "worktree", "add", "--detach", str(worktree)])
        for root in [self.root, worktree]:
            nested = root / "src/deep"
            nested.mkdir(parents=True)
            result = self.invoke(nested, "rules", "show")
            self.assertEqual(json.loads(result.stdout)["project_id"], self.project)
        self.run_cmd(["git", "-C", str(self.root), "worktree", "remove", str(worktree)])

    def test_missing_and_malformed_identity_fail_closed(self):
        identity = self.root / ".tasks.json"
        identity.unlink()
        self.assertIn("missing or invalid", self.invoke(self.root, "list", expected=2).stderr)
        for text in ['{}', '{"project_id":"oops"}', '{"project_id":4}', '{', '{"project_id":"' + self.project + '","extra":1}']:
            identity.write_text(text, encoding="utf-8")
            self.assertIn("task-project:", self.invoke(self.root, "list", expected=2).stderr)

    def test_unknown_project_and_override_refused(self):
        before = {str(p.relative_to(self.store)): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.store.rglob("*") if p.is_file()}
        (self.root / ".tasks.json").write_text(json.dumps({"project_id": str(uuid.uuid4())}), encoding="utf-8")
        result = self.invoke(self.root, "list", expected=2)
        self.assertIn("identity validation failed", result.stderr)
        self.invoke(self.root, "init", "--root", str(self.root), expected=2)
        self.invoke(self.root, "list", "--project", self.project, expected=2)
        after = {str(p.relative_to(self.store)): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.store.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_relative_body_file_and_untracked_identity(self):
        nested = self.root / "nested"
        nested.mkdir()
        (nested / "body.md").write_text("Outcome: preserve caller-relative paths", encoding="utf-8")
        result = self.invoke(nested, "create", "--title", "relative path fixture", "--body-file", "body.md")
        self.assertEqual(json.loads(result.stdout)["project_id"], self.project)
        self.run_cmd(["git", "-C", str(self.root), "rm", "--cached", ".tasks.json"])
        self.assertIn("not tracked", self.invoke(nested, "list", expected=2).stderr)

    def test_non_git_uses_nearest_identity_and_does_not_skip_invalid_one(self):
        project = self.base / "svn-project"
        nested = project / "src/deep"
        nested.mkdir(parents=True)
        (project / ".tasks.json").write_text(json.dumps({"project_id": self.project}), encoding="utf-8")
        self.assertEqual(json.loads(self.invoke(nested, "rules", "show").stdout)["project_id"], self.project)
        (nested.parent / ".tasks.json").write_text('{"project_id":"invalid"}', encoding="utf-8")
        self.assertIn("must be a UUID", self.invoke(nested, "list", expected=2).stderr)

    def test_unicode_rules_and_literal_routing_words_are_not_overrides(self):
        body = self.root / "body.md"
        body.write_text("rules Ω 日本語", encoding="utf-8")
        self.run_cmd([str(EXE), "--data-root", str(self.store), "--project", self.project, "rules", "set", "--body-file", str(body), "--expect-version", "1"])
        result = self.invoke(self.root, "create", "--title=--project", "--body-file", str(body))
        task_id = json.loads(result.stdout)["data"]["id"]
        self.assertEqual(json.loads(self.invoke(self.root, "show", f"T-{task_id}").stdout)["data"]["rules"], "rules Ω 日本語")
        result = self.invoke(self.root, "search", "--", "--project")
        self.assertEqual(json.loads(result.stdout)["data"]["items"][0]["id"], task_id)


if __name__ == "__main__":
    unittest.main()
