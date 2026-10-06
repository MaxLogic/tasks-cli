#!/usr/bin/env python3
"""Windows-owned snapshot/migration for an explicitly authorized whole-store cutover.

Keeps SQLite writer reservations and the registry lock until the coordinator
publishes release.json in --state-root. Never migrates source databases. The
coordinator must stop the viewer before launch, verify/import the copies, and
select the remote profile before retiring the local write authority.
"""
import argparse
from contextlib import closing
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time
import uuid

TABLES = ('project', 'tasks', 'dependencies', 'task_labels', 'events', 'imports', 'sqlite_sequence')

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def evidence(path, columns=None):
    with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=10)) as db:
        require(db.execute('pragma integrity_check').fetchone()[0] == 'ok', 'SQLite integrity failed')
        require(not db.execute('pragma foreign_key_check').fetchall(), 'Foreign key check failed')
        result = {'schema': db.execute('pragma user_version').fetchone()[0], 'tables': {}}
        project = db.execute('select project_id, project_key from project').fetchone()
        result.update(project_id=project[0], project_key=project[1])
        for table in TABLES:
            names = columns[table] if columns else [r[1] for r in db.execute('pragma table_info("' + table + '")')]
            sql = 'select ' + ','.join('"' + n + '"' for n in names) + ' from "' + table + '"'
            if table == 'sqlite_sequence':
                sql += " where name != 'metadata_events'"  # New archive sequence is verified separately.
            encoded = sorted(json.dumps(row, ensure_ascii=False, separators=(',', ':'), default=lambda v: {'sqlite_blob_hex': v.hex()} if isinstance(v, bytes) else (_ for _ in ()).throw(TypeError(type(v).__name__))) for row in db.execute(sql))
            digest = hashlib.sha256()
            for row in encoded:
                digest.update(row.encode('utf-8')); digest.update(b'\n')
            result['tables'][table] = {'columns': names, 'rows': len(encoded), 'sha256': digest.hexdigest()}
        return result

def run_cli(executable, root, project, *args):
    env = os.environ.copy()
    for key in ('TASKS_PROJECT', 'TASKS_WINDOWS_EXE', 'TASKS_CONTEXT_FILE', 'TASKS_CLIENT_DIR'):
        env.pop(key, None)
    p = subprocess.run([str(executable), '--data-root', str(root), '--project', project,
                        '--format', 'json', *map(str, args)], env=env, capture_output=True,
                       encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW, timeout=60)
    require(p.returncode == 0, 'CLI ' + args[0] + ' failed for ' + project + ': ' + p.stderr[-1200:])
    return json.loads(p.stdout)

