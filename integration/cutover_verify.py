#!/usr/bin/env python3
"""Windows-owned full row comparison of the stopped NAS cutover backup."""
from contextlib import closing
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import sqlite3


def check(manifest_path, snapshot, baseline_catalog, output):
    helper = runpy.run_path(str(Path(__file__).with_name('cutover_snapshot.py')))
    require = helper['require']; evidence = helper['evidence']
    manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    downloaded = json.loads((snapshot / 'manifest.json').read_text())
    require(downloaded['server_id'] == '8748aad8-d5cd-4c00-881b-842938eee52b', 'Wrong server UUID')
    require(len(downloaded['files']) == len(manifest['projects']) + 1, 'Incomplete snapshot')
    for item in downloaded['files']:
        path = (snapshot / item['path']).resolve()
        require(snapshot.resolve() in path.parents, 'Invalid manifest path')
        require(path.stat().st_size == item['bytes'] and hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'], 'Snapshot digest mismatch')
    results = []
    for project in manifest['projects']:
        copy = Path(project['upgraded']); imported = snapshot / 'projects' / project['project_id'] / 'TASKS.sqlite'
        legacy = evidence(imported, {t:v['columns'] for t,v in project['before']['tables'].items()})
        require(legacy['schema'] == 8 and legacy['project_id'] == project['project_id'] and legacy['project_key'] == project['project_key'], 'Project identity/schema mismatch')
        require(legacy['tables'] == project['before']['tables'], 'Original task/history rows changed')
        with closing(sqlite3.connect(copy.as_uri() + '?mode=ro', uri=True)) as left, closing(sqlite3.connect(imported.as_uri() + '?mode=ro', uri=True)) as right:
            for table in ('metadata_events', 'mutation_receipts', 'sqlite_sequence'):
                require(left.execute('select * from ' + table + ' order by 1').fetchall() == right.execute('select * from ' + table + ' order by 1').fetchall(), 'Schema-8 metadata mismatch: ' + table)
            require(right.execute('select count(*) from mutation_receipts').fetchone()[0] == 0, 'Unexpected task mutation during import')
            require(right.execute('select count(*) from metadata_events').fetchone()[0] == int(project['archive_timestamp'] is not None), 'Archive conversion mismatch')
        results.append({'project_id':project['project_id'], 'project_key':project['project_key'], 'tasks':legacy['tables']['tasks']['rows'], 'events':legacy['tables']['events']['rows'], 'legacy_rows_identical':True, 'metadata_identical':True})
    with closing(sqlite3.connect((snapshot / 'server.sqlite').as_uri() + '?mode=ro', uri=True)) as db:
        require(db.execute('pragma integrity_check').fetchone()[0] == 'ok' and not db.execute('pragma foreign_key_check').fetchall(), 'Catalog integrity failed')
        require({r[0] for r in db.execute('select project_id from projects')} == {p['project_id'] for p in manifest['projects']}, 'Catalog UUID set mismatch')
        require({tuple(r) for r in db.execute('select project_id,name from projects')} == {(p['project_id'],p['name']) for p in manifest['projects']}, 'Catalog project labels differ')
        require(db.execute('select count(*) from credentials').fetchone()[0] == 2, 'Unexpected enrolled credentials')
        with closing(sqlite3.connect(baseline_catalog.as_uri() + '?mode=ro', uri=True)) as before:
            tables = [r[0] for r in db.execute("select name from sqlite_master where type='table' and name != 'projects'")]
            require(set(tables) == {r[0] for r in before.execute("select name from sqlite_master where type='table' and name != 'projects'")}, 'Catalog schema changed')
            for table in tables:
                require(db.execute('select * from '+table+' order by 1').fetchall() == before.execute('select * from '+table+' order by 1').fetchall(), 'Catalog enrollment/identity/history changed: '+table)
    result = {'server_id':downloaded['server_id'], 'projects':results, 'total_tasks':sum(p['tasks'] for p in results), 'total_events':sum(p['events'] for p in results), 'archives':sum(p['archive_timestamp'] is not None for p in manifest['projects']), 'catalog_integrity':True}
    output.write_text(json.dumps(result,indent=2)+'\n')
    print('Verified',len(results),'projects,',result['total_tasks'],'tasks,',result['total_events'],'events,',result['archives'],'archives; every legacy and metadata row matches.')

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest',type=Path,required=True);p.add_argument('--snapshot',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--baseline-catalog',type=Path,required=True)
    a=p.parse_args();check(a.manifest,a.snapshot,a.baseline_catalog,a.output)
