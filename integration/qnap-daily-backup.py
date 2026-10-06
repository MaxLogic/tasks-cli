#!/usr/local/bin/python
"""QNAP daily complete snapshots; compatible with its existing Python 2.7/3."""
from __future__ import print_function

import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

BASE = '/share/Container/tasks-server'
BACKUPS = BASE + '/backups'
DOCKER = '/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker'
SERVER = 'qnap-tasks-server'
SERVER_ID = '8748aad8-d5cd-4c00-881b-842938eee52b'
LOCK = BASE + '/daily-backup.lock'
RECOVERY = BASE + '/daily-backup-recovery.json'
ARCHIVE_NAME = re.compile(r'^tasks-snapshot-(\d{8})T\d{6}[+-]\d{4}\.tgz\Z')
DB_PATH = re.compile(r'^projects/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/TASKS\.sqlite\Z')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def log(message):
    print(time.strftime('%Y-%m-%dT%H:%M:%S%z') + ' ' + message)


def command(args, seconds=60):
    """Bound each owned Docker CLI process without filling a pipe buffer."""
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT,
                                   close_fds=True)
        deadline = time.time() + seconds
        try:
            while process.poll() is None:
                if time.time() >= deadline:
                    raise RuntimeError('Command timed out: ' + ' '.join(args))
                time.sleep(0.2)
        finally:
            if process.poll() is None:
                process.terminate()
                until = time.time() + 5
                while process.poll() is None and time.time() < until:
                    time.sleep(0.2)
                if process.poll() is None:
                    process.kill()
                process.wait()
        output.seek(0)
        result = output.read().decode('utf-8', 'replace')
        require(process.returncode == 0, 'Command failed: ' + result[-2000:])
        return result


def verify_archive(path):
    """Read gzip to EOF and verify every database against the embedded manifest."""
    with tarfile.open(path, 'r:gz') as archive:
        members = archive.getmembers()
        require(all(m.isfile() for m in members), 'Unexpected archive member type')
        names = [m.name for m in members]
        require(len(names) == len(set(names)), 'Duplicate archive members')
        manifest = json.load(archive.extractfile('manifest.json'))
        require(manifest['format'] == 1 and manifest['server_id'] == SERVER_ID,
                'Incorrect snapshot identity/format')
        entries = manifest['files']
        expected = set(['manifest.json'])
        for entry in entries:
            name = entry['path']
            require(name == 'server.sqlite' or DB_PATH.match(name), 'Unsafe database path')
            require(name not in expected, 'Duplicate manifest database')
            expected.add(name)
            digest = hashlib.sha256()
            size = 0
            stream = archive.extractfile(name)
            try:
                while True:
                    block = stream.read(65536)
                    if not block:
                        break
                    size += len(block)
                    digest.update(block)
            finally:
                stream.close()
            require(size == entry['bytes'] and digest.hexdigest() == entry['sha256'],
                    'Archived database hash/size mismatch: ' + name)
        require('server.sqlite' in expected and set(names) == expected,
                'Incomplete archive or unexpected files')
        # Consume gzip's trailer too, so a damaged CRC/footer is refused.
        while archive.fileobj.read(65536):
            pass
        return len(entries)


def prune():
    oldest = datetime.date.today() - datetime.timedelta(days=6)
    for name in sorted(os.listdir(BACKUPS)):
        match = ARCHIVE_NAME.match(name)
        if not match:
            continue
        path = os.path.join(BACKUPS, name)
        if not stat.S_ISREG(os.lstat(path).st_mode):
            continue
        try:
            date = datetime.datetime.strptime(match.group(1), '%Y%m%d').date()
        except ValueError:
            continue
        if date < oldest:
            os.unlink(path)
            log('Removed expired archive ' + name)


def interrupted(signum, frame):
    raise KeyboardInterrupt('signal ' + str(signum))


def process_identity(pid):
    try:
        with open('/proc/' + str(pid) + '/stat') as source:
            text = source.read()
        fields = text[text.rfind(')') + 2:].split()
        return None if fields[0] == 'Z' else fields[19]  # Kernel process start ticks.
    except IOError:
        return None


