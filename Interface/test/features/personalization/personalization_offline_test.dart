import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartheritage/features/auth/auth_service.dart';
import 'package:smartheritage/features/personalization/personalization_service.dart';

const user = AuthUser(
  userId: 6,
  username: 'test',
  email: 'test@example.com',
  fullName: 'Test',
  role: 'VISITOR',
);
const other = AuthUser(
  userId: 7,
  username: 'other',
  email: 'other@example.com',
  fullName: 'Other',
  role: 'VISITOR',
);

String eventId(int i) =>
    '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';

http.Response ok(dynamic data) =>
    http.Response(jsonEncode({'success': true, 'data': data}), 200);
Future<List<dynamic>> stored(String name, {int userId = 6}) async {
  final prefs = await SharedPreferences.getInstance();
  return jsonDecode(prefs.getString('sh.personalization.$userId.$name') ?? '[]')
      as List;
}

Future<T> withClient<T>(MockClient client, Future<T> Function() action) =>
    http.runWithClient(action, () => client);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AuthService.currentUser.value = user;
  });
  tearDown(() => AuthService.currentUser.value = null);

  test(
    'concurrent offline additions retain every favorite and queued operation',
    () async {
      final client = MockClient(
        (_) async => throw http.ClientException('offline'),
      );
      await withClient(client, () async {
        final results = await Future.wait(
          List.generate(
            10,
            (i) => PersonalizationService.addFavorite(
              artifactId: i + 1,
              artifactName: 'Artifact $i',
            ),
          ),
        );
        expect(results.every((r) => r.success && r.queuedOffline), isTrue);
      });
      expect(await stored('favorites'), hasLength(10));
      expect(await stored('outbox.favorites'), hasLength(10));
    },
  );

  test(
    'pending favorite ADD and REMOVE override stale server exists result',
    () async {
      var online = false;
      final client = MockClient((request) async {
        if (!online) throw http.ClientException('offline');
        return ok(request.url.path.contains('/2/'));
      });
      await withClient(client, () async {
        await PersonalizationService.addFavorite(
          artifactId: 1,
          artifactName: 'One',
        );
        await PersonalizationService.removeFavorite(2);
        online = true;
        expect(await PersonalizationService.isFavorite(1), isTrue);
        expect(await PersonalizationService.isFavorite(2), isFalse);
      });
    },
  );

  test(
    'latest favorite intent survives reconnect and overlapping retry calls',
    () async {
      var online = false;
      final sent = <String>[];
      final client = MockClient((request) async {
        if (!online) throw http.ClientException('offline');
        sent.add('${request.method} ${request.url.path}');
        return ok(null);
      });
      await withClient(client, () async {
        await PersonalizationService.addFavorite(
          artifactId: 1,
          artifactName: 'One',
        );
        await PersonalizationService.removeFavorite(1);
        expect(await stored('outbox.favorites'), hasLength(1));
        online = true;
        await Future.wait([
          PersonalizationService.syncPending(),
          PersonalizationService.syncPending(),
        ]);
      });
      expect(sent, ['DELETE /api/me/favorites/1']);
      expect(await stored('outbox.favorites'), isEmpty);
      expect(await stored('favorites'), isEmpty);
    },
  );

  test(
    '503 queues favorite intent; 400 reports failure and restores cache',
    () async {
      var status = 503;
      final client = MockClient(
        (_) async => http.Response('{"message":"unavailable"}', status),
      );
      await withClient(client, () async {
        final retry = await PersonalizationService.addFavorite(
          artifactId: 1,
          artifactName: 'One',
        );
        expect(retry.queuedOffline, isTrue);
        status = 400;
        final rejected = await PersonalizationService.addFavorite(
          artifactId: 2,
          artifactName: 'Two',
        );
        expect(rejected.success, isFalse);
      });
      expect((await stored('favorites')).map((r) => r['artifactId']), [1]);
      expect(await stored('outbox.favorites'), hasLength(1));
    },
  );

  test('concurrent offline visits persist, deduplicate and retain IDs when retried', () async {
    var online = false;
    final sent = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (!online) throw http.ClientException('offline');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      sent.addAll(
        (body['events'] as List).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
      return ok({'inserted': sent.length});
    });
    await withClient(client, () async {
      await Future.wait(
        List.generate(
          8,
          (i) => PersonalizationService.recordVisit(
            artifactId: 1,
            artifactName: 'One',
            clientEventId: eventId(i),
          ),
        ),
      );
      await PersonalizationService.recordVisit(
        artifactId: 1,
        artifactName: 'One',
        clientEventId: eventId(0),
      );
      final pending = await stored('outbox.visits');
      expect(pending, hasLength(8));
      expect(await stored('history'), hasLength(8));
      online = true;
      await PersonalizationService.syncPending();
      expect(sent, pending.map((event) => Map<String, dynamic>.from(event as Map)..remove('_local')).toList());
    });
    expect(await stored('outbox.visits'), isEmpty);
    expect(
      (await stored('history')).every((row) => row['syncPending'] == false),
      isTrue,
    );
  });

  test(
    'failed batch remains durable and can be retried without changing IDs',
    () async {
      SharedPreferences.setMockInitialValues({
        'sh.personalization.6.outbox.visits': jsonEncode(
          List.generate(
            205,
            (i) => {'clientEventId': eventId(i), 'artifactId': 1},
          ),
        ),
      });
      final sizes = <int>[];
      var failSecond = true;
      final client = MockClient((request) async {
        final events = jsonDecode(request.body)['events'] as List;
        sizes.add(events.length);
        if (sizes.length == 2 && failSecond) return http.Response('', 503);
        return ok(null);
      });
      await withClient(client, () async {
        await PersonalizationService.syncPending();
        expect(await stored('outbox.visits'), hasLength(105));
        failSecond = false;
        await PersonalizationService.syncPending();
      });
      expect(sizes, [100, 100, 100, 5]);
      expect(await stored('outbox.visits'), isEmpty);
    },
  );

  test(
    'account switch does not send the old account outbox with the new session',
    () async {
      SharedPreferences.setMockInitialValues({
        'sh.personalization.6.outbox.favorites': jsonEncode([
          {'artifactId': 1, 'action': 'ADD'},
          {'artifactId': 2, 'action': 'ADD'},
        ]),
      });
      var sent = 0;
      final client = MockClient((request) async {
        sent++;
        AuthService.currentUser.value = other;
        return ok(null);
      });
      await withClient(client, () async {
        await expectLater(
          PersonalizationService.syncPending(),
          throwsStateError,
        );
        await PersonalizationService.syncPending();
      });
      expect(sent, 1);
      expect((await stored('outbox.favorites')).single['artifactId'], 2);
      expect(await stored('outbox.favorites', userId: 7), isEmpty);
    },
  );

  test('offline cached lists are isolated by account', () async {
    SharedPreferences.setMockInitialValues({
      'sh.personalization.6.favorites': jsonEncode([
        {'artifactId': 1},
      ]),
      'sh.personalization.6.history': jsonEncode([
        {'clientEventId': 'old'},
      ]),
    });
    final client = MockClient(
      (_) async => throw http.ClientException('offline'),
    );
    await withClient(client, () async {
      expect(
        (await PersonalizationService.loadFavorites()).items,
        hasLength(1),
      );
      AuthService.currentUser.value = other;
      expect((await PersonalizationService.loadFavorites()).items, isEmpty);
      expect((await PersonalizationService.loadVisitHistory()).items, isEmpty);
    });
  });
  test('W7: three beacon visits and two favorites survive lost responses and reconnect', () async {
    var online = false;
    var loseFirstResponse = true;
    final serverVisits = <String, Map<String, dynamic>>{};
    final serverFavorites = <int>{};
    final client = MockClient((request) async {
      if (!online) throw http.ClientException('offline');
      if (request.url.path.endsWith('/visits/batch')) {
        final events = jsonDecode(request.body)['events'] as List;
        for (final event in events) {
          expect((event as Map).containsKey('_local'), isFalse);
          serverVisits.putIfAbsent(event['clientEventId'] as String,
              () => Map<String, dynamic>.from(event));
        }
        if (loseFirstResponse) {
          loseFirstResponse = false;
          throw http.ClientException('response lost after commit');
        }
      } else if (request.method == 'POST') {
        serverFavorites.add(int.parse(request.url.pathSegments.last));
      }
      return ok(null);
    });
    await withClient(client, () async {
      await Future.wait([
        for (var i = 1; i <= 3; i++)
          PersonalizationService.recordVisit(artifactId: i, artifactName: 'Artifact $i',
              source: 'BEACON', clientEventId: eventId(i)),
        for (var i = 1; i <= 2; i++)
          PersonalizationService.addFavorite(artifactId: i, artifactName: 'Artifact $i'),
      ]);
      expect(await stored('outbox.visits'), hasLength(3));
      expect(await stored('outbox.favorites'), hasLength(2));
      final original = await stored('outbox.visits');
      online = true;
      await PersonalizationService.syncPending();
      expect(await stored('outbox.visits'), original);
      expect(serverVisits, hasLength(3));
      await PersonalizationService.syncPending();
      await PersonalizationService.syncPending();
      expect(serverVisits.keys.toSet(), {eventId(1), eventId(2), eventId(3)});
      expect(serverFavorites, {1, 2});
      expect(await stored('outbox.visits'), isEmpty);
      expect(await stored('outbox.favorites'), isEmpty);
      expect(await stored('history'), hasLength(3));
      expect(await stored('favorites'), hasLength(2));
    });
  });

  test('persisted outbox restores history when display cache was not written', () async {
    final row = {'clientEventId': eventId(1), 'artifactId': 1,
      'artifactName': 'One', 'detectedAt': '2026-11-19T01:00:00Z', 'syncPending': true};
    SharedPreferences.setMockInitialValues({
      'sh.personalization.6.outbox.visits': jsonEncode([
        {'clientEventId': eventId(1), 'artifactId': 1, '_local': row}
      ]),
    });
    await withClient(MockClient((_) async => throw http.ClientException('offline')), () async {
      final result = await PersonalizationService.loadVisitHistory();
      expect(result.fromCache, isTrue);
      expect(result.items.single['clientEventId'], eventId(1));
      expect(result.items.single['artifactName'], 'One');
    });
  });

}
