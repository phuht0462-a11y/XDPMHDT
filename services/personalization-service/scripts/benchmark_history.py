"""Measure the actual MySQL 8 query plan before/after the W7 index.

Uses a NEW disposable schema, never the application's schema or volume.
Requires Python 3 + Docker with the existing MySQL container running.
Password is prompted, never printed or stored in the evidence JSON.
"""
import argparse
import getpass
import json
import math
import os
import platform
import re
import statistics
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path


def summarize(samples):
    ordered = sorted(samples)
    return {"samples_ms": samples, "median_ms": statistics.median(samples),
            "p95_ms": ordered[math.ceil(.95 * len(ordered)) - 1]}


def root_ms(plan):
    # Root iterator duration, not a sum of nested iterator durations.
    match = re.search(r"actual time=([\d.]+)\.\.([\d.]+) rows=", plan)
    if not match:
        raise RuntimeError("MySQL did not return an EXPLAIN ANALYZE actual time")
    return float(match.group(2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='smart_heritage_mysql')
    parser.add_argument('--user', default='root')
    parser.add_argument('--mysql-bin', help='Use a local mysql client instead of docker exec')
    parser.add_argument('--port', type=int, default=3307)
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--output', type=Path, default=Path('personalization-index-results.json'))
    args = parser.parse_args()
    if args.samples < 5:
        parser.error('--samples must be at least 5')
    environment = os.environ.copy()
    if 'MYSQL_PWD' not in environment:
        environment['MYSQL_PWD'] = getpass.getpass('MySQL password: ')
    schema = 'phu_w7_bench_' + uuid.uuid4().hex[:12]

    def sql(statement):
        command = ([args.mysql_bin, '--protocol=TCP', '-h', '127.0.0.1', '-P', str(args.port)]
                   if args.mysql_bin else ['docker', 'exec', '-i', '-e', 'MYSQL_PWD', args.container, 'mysql'])
        result = subprocess.run(command + ['-u', args.user, '--batch', '--raw', '--skip-column-names'],
                                input=statement, text=True, encoding='utf-8', env=environment,
                                capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return result.stdout.strip()

    version = sql('SELECT VERSION();')
    if not version.startswith('8.'):
        raise RuntimeError('This benchmark requires MySQL 8, got ' + version)
    # The generated schema name is restricted to a constant prefix + hex digits.
    sql(f'CREATE DATABASE `{schema}`;')
    try:
        sql(f'''USE `{schema}`;
CREATE TABLE digits (d INT NOT NULL PRIMARY KEY);
INSERT INTO digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
CREATE TABLE visits (
 id BIGINT NOT NULL PRIMARY KEY AUTO_INCREMENT,
 user_id BIGINT NOT NULL, artifact_id BIGINT NOT NULL,
 detected_at DATETIME NOT NULL, duration_seconds INT NULL,
 client_event_id VARCHAR(36), source VARCHAR(20) NOT NULL,
 UNIQUE KEY uq_visits_user_event (user_id, client_event_id),
 KEY idx_visits_artifact (artifact_id)
) ENGINE=InnoDB;
INSERT INTO visits (user_id, artifact_id, detected_at, duration_seconds, client_event_id, source)
SELECT IF(n < 200000, 1, 2 + MOD(n, 100)), 1 + MOD(n, 6),
 DATE_ADD('2026-01-01', INTERVAL MOD(n * 7919, 20000000) SECOND),
 30, MD5(CAST(n AS CHAR)), 'BEACON'
FROM (SELECT a.d+10*b.d+100*c.d+1000*d.d+10000*e.d+100000*f.d AS n
 FROM digits a CROSS JOIN digits b CROSS JOIN digits c CROSS JOIN digits d
 CROSS JOIN digits e CROSS JOIN digits f) source_rows WHERE n < 300000;
ANALYZE TABLE visits;''')
        query = 'SELECT * FROM visits WHERE user_id = 1 ORDER BY detected_at DESC LIMIT 20'
        # Match the data and count queries produced for a Spring Data Page.
        queries = {'page': query, 'count': 'SELECT COUNT(*) FROM visits WHERE user_id = 1'}
        counts = sql(f'USE `{schema}`; SELECT COUNT(*), SUM(user_id=1) FROM visits;')
        evidence = {'measured_at_utc': datetime.now(timezone.utc).isoformat(),
                    'mysql_version': version, 'client_platform': platform.platform(),
                    'total_rows_and_target_user_rows': counts, 'samples_per_query': args.samples,
                    'metric': 'EXPLAIN ANALYZE root iterator end time, milliseconds; warm cache',
                    'queries': queries, 'before': {}, 'after': {}}
        baseline_rows = sql(f'USE `{schema}`; {query};')
        for phase in ('before', 'after'):
            if phase == 'after':
                sql(f'USE `{schema}`; ALTER TABLE visits ADD INDEX idx_visits_user_detected (user_id, detected_at); ANALYZE TABLE visits;')
            for name, statement in queries.items():
                explain = f'USE `{schema}`; EXPLAIN ANALYZE {statement};'
                for _ in range(3):
                    sql(explain)
                plans = [sql(explain) for _ in range(args.samples)]
                evidence[phase][name] = summarize([root_ms(plan) for plan in plans])
                evidence[phase][name]['plan'] = plans[-1]
        if sql(f'USE `{schema}`; {query};') != baseline_rows:
            raise RuntimeError('Query results changed after adding the index')
        evidence['same_page_before_after'] = True
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding='utf-8')
        print(f'Evidence written: {args.output}')
        for name in queries:
            print(name, 'median ms:', evidence['before'][name]['median_ms'], '->',
                  evidence['after'][name]['median_ms'])
    finally:
        # Only remove the schema successfully created by this invocation.
        sql(f'DROP DATABASE `{schema}`;')


if __name__ == '__main__':
    main()