def save_recovery(record):
    fd, temporary = tempfile.mkstemp(prefix='.daily-recovery-', dir=BASE)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(record, output)
            output.flush()
            os.fsync(output.fileno())
        os.rename(temporary, RECOVERY)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def remove_admin(name):
    require(re.match(r'^tasks-daily-backup-[0-9a-f]{32}\Z', name), 'Unsafe admin container name')
    found = command([DOCKER, 'ps', '-aq', '--no-trunc', '--filter', 'name=^/' + name + '$']).strip()
    if found:
        require(re.match(r'^[0-9a-f]{64}\Z', found), 'Unexpected admin container match')
        inspected = json.loads(command([DOCKER, 'inspect', found]))[0]
        require(inspected['Name'] == '/' + name, 'Different admin container matched')
        command([DOCKER, 'rm', '-f', found])


def recover(record):
    """Called with the job lock held, only after its coordinator has exited."""
    require(process_identity(record['pid']) != record['started'], 'Backup coordinator is still alive')
    require(re.match(r'^[0-9a-f]{64}\Z', record['container']), 'Unsafe recovery container identity')
    inspected = json.loads(command([DOCKER, 'inspect', record['container']]))[0]
    require(inspected['Name'] == '/' + SERVER and any(
        m['Destination'] == '/data' and os.path.realpath(m['Source']) == os.path.realpath(BASE + '/data')
        for m in inspected['Mounts']), 'Recovery target differs from task server')
    remove_admin(record['admin'])
    if record['restart_required']:
        if not json.loads(command([DOCKER, 'inspect', record['container']]))[0]['State']['Running']:
            command([DOCKER, 'start', record['container']])
        require(json.loads(command([DOCKER, 'inspect', record['container']]))[0]['State']['Running'],
                'Interrupted backup recovery could not restart the server')
    work = record['work']
    require(os.path.dirname(work) == BACKUPS and os.path.basename(work).startswith('.daily-work-'),
            'Unsafe interrupted workspace')
    partial = record['partial']
    require(os.path.dirname(partial) == BACKUPS and partial.endswith('.tgz.partial')
            and ARCHIVE_NAME.match(os.path.basename(partial[:-8])), 'Unsafe partial archive')
    if os.path.lexists(partial):
        os.unlink(partial)
    if os.path.exists(work):
        shutil.rmtree(work)
    os.unlink(RECOVERY)
    log('Recovered interrupted backup; original server state restored')


def watch(token):
    require(re.match(r'^[0-9a-f]{32}\Z', token), 'Invalid watcher identity')
    ready = BASE + '/.daily-watch-ready-' + token
    with open(RECOVERY) as source:
        record = json.load(source)
    require(record['token'] == token, 'Watcher recovery identity differs')
    fd = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    while os.path.exists(RECOVERY):
        with open(RECOVERY) as source:
            record = json.load(source)
        if record['token'] != token:
            return
        if process_identity(record['pid']) != record['started']:
            with open(LOCK, 'a+b') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                if not os.path.exists(RECOVERY):
                    return
                with open(RECOVERY) as source:
                    current = json.load(source)
                if current['token'] == token:
                    recover(current)
            return
        time.sleep(1)