def preserve_archive(copy, timestamp):
    # Explicit legacy-cache conversion on an isolated copy. Keep the original
    # archive timestamp and mark its author unavailable rather than inventing
    # attribution. Task/history rows remain unchanged and are compared below.
    fields = ('actor_id', 'actor_name', 'machine_id', 'machine_name', 'registered_machine_name',
              'harness_version', 'session_id', 'harness_session_id', 'session_name', 'model',
              'agent_id', 'caller_executable', 'harness_executable', 'origin_platform')
    attribution = {name: None for name in fields}
    attribution.update(schema_version=1, request_id=str(uuid.uuid4()), harness='unknown',
                       actor_authority='unavailable', context_source={n: 'unavailable' for n in (*fields, 'harness')})
    with closing(sqlite3.connect(copy)) as db:
        watermark, last = db.execute('select coalesce(max(event_id),0),max(created_ms) from events').fetchone()
        if last is not None and last > timestamp:
            return False  # The old cache's archive was already invalidated by a later task write.
        require(db.execute('select count(*) from metadata_events').fetchone()[0] == 0,
                'Unexpected metadata before legacy archive conversion')
        db.execute('insert into metadata_events(operation,created_ms,snapshot_json,attribution_json) values(?,?,?,?)',
                   ('viewer-archive', timestamp,
                    json.dumps({'archived_at_ms': timestamp, 'task_event_watermark': watermark}), json.dumps(attribution)))
        db.commit()
    return True

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--backup-root', type=Path, required=True)
    parser.add_argument('--state-root', type=Path, required=True)
    parser.add_argument('--installed-cli', type=Path, required=True)
    parser.add_argument('--candidate-cli', type=Path, required=True)
    args = parser.parse_args()
    require(os.name == 'nt', 'Run on Windows; never open the live Windows store with Linux SQLite')
    source = args.source_root.resolve(); backup = args.backup_root.resolve(); state = args.state_root.resolve()
    require(source.is_dir() and (source / 'projects').is_dir(), 'Missing source store')
    require(backup.is_dir() and not any(backup.iterdir()), 'Backup root must already be protected and empty')
    require(source != backup and source not in backup.parents, 'Backups must be outside the source store')
    require(not (source / 'client.toml').exists(), 'Existing default profile; re-evaluate cutover')
    require(state.is_dir() and not any(state.iterdir()), 'State root must be fresh and empty')
    release_token = str(uuid.uuid4())
    connections = []; lock = None; registry_locked = False
    try:
        lock = (source / 'registry.lock').open('r+b')
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        registry_locked = True
        registry_bytes = (source / 'registry.json').read_bytes()
        registry = json.loads(registry_bytes)
        paths = sorted((source / 'projects').glob('*/TASKS.sqlite'))
        require({p.parent.name for p in paths} == {b['project_id'] for b in registry['bindings']},
                'Registry/database selection mismatch; inspect before cutting over')
        for path in paths:
            connection = sqlite3.connect(path, timeout=10)
            connections.append(connection)
            connection.execute('pragma busy_timeout=10000')
            connection.execute('begin immediate')
        print('Writer reservations acquired for', len(paths), 'projects; registry frozen', flush=True)
        (backup / 'registry.json').write_bytes(registry_bytes)
        if (source / 'viewer-cache.sqlite3').exists():
            with closing(sqlite3.connect((source / 'viewer-cache.sqlite3').as_uri() + '?mode=ro', uri=True)) as src:
                with closing(sqlite3.connect(backup / 'viewer-cache.sqlite3')) as dst:
                    src.backup(dst)
        archives = {}
        if (backup / 'viewer-cache.sqlite3').exists():
            with closing(sqlite3.connect(backup / 'viewer-cache.sqlite3')) as db:
                archives = dict(db.execute('select project_id,archived_at_ms from project_cache where archived_at_ms is not null'))
        original = backup / 'original'; original.mkdir()
        upgraded = backup / 'upgraded'; upgraded.mkdir(); (upgraded / 'projects').mkdir()
        records = []; keys = set()
        for path in paths:
            project = path.parent.name
            destination = original / (project + '.sqlite')
            run_cli(args.installed_cli, source, project, 'backup', '--out', destination)
            before = evidence(destination)
            require(evidence(path) == before, 'Locked source differs from its original snapshot')
            require(before['schema'] == 6 and before['project_id'] == project, 'Unexpected source identity/schema')
            require(before['project_key'] not in keys, 'Duplicate project key')
            keys.add(before['project_key'])
            directory = upgraded / 'projects' / project; directory.mkdir()
            copy = directory / 'TASKS.sqlite'; shutil.copy2(destination, copy)
            run_cli(args.candidate_cli, upgraded, project, 'migrate')
            archive = preserve_archive(copy, archives[project]) if project in archives else False
            after = evidence(copy, {t: v['columns'] for t, v in before['tables'].items()})
            require(after['schema'] == 8 and before['tables'] == after['tables'], 'Migration changed legacy rows')
            with closing(sqlite3.connect(copy)) as db:
                require(not db.execute('select count(*) from events where attribution_json is not null').fetchone()[0],
                        'Legacy task authors must remain unavailable')
                require(db.execute('pragma wal_checkpoint(truncate)').fetchone()[0] == 0,
                        'Cannot flush the isolated upgraded copy')
                require(db.execute('pragma journal_mode=delete').fetchone()[0] == 'delete',
                        'Import copy must be standalone on its read-only NAS mount')
            roots = [b['root'] for b in registry['bindings'] if b['project_id'] == project]
            name = Path(roots[0]).name
            records.append({'project_id': project, 'project_key': before['project_key'], 'name': name,
                            'roots': roots, 'before': before, 'upgraded': str(copy),
                            'upgraded_sha256': hashlib.sha256(copy.read_bytes()).hexdigest(),
                            'archive_timestamp': archives[project] if archive else None})
            print('Verified snapshot and schema-8 copy:', before['project_key'], flush=True)
        require((source / 'registry.json').read_bytes() == registry_bytes, 'Registry changed despite reservation')
        manifest = {'source_root': str(source), 'backup_root': str(backup), 'registry_sha256': hashlib.sha256(registry_bytes).hexdigest(),
                    'projects': records, 'total_tasks': sum(r['before']['tables']['tasks']['rows'] for r in records),
                    'total_events': sum(r['before']['tables']['events']['rows'] for r in records)}
        (backup / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        (state / 'ready.json').write_text(json.dumps({'projects': len(records), 'tasks': manifest['total_tasks'],
            'events': manifest['total_events'], 'archives': sum(r['archive_timestamp'] is not None for r in records),
            'manifest': str(backup / 'manifest.json'), 'release_token': release_token}, indent=2), encoding='utf-8')
        print('Snapshots ready; retaining writer reservations until release.json', flush=True)
        while True:
            try:
                signal = json.loads((state / 'release.json').read_text())
                if signal.get('release') is True and signal.get('release_token') == release_token:
                    break
            except (OSError, ValueError):
                pass
            time.sleep(1)
    finally:
        for connection in connections:
            connection.rollback(); connection.close()
        if lock is not None:
            lock.seek(0)
            try:
                if registry_locked:
                    msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            finally:
                lock.close()
        print('Owned writer reservations released', flush=True)

if __name__ == '__main__':
    main()
