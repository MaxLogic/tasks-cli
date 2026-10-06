"""Archive integrity tests; the package command separately smoke-tests the real CLI."""

from pathlib import Path
import os
import tarfile
import tempfile
import unittest

from package import archive_directory, check_hashes, extract_archive, write_hashes


class ArchiveTests(unittest.TestCase):
    def test_round_trip_preserves_contents_and_hashes(self):
        with tempfile.TemporaryDirectory(prefix="tasks-release-test-") as temporary:
            root = Path(temporary)
            source = root / "bundle"
            (source / "data").mkdir(parents=True)
            (source / "data/Zaźółć.txt").write_text("Complete Unicode task text.\n", encoding="utf-8")
            (source / "tasks").write_bytes(b"synthetic executable")
            (source / "tasks").chmod(0o755)
            write_hashes(source)
            for suffix in (".zip", ".tar.gz"):
                archive = root / ("bundle" + suffix)
                archive_directory(source, archive)
                destination = root / suffix
                destination.mkdir()
                extract_archive(archive, destination)
                check_hashes(destination / "bundle")
                self.assertEqual((destination / "bundle/data/Zaźółć.txt").read_text(encoding="utf-8"),
                                 "Complete Unicode task text.\n")
                if suffix == ".tar.gz":
                    with tarfile.open(archive) as stream:
                        self.assertTrue(stream.getmember("bundle/tasks").mode & 0o100)
                    if os.name != "nt":
                        self.assertTrue((destination / "bundle/tasks").stat().st_mode & 0o100)

    def test_tampered_or_unlisted_files_are_refused(self):
        with tempfile.TemporaryDirectory(prefix="tasks-release-test-") as temporary:
            root = Path(temporary)
            path = root / "tasks"
            path.write_bytes(b"original")
            write_hashes(root)
            path.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "Hash mismatch"):
                check_hashes(root)
            path.write_bytes(b"original")
            (root / "unlisted").write_bytes(b"extra")
            with self.assertRaisesRegex(ValueError, "complete archive"):
                check_hashes(root)


if __name__ == "__main__":
    unittest.main()
