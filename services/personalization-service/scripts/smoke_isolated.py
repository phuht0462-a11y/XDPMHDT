"""Isolated Linux integration: real MySQL, personalization JAR and Gateway JAR.
Content is an HTTP fixture; Redis and RabbitMQ are unavailable deliberately.
This does NOT replace a Flutter/device or real RabbitMQ end-to-end test.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen, build_opener, ProxyHandler


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--java', required=True)
    p.add_argument('--mysql-home', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    repo = Path(__file__).resolve().parents[3]
    processes = []
    logs = []
    evidence = {'timestamp_utc': datetime.now(timezone.utc).isoformat(),
                'scope': 'Real MySQL + Spring Boot + Gateway; HTTP Content fixture; Redis/RabbitMQ absent',
                'checks': []}
    opener = build_opener(ProxyHandler({}))

    def port():
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            return s.getsockname()[1]

    db_port, service_port, gateway_port, redis_port, rabbit_port = [port() for _ in range(5)]
    secret = uuid.uuid4().hex + uuid.uuid4().hex

    class Content(BaseHTTPRequestHandler):
        def do_GET(self):
            artifact_id = int(self.path.rsplit('/', 1)[-1])
            payload = json.dumps({'data': {'id': artifact_id, 'name': f'Fixture {artifact_id}',
                                          'status': 'ACTIVE', 'siteId': 1}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(payload)
        def log_message(self, *args):
            pass

    content = ThreadingHTTPServer(('127.0.0.1', 0), Content)
    threading.Thread(target=content.serve_forever, daemon=True).start()
    content_port = content.server_port

    def request(path, body=None, token=None, method=None, origin=None):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        data = json.dumps(body).encode() if body is not None else None
        url = f'http://127.0.0.1:{origin or gateway_port}' + path
        with opener.open(Request(url, data=data, headers=headers, method=method), timeout=15) as r:
            raw = r.read().decode('utf-8')
            return json.loads(raw) if r.headers.get('Content-Type', '').startswith('application/json') else raw

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        evidence['checks'].append({'name': name, 'status': 'PASS'})

    def jwt(uid):
        def enc(value):
            return base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).rstrip(b'=')
        data = enc({'alg': 'HS256', 'typ': 'JWT'}) + b'.' + enc({
            'iss': 'smart-heritage', 'sub': 'isolated-test', 'uid': uid,
            'role': 'VISITOR', 'typ': 'access', 'iat': int(time.time()), 'exp': int(time.time()) + 900})
        sig = base64.urlsafe_b64encode(hmac.new(secret.encode(), data, hashlib.sha256).digest()).rstrip(b'=')
        return (data + b'.' + sig).decode()

    with tempfile.TemporaryDirectory(prefix='phu-w7-smoke-') as tmp:
        tmp = Path(tmp)
        try:
            subprocess.run([str(args.mysql_home/'bin/mysqld'), '--no-defaults', '--initialize-insecure',
                            '--basedir='+str(args.mysql_home), '--datadir='+str(tmp/'data')],
                           check=True, capture_output=True)
            def start(command, name, env=None):
                log = (tmp/(name+'.log')).open('w'); logs.append(log)
                process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=env)
                processes.append(process)
                return process
            start([str(args.mysql_home/'bin/mysqld'), '--no-defaults', '--basedir='+str(args.mysql_home),
                   '--datadir='+str(tmp/'data'), '--bind-address=127.0.0.1', f'--port={db_port}',
                   '--socket=', '--mysqlx=0', '--pid-file='+str(tmp/'mysql.pid')], 'mysql')
            sql_command = [str(args.mysql_home/'bin/mysql'), '--protocol=TCP', '-h127.0.0.1',
                           f'-P{db_port}', '-uroot', '--batch', '--skip-column-names']
            for _ in range(40):
                result = subprocess.run(sql_command + ['-e', 'SELECT VERSION();'], capture_output=True)
                if result.returncode == 0:
                    evidence['mysql_version'] = result.stdout.decode().strip()
                    break
                time.sleep(.5)
            else:
                raise RuntimeError('MySQL did not start')
            env = os.environ.copy()
            env.update({'SERVER_PORT': str(service_port), 'DB_URL': f'jdbc:mysql://127.0.0.1:{db_port}/personalization_db?createDatabaseIfNotExist=true&useSSL=false&allowPublicKeyRetrieval=true',
                        'DB_USERNAME': 'root', 'DB_PASSWORD': '', 'REDIS_PORT': str(redis_port),
                        'CONTENT_SERVICE_URL': f'http://127.0.0.1:{content_port}',
                        'SPRING_RABBITMQ_PORT': str(rabbit_port)})
            start([args.java, '-Xmx384m', '-jar', str(repo/'services/personalization-service/target/personalization-service-0.0.1-SNAPSHOT.jar'),
                   '--spring.rabbitmq.listener.simple.auto-startup=false', '--spring.rabbitmq.connection-timeout=100ms'], 'personalization', env)
            gateway_env = os.environ.copy()
            gateway_env.update({'SERVER_PORT': str(gateway_port), 'JWT_SECRET': secret,
                                'PERSONALIZATION_SERVICE_URL': f'http://127.0.0.1:{service_port}'})
            # Gateway's server.port is fixed in YAML, so override explicitly.
            start([args.java, '-Xmx256m', '-jar', str(repo/'services/api-gateway/target/api-gateway-0.0.1-SNAPSHOT.jar'),
                   f'--server.port={gateway_port}'], 'gateway', gateway_env)
            for _ in range(120):
                try:
                    spec = request('/v3/api-docs/personalization')
                    if '/api/me/visits/batch' in spec.get('paths', {}): break
                except (URLError, ValueError, TimeoutError): pass
                time.sleep(.5)
            else:
                raise RuntimeError('Gateway/service did not become ready')
            check('OpenAPI available through Gateway', '/api/me/favorites' in spec['paths'])
            check('Swagger UI served through Gateway', 'swagger' in request('/swagger-ui.html').lower())
            check('Prometheus endpoint available', '# HELP' in request('/actuator/prometheus', origin=service_port))
            token = jwt(10006)
            try:
                request('/api/me/favorites')
                raise AssertionError('Missing JWT accepted')
            except HTTPError as error:
                check('Gateway requires JWT', error.code == 401)
            for artifact in (1, 2, 1):
                request(f'/api/me/favorites/{artifact}', {}, token)
            favorites = request('/api/me/favorites', token=token)['data']['content']
            check('Redis unavailable: two favorites, repeated add does not duplicate', len(favorites) == 2)
            events = [{'artifactId': i, 'clientEventId': str(uuid.uuid4()), 'source': 'BEACON',
                       'detectedAt': datetime.now(timezone.utc).isoformat(), 'durationSeconds': 10}
                      for i in (1, 2, 3)]
            request('/api/me/visits/batch', {'events': events}, token)  # Deliberately discard first response.
            replay = request('/api/me/visits/batch', {'events': events}, token)['data']
            check('Replay after discarded response creates no additional visits', replay['created'] == 0 and replay['duplicates'] == 3)
            history = request('/api/me/visits', token=token)['data']['content']
            check('Exactly three original event IDs retained', {r['clientEventId'] for r in history} == {e['clientEventId'] for e in events} and len(history) == 3)
            check('JWT account isolation', not request('/api/me/visits', token=jwt(10007))['data']['content'])
            content.shutdown(); content.server_close()
            favorites = request('/api/me/favorites', token=token)['data']['content']
            history = request('/api/me/visits', token=token)['data']['content']
            check('Content and Redis unavailable: existing favorites still readable', len(favorites) == 2 and all(r['artifactName'].startswith('Hiện vật #') for r in favorites))
            check('Content and Redis unavailable: visits still readable', len(history) == 3)
            try:
                request('/api/me/favorites/3', {}, token)
                raise AssertionError('Unverified artifact accepted')
            except HTTPError as error:
                check('Content unavailable: new write remains retryable, not falsely accepted', error.code == 503)
            request('/api/me/favorites/1', token=token, method='DELETE')
            check('Removing an existing favorite does not need Content or Redis', request('/api/me/favorites/1/exists', token=token)['data'] is False)
            migration = (repo/'Infra/personalization_w7_indexes.sql').read_text()
            subprocess.run(sql_command, input=b'ALTER TABLE personalization_db.visits DROP INDEX idx_visits_user_detected;', capture_output=True, check=True)
            for _ in range(2):
                subprocess.run(sql_command, input=migration.encode(), capture_output=True, check=True)
            index_rows = subprocess.run(sql_command, input=b"SELECT COLUMN_NAME FROM information_schema.statistics WHERE TABLE_SCHEMA='personalization_db' AND TABLE_NAME='visits' AND INDEX_NAME='idx_visits_user_detected' ORDER BY SEQ_IN_INDEX;", capture_output=True, check=True).stdout.decode()
            check('Index migration creates both columns and runs twice without error', 'user_id' in index_rows and 'detected_at' in index_rows)
            evidence['status'] = 'PASS'
        except Exception as error:
            evidence['status'] = 'FAIL'
            evidence['error'] = str(error)
            # Preserve service diagnostics on failure, without environment variables or tokens.
            for log in logs: log.flush()
            args.output.parent.mkdir(parents=True, exist_ok=True)
            for log_file in tmp.glob('*.log'):
                (args.output.parent/('isolated-'+log_file.name)).write_bytes(log_file.read_bytes())
            raise
        finally:
            content.shutdown(); content.server_close()
            for process in reversed(processes):
                process.terminate()
            for process in processes:
                try: process.wait(timeout=20)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            for log in logs: log.close()
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(evidence, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
