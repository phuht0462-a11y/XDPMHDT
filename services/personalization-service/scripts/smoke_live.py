"""Week 7 smoke test against real services in a disposable local Compose stack.

Creates two uniquely named test accounts, two favorites and three visits.
--chaos additionally stops/restarts Redis and Content; use only a test stack.
Does not reset databases, delete volumes, or print passwords/access tokens.
"""
import argparse
import json
import os
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gateway', default='http://localhost:8080')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--chaos', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    compose = ['docker', 'compose', '-f', str(repo / 'Infra/docker-compose.yml'),
               '--profile', 'all']
    evidence = {'timestamp_utc': datetime.now(timezone.utc).isoformat(),
                'scope': 'Real Auth, Gateway, Content, Personalization, MySQL, Redis, RabbitMQ and Analytics',
                'checks': [], 'status': 'FAIL'}
    stopped = []

    def request(path, body=None, token=None, method=None):
        headers = {'Content-Type': 'application/json; charset=utf-8'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        data = None if body is None else json.dumps(body).encode('utf-8')
        with urlopen(Request(args.gateway.rstrip('/') + path, data=data,
                             headers=headers, method=method), timeout=20) as response:
            raw = response.read().decode('utf-8')
            return json.loads(raw) if 'application/json' in response.headers.get('Content-Type', '') else raw

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        evidence['checks'].append({'name': name, 'status': 'PASS'})
        print('PASS: ' + name, flush=True)

    def register():
        name = 'phu_w7_' + uuid.uuid4().hex[:12]
        password = 'Test@' + uuid.uuid4().hex
        request('/api/auth/register', {'username': name, 'email': name + '@example.com',
                                     'fullName': 'Week 7 smoke test', 'password': password})
        login = request('/api/auth/login', {'username': name, 'password': password})
        return login['accessToken'], login['userId']

    def views(admin):
        return int(request('/api/statistics/realtime', token=admin)['data']['views'])

    def stop(service):
        # Mark first so cleanup also runs if the stop command partially succeeds.
        stopped.append(service)
        subprocess.run(compose + ['stop', service], check=True)

    try:
        for _ in range(120):
            try:
                spec = request('/v3/api-docs/personalization')
                if '/api/me/visits/batch' in spec.get('paths', {}):
                    break
            except (URLError, TimeoutError, ValueError):
                pass
            time.sleep(1)
        else:
            raise RuntimeError('Gateway/personalization not ready')
        check('OpenAPI and Swagger through Gateway',
              '/api/me/favorites' in spec['paths'] and 'swagger' in request('/swagger-ui.html').lower())
        token, user_id = register()
        other_token, _ = register()
        evidence['user_id'] = user_id
        check('Register and login through real Auth', bool(token) and bool(other_token))
        admin = request('/api/auth/login', {
            'username': os.getenv('SH_SMOKE_ADMIN_USER', 'admin'),
            'password': os.getenv('SH_SMOKE_ADMIN_PASSWORD', 'Test@1234')})['accessToken']
        for _ in range(30):
            queues = subprocess.run(['docker', 'exec', 'smart_heritage_rabbitmq',
                                     'rabbitmqctl', 'list_queues', 'name', 'consumers', '--quiet'],
                                    capture_output=True, text=True, check=True).stdout
            if any(line.split() == ['analytics.visit-recorded', '1'] for line in queues.splitlines()):
                break
            time.sleep(1)
        else:
            raise RuntimeError('Analytics RabbitMQ consumer not ready')
        check('Analytics consumer subscribed', True)
        artifacts = request('/api/artifacts')['data']
        if isinstance(artifacts, dict):
            artifacts = artifacts['content']
        ids = [row['id'] for row in artifacts if row.get('status') == 'ACTIVE']
        check('Real Content provides at least three ACTIVE artifacts', len(ids) >= 3)
        for artifact in ids[:2] + ids[:1]:
            request(f'/api/me/favorites/{artifact}', {}, token)
        favorites = request('/api/me/favorites', token=token)['data']['content']
        check('Two favorites, repeated add stays idempotent',
              len(favorites) == 2 and {row['artifactId'] for row in favorites} == set(ids[:2]))
        before = views(admin)
        events = [{'artifactId': artifact, 'clientEventId': str(uuid.uuid4()),
                   'detectedAt': datetime.now(timezone.utc).isoformat(),
                   'durationSeconds': 10, 'source': 'BEACON'} for artifact in ids[:3]]
        evidence['event_ids'] = [row['clientEventId'] for row in events]
        request('/api/me/visits/batch', {'events': events}, token)  # Discard first response.
        replay = request('/api/me/visits/batch', {'events': events}, token)['data']
        check('Lost-response replay: zero new, three duplicates',
              replay['created'] == 0 and replay['duplicates'] == 3)
        history = request('/api/me/visits', token=token)['data']['content']
        check('History retains exactly the three original UUIDs',
              len(history) == 3 and {row['clientEventId'] for row in history} == set(evidence['event_ids']))
        check('Second account has no first-account data',
              not request('/api/me/visits', token=other_token)['data']['content'] and
              not request('/api/me/favorites', token=other_token)['data']['content'])
        for _ in range(30):
            delta = views(admin) - before
            if delta >= 3:
                break
            time.sleep(1)
        check('RabbitMQ delivers exactly three visits to Analytics', delta == 3)
        request('/api/me/visits/batch', {'events': events}, token)
        time.sleep(3)
        check('Another replay does not increment Analytics', views(admin) - before == 3)
        request(f'/api/me/favorites/{ids[0]}', token=token, method='DELETE')
        check('Favorite deletion confirmed by API',
              request(f'/api/me/favorites/{ids[0]}/exists', token=token)['data'] is False)
        if args.chaos:
            stop('redis-cache')
            request(f'/api/me/favorites/{ids[0]}', {}, token)
            check('Redis stopped: real Content permits write and read',
                  len(request('/api/me/favorites', token=token)['data']['content']) == 2)
            stop('content-service')
            favorites = request('/api/me/favorites', token=token)['data']['content']
            history = request('/api/me/visits', token=token)['data']['content']
            check('Redis and Content stopped: personal records remain readable',
                  len(favorites) == 2 and len(history) == 3 and
                  all(row['artifactName'].startswith('Hiện vật #') for row in favorites + history))
            try:
                request(f'/api/me/favorites/{ids[2]}', {}, token)
                raise AssertionError('Unverified new favorite was accepted')
            except HTTPError as error:
                check('Unverifiable new favorite returns retryable 503', error.code == 503)
        evidence['status'] = 'PASS'
    except Exception as error:
        evidence['error'] = str(error)
        raise
    finally:
        for service in reversed(stopped):
            restored = subprocess.run(compose + ['start', service], check=False)
            if restored.returncode:
                evidence['status'] = 'FAIL'
                evidence.setdefault('cleanup_errors', []).append(service)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(evidence, ensure_ascii=False, indent=2))
    if evidence['status'] != 'PASS':
        raise RuntimeError('Cleanup failed; see evidence JSON')


if __name__ == '__main__':
    main()
