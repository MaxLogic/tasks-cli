"""Fixture ownership regressions; every Docker operation is mocked."""
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from verify_server_container import Proof

class OwnershipTests(unittest.TestCase):
    def fixture(self):
        root=tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        return Proof(SimpleNamespace(fixture_root=Path(root.name),docker="mock-docker",tasks=Path(root.name)/"tasks",image="mock-image"))

    def test_preexisting_volume_is_never_claimed_or_cleaned(self):
        proof=self.fixture();calls=[]
        def docker(*args,**kwargs):
            calls.append(args);return SimpleNamespace(returncode=0,stdout="[]")
        proof.docker=docker
        with self.assertRaisesRegex(AssertionError,"already exists"):
            proof.create_resource("volume",proof.volume)
        proof.cleanup()
        self.assertEqual(calls,[("volume","inspect",proof.volume)])
        self.assertFalse(proof.created["volume"])

    def test_changed_owner_label_prevents_cleanup(self):
        proof=self.fixture();calls=[];proof.created["volume"].add(proof.volume)
        def docker(*args,**kwargs):
            calls.append(args);return SimpleNamespace(returncode=0,stdout=json.dumps([{"Labels":{"tasks-proof.run":"someone-else"}}]))
        proof.docker=docker;proof.cleanup()
        self.assertEqual(calls,[("volume","inspect",proof.volume)])

    def test_cleanup_removes_only_created_matching_resources(self):
        proof=self.fixture();calls=[];proof.created["volume"].add(proof.volume)
        def docker(*args,**kwargs):
            calls.append(args);return SimpleNamespace(returncode=0,stdout=json.dumps([{"Labels":{"tasks-proof.run":proof.prefix}}]))
        proof.docker=docker;proof.cleanup()
        self.assertEqual(calls,[("volume","inspect",proof.volume),("volume","rm",proof.volume)])

if __name__ == "__main__": unittest.main()
