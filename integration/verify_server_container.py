#!/usr/bin/env python3
"""Isolated, destructive-to-own-fixture Docker proof for a built tasks-server image.

Requires Python 3.11+, cryptography>=46, a local linux/amd64 server image,
python:3.13-slim-bookworm cached locally, Docker, and a built remote-capable CLI.
Never selects a default tasks data root. Docker resources have one random prefix.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import contextlib
import datetime as dt
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import sqlite3
import socket
import ssl
import subprocess
import sys
import threading
import time
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID


GATEWAY_CODE = """import socket,threading
def relay(a,b):
 try:
  while data:=a.recv(65536): b.sendall(data)
 except OSError: pass
 finally:
  try: b.shutdown(socket.SHUT_WR)
  except OSError: pass
def serve(c):
 try:
  b=socket.create_connection(('tasks-server',8080),5)
  t=threading.Thread(target=relay,args=(c,b),daemon=True); t.start()
  relay(b,c); t.join(5); b.close()
 finally: c.close()
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('0.0.0.0',9090)); s.listen(32)
while True:
 c,_=s.accept(); threading.Thread(target=serve,args=(c,),daemon=True).start()
"""


class Proof:
    def __init__(self, args):
        self.args = args
        self.root = args.fixture_root
        self.log = self.root / "commands.jsonl"
        self.manifest = {"checks": [], "resources": {}, "limitations": [
            "Local Docker proof only; repeat network isolation and TLS checks on QNAP Docker 27.1.2-qnap8."]}
        self.prefix = "tasks-proof-" + uuid.uuid4().hex[:12]
        self.volume = self.prefix + "-data"
        self.backup_volume = self.prefix + "-backups"
        self.network = self.prefix + "-net"
        self.backend = self.prefix + "-backend"
        self.gateway = self.prefix + "-gateway"
        self.tls_servers = []
        self.drop_next = False
        self.signed_read = None  # Synthetic signature metadata stays in memory only.
        self.lost_reply = None
        self.dropped = threading.Event()
        self.log_lock = threading.Lock()
        self.created = {"container":set(),"network":set(),"volume":set()}

    def record(self, name, detail=None):
        self.manifest["checks"].append({"name": name, "result": "pass", "detail": detail})
        self.write_manifest()

    def write_manifest(self):
        (self.root / "manifest.json").write_text(
            json.dumps(self.manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def run(self, argv, *, ok=(0,), timeout=45, input_data=None, secret=False):
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        env = os.environ.copy()
        for name in ("TASKS_WINDOWS_EXE", "TASKS_PROJECT", "TASKS_CONTEXT_FILE",
                     "TASKS_AGENT_ID", "TASKS_EXECUTION_ID", "TASKS_ORIGIN_CONTEXT", "TASKS_DELEGATED"):
            env.pop(name, None)
        if str(argv[0]) == str(self.args.tasks):
            client_root = Path(argv[2])
            env["TASKS_CLIENT_DIR"] = str(client_root / "client")
        try:
            p = subprocess.run([str(a) for a in argv], input=input_data, text=True,
                               capture_output=True, timeout=timeout, creationflags=flags,
                               encoding="utf-8", errors="replace", env=env)
        except subprocess.TimeoutExpired as e:
            raise AssertionError(f"command timed out: {argv[0]} {argv[1:3]}") from e
        entry = {"argv": ([str(argv[0]), "<private args>"] if secret else [str(a) for a in argv]),
                 "exit": p.returncode,
                 "stdout": "<private>" if secret else p.stdout[-12000:],
                 "stderr": "<private>" if secret else p.stderr[-12000:]}
        with self.log_lock:
            with self.log.open("a", encoding="utf-8", newline="\n") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        if p.returncode not in ok:
            raise AssertionError(f"exit {p.returncode}, expected {ok}: {entry['argv']}; see {self.log}")
        return p

    def docker(self, *argv, **kwargs):
        return self.run([self.args.docker, *argv], **kwargs)

    def create_resource(self, kind, name, *arguments):
        before = self.docker(kind if kind != "container" else "container", "inspect", name, ok=(0,1))
        if before.returncode == 0:
            raise AssertionError(f"fixture {kind} name already exists: {name}")
        if kind == "container":
            self.docker(*arguments)
        else:
            self.docker(kind,"create","--label",f"tasks-proof.run={self.prefix}",*arguments,name)
        self.created[kind].add(name)

    def owns_resource(self, kind, name):
        if name not in self.created[kind]: return False
        inspected = self.docker(kind,"inspect",name,ok=(0,1))
        if inspected.returncode != 0: return False
        item=json.loads(inspected.stdout)[0]
        labels=item.get("Config",{}).get("Labels",{}) if kind == "container" else item.get("Labels",{})
        return (labels or {}).get("tasks-proof.run") == self.prefix

    def cli(self, client, *argv, ok=(0,)):
        return self.run([self.args.tasks, "--data-root", self.root / client,
                         "--format", "json", *argv], ok=ok)

    def admin(self, *argv):
        return json.loads(self.docker("run", "--rm", "--network", self.network,
            "--user", "10001:10001", "--mount", f"type=volume,src={self.volume},dst=/data",
            "--mount", f"type=volume,src={self.backup_volume},dst=/backups",
            "--entrypoint", "tasks-server", self.args.image,
            "--data-root", "/data", "admin", *argv).stdout)

    def install_cert(self):
        now = dt.datetime.now(dt.timezone.utc)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "tasks proof CA")])
        ca = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
              .public_key(key.public_key()).serial_number(x509.random_serial_number())
              .not_valid_before(now - dt.timedelta(minutes=5))
              .not_valid_after(now + dt.timedelta(days=1))
              .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
              .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
              .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()), critical=False)
              .add_extension(x509.KeyUsage(digital_signature=False, content_commitment=False,
                  key_encipherment=False, data_encipherment=False, key_agreement=False,
                  key_cert_sign=True, crl_sign=True, encipher_only=False, decipher_only=False), critical=True)
              .sign(key, hashes.SHA256()))
        leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        leaf = (x509.CertificateBuilder().subject_name(x509.Name([
                    x509.NameAttribute(NameOID.COMMON_NAME, "localhost")]))
                .issuer_name(subject).public_key(leaf_key.public_key())
                .serial_number(x509.random_serial_number())
                .not_valid_before(now - dt.timedelta(minutes=5))
                .not_valid_after(now + dt.timedelta(days=1))
                .add_extension(x509.SubjectKeyIdentifier.from_public_key(leaf_key.public_key()), critical=False)
                .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()), critical=False)
                .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                    key_encipherment=True, data_encipherment=False, key_agreement=False,
                    key_cert_sign=False, crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
                .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]),
                               critical=False).sign(key, hashes.SHA256()))
        tls = self.root / "tls"
        tls.mkdir()
        (tls / "ca.pem").write_bytes(ca.public_bytes(serialization.Encoding.PEM))
        (tls / "cert.pem").write_bytes(leaf.public_bytes(serialization.Encoding.PEM))
        (tls / "key.pem").write_bytes(leaf_key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption()))
        if os.name != "nt":
            (tls / "key.pem").chmod(0o600)
        return tls

    def start_gateway_tls(self):
        gateway_source = self.root / "gateway.py"
        gateway_source.write_text(GATEWAY_CODE, encoding="utf-8", newline="\n")
        self.create_resource("container",self.gateway,"run", "-d", "--name", self.gateway,"--label",f"tasks-proof.run={self.prefix}", "--network", "bridge",
                    "--publish", "127.0.0.1::9090", "--read-only", "--cap-drop", "ALL",
                    "--security-opt", "no-new-privileges", "--mount",
                    f"type=bind,src={gateway_source},dst=/gateway.py,readonly",
                    "python:3.13-slim-bookworm", "python", "-u", "/gateway.py")
        self.docker("network","connect",self.network,self.gateway)
        published = self.docker("port", self.gateway, "9090/tcp").stdout.strip()
        assert published.startswith("127.0.0.1:"), published
        self.gateway_port = int(published.rsplit(":", 1)[1])
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                return

            def proxy(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                conn = http.client.HTTPConnection("127.0.0.1", outer.gateway_port, timeout=8)
                headers = dict(self.headers.items())
                headers.pop("Connection", None)
                headers["Connection"] = "close"
                try:
                    conn.request(self.command, self.path, body=body, headers=headers)
                    reply = conn.getresponse()
                    payload = reply.read()
                    if (outer.signed_read is None and self.command == "GET" and
                            self.path == "/v1/info" and reply.status == 200):
                        outer.signed_read = (self.command, self.path, body, headers)
                    if (outer.drop_next and self.command == "POST" and
                            self.path.endswith("/tasks") and reply.status < 400):
                        outer.drop_next = False
                        outer.lost_reply = json.loads(payload)["output"]
                        outer.dropped.set()
                        self.close_connection = True
                        with contextlib.suppress(OSError):
                            self.connection.shutdown(socket.SHUT_RDWR)
                        return
                    self.send_response_only(reply.status, reply.reason)
                    for k, v in reply.getheaders():
                        if k.lower() not in {"transfer-encoding", "connection", "content-length"}:
                            self.send_header(k, v)
                    self.send_header("Content-Length", str(len(payload)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(payload)
                    self.close_connection = True
                finally:
                    conn.close()

            do_GET = do_POST = do_PATCH = do_PUT = proxy

        tls = self.install_cert()
        for route in ("lan", "public"):
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(str(tls / "cert.pem"), str(tls / "key.pem"))
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.tls_servers.append(server)
            self.manifest["resources"][route + "_url"] = f"https://localhost:{server.server_port}"

    def start_backend(self):
        self.create_resource("container",self.backend,"run", "-d", "--name", self.backend,"--label",f"tasks-proof.run={self.prefix}", "--network", self.network,
            "--network-alias", "tasks-server", "--user", "10001:10001",
            "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "--pids-limit", "128", "--memory", "512m", "--stop-timeout", "35",
            "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777",
            "--mount", f"type=volume,src={self.volume},dst=/data", self.args.image)
        inspect = json.loads(self.docker("inspect", self.backend).stdout)[0]
        cfg, host = inspect["Config"], inspect["HostConfig"]
        assert not host["PortBindings"] and not inspect["NetworkSettings"]["Ports"].get("8080/tcp")
        assert cfg["User"] == "10001:10001" and host["ReadonlyRootfs"]
        assert "ALL" in host["CapDrop"] and "no-new-privileges" in host["SecurityOpt"]
        assert host["PidsLimit"] == 128 and host["Memory"] == 512 * 1024 * 1024
        assert cfg["StopTimeout"] == 35
        assert not any("docker.sock" in str(m) for m in inspect["Mounts"])
        self.record("backend isolation inspect", {"container": self.backend})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.docker("inspect", "-f", "{{.State.Running}}", self.backend).stdout.strip() != "true":
                raise AssertionError("backend exited during readiness")
            try:
                if self.backend_ready():
                    return
            except OSError:
                time.sleep(.2)
        raise AssertionError("gateway was not ready within 10 seconds")

    def stop_backend(self):
        self.docker("stop", "--time", "35", self.backend, timeout=45)

    def verify(self):
        image_info = json.loads(self.docker("image", "inspect", self.args.image).stdout)[0]
        assert (image_info["Os"], image_info["Architecture"]) == ("linux", "amd64")
        self.docker("image", "inspect", "python:3.13-slim-bookworm")
        self.manifest["resources"]["image_digest"] = self.docker(
            "image", "inspect", "-f", "{{.Id}}", self.args.image).stdout.strip()
        self.create_resource("volume",self.volume)
        self.create_resource("volume",self.backup_volume)
        self.create_resource("network",self.network,"--internal")
        self.docker("run", "--rm", "--user", "0:0", "--mount",
            f"type=volume,src={self.volume},dst=/data", "--entrypoint", "/bin/sh",
            "--mount", f"type=volume,src={self.backup_volume},dst=/backups",
            self.args.image, "-c", "chown 10001:10001 /data /backups")
        server_id = self.admin("init")["server_id"]
        creds = []
        for client in ("client-a", "client-b"):
            home = self.root / client
            home.mkdir()
            enrollment = json.loads(self.cli(client, "remote", "keygen", "--directory",
                                             home / "key").stdout)
            file = self.root / f"{client}-enrollment.json"
            file.write_text(json.dumps(enrollment) + "\n", encoding="utf-8", newline="\n")
            result = self.docker("run", "--rm", "--user", "10001:10001", "--network",
                self.network, "--mount", f"type=volume,src={self.volume},dst=/data",
                "--mount", f"type=bind,src={file},dst=/enrollment.json,readonly",
                "--entrypoint", "tasks-server", self.args.image, "--data-root", "/data",
                "admin", "register", "--registration-file", "/enrollment.json")
            creds.append(json.loads(result.stdout)["credential_id"])
        self.start_gateway_tls()
        self.start_backend()
        ca = self.root / "tls" / "ca.pem"
        for client, route, credential in zip(("client-a", "client-b"),
                                              ("lan", "public"), creds):
            self.cli(client, "remote", "configure", "--server-url",
                self.manifest["resources"][route + "_url"], "--server-id", server_id,
                "--credential-id", credential, "--credential-file",
                self.root / client / "key" / "signing-key.pem", "--private-ca", ca)
        self.record("two signed HTTPS profiles", {"server_id": server_id})
        self.assert_nonce_replay_refused()
        workspace = self.root / "workspace"
        workspace.mkdir()
        project = json.loads(self.cli("client-a", "init", "--root", workspace,
                                      "--key", "FIX").stdout)["project_id"]
        body = "Full body Ω\nsecond line\n"
        (self.root / "body.txt").write_text(body, encoding="utf-8", newline="\n")
        created = json.loads(self.cli("client-a", "--project", project, "create", "--title",
            "container proof", "--body-file", self.root / "body.txt").stdout)
        task = created["data"]["display_id"]
        shown = json.loads(self.cli("client-b", "--project", project, "show", task).stdout)
        assert shown["data"]["body"] == body
        history = json.loads(self.cli("client-b", "--project", project, "history", task).stdout)
        assert history["data"]["items"] and history["data"]["items"][0]["attribution"]["actor_authority"] == "credential"
        self.record("cross-route project, body, history and attribution", {"project_id": project, "task": task})
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(self.cli, client, "--project", project, "update", task,
                                   "--expect-version", "1", "--title", title, ok=(0, 4))
                       for client, title in (("client-a", "first edit"),
                                             ("client-b", "second edit"))]
            outcomes = [future.result() for future in futures]
        assert sorted(p.returncode for p in outcomes) == [0, 4]
        conflict = next(p for p in outcomes if p.returncode == 4)
        assert json.loads(conflict.stderr)["error"]["conflict"] == {"expected": 1, "current": 2}
        event_count = len(json.loads(self.cli("client-a", "--project", project,
                                           "history", task).stdout)["data"]["items"])
        assert event_count == 2
        self.record("stale version rejected without extra event")
        self.drop_next = True
        unknown = self.cli("client-a", "--project", project, "create", "--title",
                           "lost acknowledgement", "--body-file", self.root / "body.txt", ok=(5,))
        assert self.dropped.is_set()
        request_id = json.loads(unknown.stderr)["error"]["request_id"]
        pending = json.loads(self.cli("client-a", "remote", "pending").stdout)
        assert [v["request_id"] for v in pending["data"]["items"]] == [request_id]
        self.stop_backend()
        self.docker("start", self.backend)
        self.start_wait_backend()
        self.assert_nonce_replay_refused()
        self.record("signed nonce replay refused on other route before and after restart")
        replay = json.loads(self.cli("client-a", "remote", "reconcile", request_id).stdout)
        assert replay == self.lost_reply
        assert not json.loads(self.cli("client-a", "remote", "pending").stdout)["data"]["items"]
        recovered = replay["data"]["display_id"]
        recovered_show = json.loads(self.cli("client-b", "--project", project, "show", recovered).stdout)
        recovered_history = json.loads(self.cli("client-b", "--project", project, "history", recovered).stdout)
        assert recovered_show["data"]["version"] == 1 and recovered_show["data"]["body"] == body
        assert len(recovered_history["data"]["items"]) == 1
        assert recovered_history["data"]["items"][0]["attribution"]["request_id"] == request_id
        listed = json.loads(self.cli("client-a", "--project", project, "list", "--open", "--limit", "10").stdout)
        assert len(listed["data"]["items"]) == 2
        self.record("lost acknowledgement, restart and exact request replay", {"request_id": request_id})
        self.stop_backend()
        self.admin("revoke", creds[1])
        self.docker("start", self.backend)
        self.start_wait_backend()
        refused = self.cli("client-b", "--project", project, "show", task, ok=(5,))
        assert "revok" in refused.stderr.lower() or "credential" in refused.stderr.lower()
        profile = self.root / "client-b" / "client.toml"
        original_profile = profile.read_text(encoding="utf-8")
        profile.write_text(original_profile.replace(
            self.manifest["resources"]["public_url"],
            self.manifest["resources"]["lan_url"]), encoding="utf-8", newline="\n")
        refused_lan = self.cli("client-b", "--project", project, "show", task, ok=(5,))
        assert "revok" in refused_lan.stderr.lower() or "credential" in refused_lan.stderr.lower()
        profile.write_text(original_profile, encoding="utf-8", newline="\n")
        self.cli("client-a", "--project", project, "show", task)
        self.record("revoked credential rejected on both routes; other credential survives")
        bad_url = self.manifest["resources"]["lan_url"].replace("localhost", "127.0.0.1")
        bad = self.cli("client-a", "remote", "configure", "--server-url",
            bad_url, "--server-id", server_id,
            "--credential-id", creds[0], "--credential-file",
            self.root / "client-a" / "key" / "signing-key.pem", "--private-ca", ca, ok=(5,))
        assert bad.returncode == 5
        self.record("TLS hostname mismatch rejected")
        self.stop_backend()
        backup = self.admin("backup", "--out", "/backups/proof-backup")
        assert backup["server_id"] == server_id
        copied = self.root / "verified-backup"
        exporter = self.prefix + "-exporter"
        self.create_resource("container",exporter,"create", "--name", exporter,"--label",f"tasks-proof.run={self.prefix}", "--mount",
                    f"type=volume,src={self.backup_volume},dst=/backups", self.args.image)
        self.docker("cp", f"{exporter}:/backups/proof-backup", copied)
        source_manifest = json.loads((copied / "manifest.json").read_text(encoding="utf-8"))
        assert source_manifest["server_id"] == server_id
        for item in source_manifest["files"]:
            p = copied / item["path"]
            assert hashlib.sha256(p.read_bytes()).hexdigest() == item["sha256"]
            assert p.stat().st_size == item["bytes"]
            with sqlite3.connect(str(p)) as db:
                assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
                assert not db.execute("PRAGMA foreign_key_check").fetchall()
                for table, count in item["counts"]:
                    assert table in {"projects", "credentials", "replay_nonces", "admin_events",
                                     "tasks", "dependencies", "events", "imports",
                                     "metadata_events", "mutation_receipts"}
                    assert db.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0] == count
        with sqlite3.connect(str(copied / "server.sqlite")) as catalog:
            assert catalog.execute("SELECT server_id FROM server_identity").fetchone()[0] == server_id
            assert catalog.execute("SELECT revoked FROM credentials WHERE credential_id=?",
                                   (creds[1],)).fetchone()[0] == 1
        restored = self.admin("restore", "--backup", "/backups/proof-backup",
                              "--out", "/backups/proof-restored")
        assert restored["server_id"] == server_id
        restored_copy = self.root / "verified-restored"
        self.docker("cp", f"{exporter}:/backups/proof-restored", restored_copy)
        restored_manifest = json.loads((restored_copy / "manifest.json").read_text(encoding="utf-8"))
        assert restored_manifest == source_manifest
        for item in source_manifest["files"]:
            assert hashlib.sha256((restored_copy / item["path"]).read_bytes()).hexdigest() == item["sha256"]
        self.record("stopped-service online backup and verified restore",
                    {"databases": backup["databases"], "backup_manifest": str(copied / "manifest.json")})

    def assert_nonce_replay_refused(self):
        assert self.signed_read is not None
        method, path, body, headers = self.signed_read
        port = int(self.manifest["resources"]["public_url"].rsplit(":", 1)[1])
        context = ssl.create_default_context(cafile=str(self.root / "tls" / "ca.pem"))
        conn = http.client.HTTPSConnection("localhost", port, context=context, timeout=8)
        try:
            conn.request(method, path, body=body, headers=headers)
            reply = conn.getresponse()
            payload = reply.read()
            assert reply.status == 401 and b"nonce was already used" in payload
        finally:
            conn.close()

    def start_wait_backend(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                if self.backend_ready():
                    return
            except OSError:
                time.sleep(.2)
        raise AssertionError("backend did not become reachable within 10 seconds")

    def backend_ready(self):
        conn = http.client.HTTPConnection("127.0.0.1",self.gateway_port,timeout=.4)
        try:
            conn.request("GET","/v1/info")
            response = conn.getresponse()
            response.read(513)
            return response.status == 401
        except (OSError,http.client.HTTPException):
            return False
        finally:
            conn.close()

    def cleanup(self):
        for server in self.tls_servers:
            server.shutdown()
            server.server_close()
        for name in tuple(self.created["container"]):
            with contextlib.suppress(Exception):
                if self.owns_resource("container",name):
                    self.docker("rm", "-f", name, ok=(0, 1), timeout=20)
        for kind in ("network","volume"):
            for name in tuple(self.created[kind]):
                with contextlib.suppress(Exception):
                    if self.owns_resource(kind,name):
                        self.docker(kind, "rm", name, ok=(0, 1), timeout=20)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--tasks", type=Path, required=True)
    parser.add_argument("--docker", default="docker")
    args = parser.parse_args()
    if not args.fixture_root.is_absolute() or args.fixture_root.exists():
        parser.error("--fixture-root must be a new absolute path")
    if not args.tasks.is_absolute() or not args.tasks.is_file():
        parser.error("--tasks must be an existing absolute CLI path")
    args.fixture_root.mkdir(parents=True)
    proof = Proof(args)
    try:
        proof.verify()
        proof.manifest["result"] = "pass"
    except Exception as e:
        proof.manifest["result"] = "fail"
        proof.manifest["failure"] = repr(e)
        raise
    finally:
        proof.write_manifest()
        proof.cleanup()
    print(proof.root / "manifest.json")


if __name__ == "__main__":
    main()
