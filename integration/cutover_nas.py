#!/usr/bin/env python3
"""Import the explicit, verified cutover copies into the stopped empty QNAP server.

Run in WSL. Reads only closed snapshot files from Windows, never live Windows
SQLite. Failed imports leave the server stopped with the pre-import snapshot
and all imported state retained for operator inspection/recovery.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import runpy
import shlex
import subprocess
import tarfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
NAS = ROOT.parent / 'qnap-nas-maintenance'
D = '/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker'
BASE = '/share/Container/tasks-server'
IMAGE = 'tasks-server:reviewed-20261004'
IMAGE_ID = 'sha256:cd294eb7a7765b0e4fa23f8fef65f5af6b6f4e554a6d5a009b71a30cc162f91f'
SERVER_ID = '8748aad8-d5cd-4c00-881b-842938eee52b'

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def windows_path(path):
    return Path(subprocess.check_output(['wslpath', '-u', path], text=True).strip())

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--linux-registration', type=Path, required=True)
    parser.add_argument('--output-root', type=Path, required=True)
    parser.add_argument('--existing-credential-id', type=uuid.UUID, help='Resume only after verifying this enrollment against a stopped catalog snapshot')
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    out = args.output_root.resolve()
    require(out.is_dir() and not (out / 'nas-result.json').exists(), 'Existing result; inspect before resuming')
    require(manifest['projects'] and len({p['project_key'] for p in manifest['projects']}) == len(manifest['projects']),
            'Invalid cutover project selection')
    nas = runpy.run_path(str(NAS / 'scripts/nas-exec.py'))
    password = nas['dotenv'](NAS / '.env')['QNAP_SSH_USER_SUDO_PW']
    def sudo_bytes(command):
        p = subprocess.run(['ssh', '-o', 'BatchMode=yes', 'qnap-nas',
                            "sudo -S -p '' -k /bin/sh -c " + shlex.quote(command)],
                           input=(password + '\n').encode(), capture_output=True)
        require(p.returncode == 0, 'NAS command failed: ' + p.stderr.decode(errors='replace')[-1500:])
        return p.stdout
    def sudo(command):
        return sudo_bytes(command).decode()
    inspected = json.loads(sudo(D + ' inspect qnap-tasks-server'))[0]
    require(inspected['Image'] == IMAGE_ID, 'Unexpected running image')
    require(next(m['Source'] for m in inspected['Mounts'] if m['Destination'] == '/data') == BASE + '/data',
            'Unexpected authority mount')
    require(inspected['HostConfig']['PortBindings'] in ({}, None), 'Backend ports must remain unpublished')
    run = uuid.uuid4().hex
    work = BASE + '/cutover-' + run
    staging = '/share/Container/.tasks-cutover-upload-' + run
    sudo(f'set -eu; test ! -e {work}; mkdir -m 700 {work}; chown 10001:10001 {work}; test ! -e {staging}; mkdir -m 700 {staging}; chown qnap {staging}')
    archive = out / 'import-copies.tgz'
    with tarfile.open(archive, 'x:gz') as tar:
        for project in manifest['projects']:
            source = windows_path(project['upgraded'])
            require(hashlib.sha256(source.read_bytes()).hexdigest() == project['upgraded_sha256'], 'Copy hash changed')
            tar.add(source, arcname=project['project_id'] + '.sqlite', recursive=False)
        tar.add(args.linux_registration, arcname='linux-enrollment.json', recursive=False)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    stopped = False
    def admin(*arguments):
        return json.loads(sudo(f'{D} run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true --user 10001:10001 '
            f'-v {BASE}/data:/data -v {BASE}/backups:/backups -v {work}:/imports:ro {IMAGE_ID} admin ' + shlex.join(arguments)))
    try:
        with archive.open('rb') as source:
            subprocess.run(['ssh', '-o', 'BatchMode=yes', 'qnap-nas',
                            'umask 077; cat > ' + shlex.quote(staging + '/copies.tgz')], stdin=source, check=True)
        require(sudo('sha256sum ' + staging + '/copies.tgz').split()[0] == checksum, 'Upload checksum mismatch')
        sudo(f'set -eu; tar -xzf {staging}/copies.tgz -C {work}; chown -R 10001:10001 {work}; chmod 600 {work}/*')
        sudo(D + ' stop qnap-tasks-server'); stopped = True
        info = admin('info')
        require(info['server_id'] == SERVER_ID, 'Unexpected server UUID')
        before_name = 'pre-cutover-' + run
        before = admin('backup', '--out', '/backups/' + before_name)
        require(before['server_id'] == SERVER_ID and before['databases'] == 1, 'Invalid pre-cutover backup')
        baseline = json.loads(sudo('cat ' + BASE + '/backups/' + before_name + '/manifest.json'))
        catalog = next(f for f in baseline['files'] if f['path'] == 'server.sqlite')
        require(dict(catalog['counts'])['projects'] == 0, 'Authority is no longer empty; do not overwrite it')
        require(dict(catalog['counts'])['credentials'] == (2 if args.existing_credential_id else 1), 'Unexpected enrollment state')
        registered = {'server_id': SERVER_ID, 'credential_id': str(args.existing_credential_id)} if args.existing_credential_id else admin('register', '--registration-file', '/imports/linux-enrollment.json')
        imports = []
        for project in manifest['projects']:
            result = admin('import-project', '--database', '/imports/' + project['project_id'] + '.sqlite', '--name', project['name'])
            require(result['project_id'] == project['project_id'], 'Import UUID mismatch')
            # SQLite backup may change journal/header bytes. The coordinator
            # compares every logical row in the downloaded verified snapshot.
            imports.append(result)
            print('Imported', project['project_key'], flush=True)
        after_name = 'post-cutover-' + run
        after = admin('backup', '--out', '/backups/' + after_name)
        require(after['server_id'] == SERVER_ID and after['databases'] == len(imports) + 1, 'Incomplete server backup')
        snapshot = out / 'server-snapshot'; snapshot.mkdir()
        # Download a verified stopped-service SQLite snapshot to the protected
        # workstation destination before remote writes become authoritative.
        payload = sudo_bytes(f'tar -czf - -C {BASE}/backups/{after_name} .')
        with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as tar:
            for member in tar.getmembers():
                target = (snapshot / member.name).resolve()
                require(target == snapshot or snapshot in target.parents, 'Unsafe snapshot archive path')
                require(member.isdir() or member.isfile(), 'Unexpected snapshot archive member')
            tar.extractall(snapshot)
        snapshot_manifest = json.loads((snapshot / 'manifest.json').read_text())
        require(snapshot_manifest['server_id'] == SERVER_ID, 'Downloaded backup identity mismatch')
        for item in snapshot_manifest['files']:
            file = snapshot / item['path']
            require(file.stat().st_size == item['bytes'] and hashlib.sha256(file.read_bytes()).hexdigest() == item['sha256'],
                    'Downloaded snapshot hash mismatch')
        result = {'server_id': SERVER_ID, 'linux_credential': registered, 'imported_projects': imports,
                  'before_backup': before, 'after_backup': after, 'work': work,
                  'snapshot': str(snapshot), 'server_stopped': True}
        (out / 'nas-result.json').write_text(json.dumps(result, indent=2) + '\n')
        print('All imports and the off-NAS snapshot verified. Server remains stopped for coordinator comparison.', flush=True)
    except Exception:
        if stopped:
            print('Import incomplete: server intentionally remains stopped; retain private state/backups for recovery.', flush=True)
        raise
    finally:
        # Only this run's exact staging file/directory is removed; state and
        # verified import copies are retained in the root-private authority tree.
        nas['ssh']('rm -f -- ' + shlex.quote(staging + '/copies.tgz'), check=False)
        sudo('rmdir -- ' + shlex.quote(staging))

if __name__ == '__main__':
    main()