def snapshot():
    require(os.geteuid() == 0, 'Run as the QNAP admin/root cron user')
    require(os.path.isdir(BACKUPS) and not os.path.islink(BACKUPS), 'Unsafe backup directory')
    inspected = json.loads(command([DOCKER, 'inspect', SERVER]))[0]
    container = inspected['Id']
    image = inspected['Image']  # Immutable ID of this installation, never a mutable tag.
    mounts = [m for m in inspected['Mounts'] if m['Destination'] == '/data']
    require(len(mounts) == 1 and os.path.realpath(mounts[0]['Source']) == os.path.realpath(BASE + '/data'),
            'Unexpected live authority mount')
    require(inspected['Config']['User'] == '10001:10001', 'Unexpected service identity')
    timestamp = time.strftime('%Y%m%dT%H%M%S%z')
    final = os.path.join(BACKUPS, 'tasks-snapshot-' + timestamp + '.tgz')
    require(not os.path.lexists(final), 'Archive name already exists')
    work = tempfile.mkdtemp(prefix='.daily-work-', dir=BACKUPS)
    os.chmod(work, 0o700)
    os.chown(work, 10001, 10001)
    admin = 'tasks-daily-backup-' + uuid.uuid4().hex
    partial = final + '.partial'
    restart = False
    admin_started = False
    admin_clean = True
    recovery = {'token': uuid.uuid4().hex, 'pid': os.getpid(), 'started': process_identity(os.getpid()),
                'container': container, 'admin': admin, 'work': work, 'partial': partial,
                'restart_required': bool(inspected['State']['Running'])}
    require(not os.path.exists(RECOVERY), 'Unresolved previous backup recovery')
    save_recovery(recovery)
    ready = BASE + '/.daily-watch-ready-' + recovery['token']
    with open(os.devnull, 'rb') as stdin, open(BASE + '/daily-backup.log', 'ab') as output:
        watcher = subprocess.Popen([sys.executable, os.path.realpath(__file__), '--watch', recovery['token']],
                                   stdin=stdin, stdout=output, stderr=subprocess.STDOUT,
                                   close_fds=True, preexec_fn=os.setsid)
    try:
        deadline = time.time() + 10
        while not os.path.exists(ready):
            require(watcher.poll() is None and time.time() < deadline, 'Recovery watcher failed to start')
            time.sleep(0.1)
        os.unlink(ready)
        log('Creating snapshot ' + timestamp)
        try:
            if inspected['State']['Running']:
                restart = True  # Also restart after a partially successful stop.
                command([DOCKER, 'stop', '--time', '30', container])
            admin_started = True
            result = json.loads(command([
                DOCKER, 'run', '--rm', '--name', admin, '--network', 'none',
                '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
                '--user', '10001:10001', '-v', BASE + '/data:/data',
                '-v', work + ':/backup', image,
                'admin', 'backup', '--out', '/backup/snapshot'], seconds=300))
            admin_started = False  # Successful --rm completed and released server.lock.
            require(result['server_id'] == SERVER_ID, 'Snapshot server identity differs')
        finally:
            try:
                if admin_started:
                    # A timed-out Docker CLI may leave its daemon-owned container alive.
                    remove_admin(admin)
            except Exception:
                # Retain any workspace still mounted by an unconfirmed child.
                admin_clean = False
                raise
            finally:
                if restart:
                    command([DOCKER, 'start', container])
                    require(json.loads(command([DOCKER, 'inspect', container]))[0]['State']['Running'],
                            'Tasks server did not restart')
                    log('Tasks server restarted; compression runs with the API online')
            if admin_clean:
                recovery['restart_required'] = False
                save_recovery(recovery)
        source = os.path.join(work, 'snapshot')
        with open(os.path.join(source, 'manifest.json'), 'rb') as document:
            manifest = json.load(document)
        require(manifest['server_id'] == SERVER_ID, 'Manifest server identity differs')
        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as output:
            with tarfile.open(fileobj=output, mode='w:gz') as archive:
                for name in ['manifest.json'] + [e['path'] for e in manifest['files']]:
                    require(name in ('manifest.json', 'server.sqlite') or DB_PATH.match(name),
                            'Unsafe snapshot path')
                    path = os.path.join(source, name)
                    require(stat.S_ISREG(os.lstat(path).st_mode), 'Snapshot file is not regular')
                    archive.add(path, arcname=name, recursive=False)
            output.flush()
            os.fsync(output.fileno())
        count = verify_archive(partial)
        require(count == result['databases'], 'Archived database count differs')
        os.link(partial, final)  # Atomic publication that refuses overwrite.
        os.unlink(partial)
        directory = os.open(BACKUPS, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        log('Published ' + final + ' (' + str(count) + ' verified databases)')
        prune()  # Never prune after a failed snapshot, archive or verification.
    finally:
        if os.path.lexists(partial):
            os.unlink(partial)
        if admin_clean:
            require(os.path.dirname(work) == BACKUPS and os.path.basename(work).startswith('.daily-work-'),
                    'Unsafe workspace cleanup')
            shutil.rmtree(work)
            # Only disarm after a confirmed restart and complete owned cleanup.
            if not recovery['restart_required']:
                os.unlink(RECOVERY)
        if os.path.exists(ready):
            os.unlink(ready)


def main():
    os.umask(0o077)
    signal.signal(signal.SIGTERM, interrupted)
    require(os.geteuid() == 0, 'Run as the QNAP admin/root cron user')
    if len(sys.argv) == 3 and sys.argv[1] == '--watch':
        watch(sys.argv[2])
        return
    require(len(sys.argv) == 1, 'Unsupported backup arguments')
    with open(LOCK, 'a+b') as lock:
        os.chmod(LOCK, 0o600)
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except IOError:
            log('Another backup is running; skipped')
            return
        if os.path.exists(RECOVERY):
            with open(RECOVERY) as source:
                recover(json.load(source))
        snapshot()


if __name__ == '__main__':
    main()
