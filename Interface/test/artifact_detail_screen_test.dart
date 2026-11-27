import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartheritage/features/auth/auth_service.dart';
import 'package:smartheritage/screens/artifact_detail_screen.dart';
import 'package:smartheritage/screens/recent_artifacts_screen.dart';
import 'package:smartheritage/features/feedback/feedback_screen.dart';

import 'core/artifact_cache_test.dart' show artifactJson;

void main() {
  testWidgets(
    'refresh reports deleted artifact instead of showing cached article',
    (tester) async {
      var deleted = false;
      AuthService.rawClient = MockClient(
        (_) async => deleted
            ? http.Response('{}', 404)
            : http.Response(jsonEncode({'data': artifactJson(1, 'vi')}), 200),
      );
      await tester.pumpWidget(
        const MaterialApp(home: ArtifactDetailScreen(artifactId: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Title 1 vi'), findsWidgets);
      deleted = true;
      await tester.tap(find.byTooltip('Tải lại hiện vật'));
      await tester.pumpAndSettle();
      expect(
        find.text('Hiện vật đã bị xóa hoặc không còn được cung cấp.'),
        findsOneWidget,
      );
      expect(find.text('Title 1 vi'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [240.0, 320.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'long content and missing media at width $width scale $scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          AuthService.rawClient = MockClient((_) async {
            final data = artifactJson(1, 'vi');
            data['name'] = List.filled(12, 'Hiện vật có tên rất dài').join(' ');
            data['material'] = List.filled(20, 'Chất liệu lịch sử').join(' ');
            data['dimensions'] = List.filled(
              20,
              'Kích thước hiện vật',
            ).join(' ');
            data['locationName'] = List.filled(20, 'Di tích văn hóa').join(' ');
            final content = data['content'] as Map<String, dynamic>;
            content['title'] = data['name'];
            content['description'] = List.filled(
              100,
              'Nội dung mô tả dài.',
            ).join(' ');
            content['transcript'] = List.filled(30, 'Phụ đề dài.').join(' ');
            return http.Response(
              jsonEncode({'data': data}),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          });
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const ArtifactDetailScreen(artifactId: 1),
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byType(NestedScrollView),
            const Offset(0, -500),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          expect(tester.takeException(), isNull);
          for (final label in ['Hình ảnh', 'Âm thanh', 'Thông tin']) {
            await tester.ensureVisible(find.text(label));
            await tester.tap(find.text(label));
            await tester.pumpAndSettle(
              const Duration(milliseconds: 100),
              EnginePhase.sendSemanticsUpdate,
              const Duration(seconds: 5),
            );
            expect(tester.takeException(), isNull);
          }
          expect(find.text('Xem video'), findsNothing);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets(
    'favorites use real adapter and feedback receives the artifact ID',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      AuthService.currentUser.value = const AuthUser(
        userId: 1,
        username: 'visitor',
        email: '',
        fullName: '',
        role: 'VISITOR',
      );
      AuthService.rawClient = MockClient(
        (_) async =>
            http.Response(jsonEncode({'data': artifactJson(7, 'vi')}), 200),
      );
      final writes = <String>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            const MaterialApp(home: ArtifactDetailScreen(artifactId: 7)),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Yêu thích'));
          await tester.pumpAndSettle();
          expect(find.byIcon(Icons.favorite), findsOneWidget);
          await tester.tap(find.byTooltip('Yêu thích'));
          await tester.pumpAndSettle();
          expect(find.byIcon(Icons.favorite_border), findsOneWidget);
          expect(writes, [
            'POST /api/me/favorites/7',
            'DELETE /api/me/favorites/7',
          ]);
          await tester.tap(find.text('Đánh giá'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<FeedbackScreen>(find.byType(FeedbackScreen))
                .artifactId,
            7,
          );
        },
        () => MockClient((request) async {
          if (request.method != 'GET') {
            writes.add('${request.method} ${request.url.path}');
          }
          final Object data = request.url.path.endsWith('/exists')
              ? false
              : request.url.path.endsWith('/rating-summary')
              ? {
                  'artifactId': 7,
                  'averageRating': 0,
                  'totalRatings': 0,
                  'distribution': {},
                }
              : <Object>[];
          return http.Response(
            jsonEncode({'success': true, 'data': data}),
            200,
          );
        }),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid audio URL displays an error and disposing does not crash',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      AuthService.rawClient = MockClient((_) async {
        final data = artifactJson(1, 'vi');
        (data['content'] as Map<String, dynamic>)['audioUrl'] = 'invalid-url';
        return http.Response(jsonEncode({'data': data}), 200);
      });
      await tester.pumpWidget(
        const MaterialApp(home: ArtifactDetailScreen(artifactId: 1)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Âm thanh'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Không tải được file âm thanh.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  late http.Client original;
  setUp(() {
    original = AuthService.rawClient;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    AuthService.rawClient.close();
    AuthService.rawClient = original;
    AuthService.currentUser.value = null;
  });

  testWidgets('uses preferredLanguage and reloads content for VI/EN', (
    tester,
  ) async {
    final requests = <String>[];
    AuthService.currentUser.value = const AuthUser(
      userId: 1,
      username: 'user',
      email: '',
      fullName: '',
      role: 'VISITOR',
      preferredLanguage: 'en',
    );
    AuthService.rawClient = MockClient((request) async {
      final lang = request.url.queryParameters['lang']!;
      requests.add(lang);
      return http.Response(jsonEncode({'data': artifactJson(1, lang)}), 200);
    });
    await tester.pumpWidget(
      const MaterialApp(home: ArtifactDetailScreen(artifactId: 1)),
    );
    await tester.pumpAndSettle();
    expect(requests, ['en']);
    await tester.tap(find.text('🇻🇳 Tiếng Việt'));
    await tester.pumpAndSettle();
    expect(requests, ['en', 'vi']);
    expect(find.text('Title 1 vi'), findsWidgets);
  });

  testWidgets(
    'shows fallback label and invalid video URL reports error without crashing on exit',
    (tester) async {
      AuthService.rawClient = MockClient((_) async {
        final data = artifactJson(1, 'vi');
        data['fallback'] = true;
        (data['content'] as Map<String, dynamic>)['videoUrl'] = 'invalid-url';
        return http.Response(jsonEncode({'data': data}), 200);
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: ArtifactDetailScreen(artifactId: 1, initialLang: 'en'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Chưa có bản dịch, đang hiển thị tiếng Việt'),
        findsOneWidget,
      );
      await tester.tap(find.text('Xem video'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Không tải được video.'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recent artifacts can be reopened offline after restarting screen',
    (tester) async {
      AuthService.rawClient = MockClient(
        (_) async =>
            http.Response(jsonEncode({'data': artifactJson(1, 'vi')}), 200),
      );
      await tester.pumpWidget(
        const MaterialApp(home: ArtifactDetailScreen(artifactId: 1)),
      );
      await tester.pumpAndSettle();
      AuthService.rawClient = MockClient(
        (_) async => throw const SocketException('offline'),
      );
      await tester.pumpWidget(const MaterialApp(home: RecentArtifactsScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Artifact 1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Đang xem nội dung đã tải'), findsOneWidget);
      expect(find.text('Title 1 vi'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('loads extra active languages and falls back when a translation is missing',
      (tester) async {
    final requestedLanguages = <String>[];
    AuthService.rawClient = MockClient((request) async {
      if (request.url.path == '/api/languages') {
        return http.Response(
          jsonEncode({
            'data': [
              {'code': 'vi', 'name': 'Tiếng Việt', 'active': true},
              {'code': 'en', 'name': 'English', 'active': true},
              {'code': 'fr', 'name': 'Français', 'active': true},
              {'code': 'de', 'name': 'Deutsch', 'active': false},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path == '/api/artifacts/1') {
        final lang = request.url.queryParameters['lang'] ?? 'vi';
        requestedLanguages.add(lang);
        final data = artifactJson(1, 'vi');
        data['requestedLanguage'] = lang;
        data['fallback'] = lang == 'fr';
        return http.Response(
          jsonEncode({'data': data}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 404);
    });
    await tester.pumpWidget(
      const MaterialApp(home: ArtifactDetailScreen(artifactId: 1)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Français (fr)'), findsOneWidget);
    expect(find.text('Deutsch (de)'), findsNothing);
    await tester.tap(find.text('Français (fr)'));
    await tester.pumpAndSettle();
    expect(requestedLanguages, contains('fr'));
    expect(
      find.text('Chưa có bản dịch, đang hiển thị tiếng Việt'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

}
