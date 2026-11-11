import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../auth/auth_service.dart';

class PersonalizationListResult {
  final List<Map<String, dynamic>> items;
  final bool fromCache;
  final String? warning;

  const PersonalizationListResult({
    required this.items,
    required this.fromCache,
    this.warning,
  });
}

class PersonalizationActionResult {
  final bool success;
  final bool queuedOffline;
  final String message;

  const PersonalizationActionResult({
    required this.success,
    required this.queuedOffline,
    required this.message,
  });
}

/// API adapter + per-account local cache/outbox for Favorites and Visit History.
///
/// Xác thực: KHÔNG tự gắn header X-User-Id. Access token (Bearer) được gắn tự động
/// cho mọi request qua http.runWithClient + AuthHttpClient trong main.dart;
/// Backend lấy userId từ token. Từ W4 Gateway xóa mọi header X-User-* do client gửi.
class PersonalizationService {
  PersonalizationService._();
  static final Uuid _uuid = Uuid();
  static const Duration _timeout = Duration(seconds: 8);
  static const String _favoritesPath = '/api/me/favorites';
  static const String _visitsPath = '/api/me/visits';

  static int? get _userId => AuthService.currentUser.value?.userId;
  static String get _baseUrl => AuthService.baseUrl;

  static String _cacheKey(int userId, String name) => 'sh.personalization.$userId.$name';

  static Map<String, String> _headers() => const {
        'Accept': 'application/json',
        'Content-Type': 'application/json; charset=UTF-8',
      };

  static Future<http.Response> _get(String path) => http
      .get(Uri.parse('$_baseUrl$path'), headers: _headers())
      .timeout(_timeout);

  static Future<http.Response> _post(String path, Map<String, dynamic> body) => http
      .post(Uri.parse('$_baseUrl$path'), headers: _headers(), body: jsonEncode(body))
      .timeout(_timeout);

  static Future<http.Response> _delete(String path) => http
      .delete(Uri.parse('$_baseUrl$path'), headers: _headers())
      .timeout(_timeout);

  static bool _ok(http.Response response) => response.statusCode >= 200 && response.statusCode < 300;

  static Map<String, dynamic> _decodeMap(http.Response response) {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{};
  }

  static String _message(http.Response response) {
    try {
      final body = _decodeMap(response);
      return body['message']?.toString() ?? 'Máy chủ trả mã ${response.statusCode}.';
    } catch (_) {
      return 'Máy chủ trả mã ${response.statusCode}.';
    }
  }

  static dynamic _unwrap(http.Response response) {
    final body = _decodeMap(response);
    // Standard backend shape: {success, message, data}.
    return body.containsKey('data') ? body['data'] : body;
  }

  static List<Map<String, dynamic>> _rowsFromResponse(http.Response response) {
    final payload = _unwrap(response);
    dynamic rows = payload;
    if (payload is Map<String, dynamic>) {
      rows = payload['content'] ?? payload['items'] ?? payload['results'] ?? const [];
    }
    if (rows is! List) return <Map<String, dynamic>>[];
    return rows.whereType<Map>().map((row) => Map<String, dynamic>.from(row)).toList();
  }

  static Future<List<Map<String, dynamic>>> _readCache(int userId, String name) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey(userId, name));
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {
      // Ignore a corrupted local cache and rebuild it from the next server response.
    }
    return <Map<String, dynamic>>[];
  }

  static Future<void> _writeCache(int userId, String name, List<Map<String, dynamic>> rows) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey(userId, name), jsonEncode(rows));
  }

  static Future<List<Map<String, dynamic>>> _readOutbox(int userId, String name) =>
      _readCache(userId, 'outbox.$name');

  static Future<void> _writeOutbox(int userId, String name, List<Map<String, dynamic>> rows) =>
      _writeCache(userId, 'outbox.$name', rows);

  static Future<PersonalizationListResult> loadFavorites() async {
    final userId = _userId;
    if (userId == null) {
      return const PersonalizationListResult(items: [], fromCache: false, warning: 'Đăng nhập để xem danh sách yêu thích.');
    }

    await _syncFavoriteOutbox(userId);
    try {
      final response = await _get('$_favoritesPath?page=0&size=100');
      if (!_ok(response)) throw Exception(_message(response));
      final remote = _rowsFromResponse(response);
      await _writeCache(userId, 'favorites', remote);
      final merged = await _applyPendingFavoriteOps(userId, remote);
      await _writeCache(userId, 'favorites', merged);
      final pending = await _readOutbox(userId, 'favorites');
      return PersonalizationListResult(
        items: merged,
        fromCache: false,
        warning: pending.isNotEmpty
            ? 'Có thay đổi Yêu thích đang chờ đồng bộ.'
            : null,
      );
    } catch (_) {
      return PersonalizationListResult(
        items: await _readCache(userId, 'favorites'),
        fromCache: true,
        warning: (await _readOutbox(userId, 'favorites')).isNotEmpty
            ? 'Đang ngoại tuyến – sẽ đồng bộ sau. Hiển thị Yêu thích đã lưu.'
            : 'Không kết nối được máy chủ. Đang hiển thị Yêu thích đã lưu.',
      );
    }
  }

  static Future<List<Map<String, dynamic>>> _applyPendingFavoriteOps(
      int userId, List<Map<String, dynamic>> remote) async {
    final rows = List<Map<String, dynamic>>.from(remote);
    final pending = await _readOutbox(userId, 'favorites');
    for (final operation in pending) {
      final artifactId = (operation['artifactId'] as num?)?.toInt();
      if (artifactId == null) continue;
      final action = operation['action']?.toString();
      rows.removeWhere((row) => _artifactId(row) == artifactId);
      if (action == 'ADD') {
        final queuedItem = operation['item'];
        Map<String, dynamic>? item = queuedItem is Map
            ? Map<String, dynamic>.from(queuedItem)
            : null;
        if (item == null) {
          final cached = await _readCache(userId, 'favorites');
          for (final candidate in cached) {
            if (_artifactId(candidate) == artifactId) {
              item = candidate;
              break;
            }
          }
        }
        if (item != null) rows.insert(0, item);
      }
    }
    return rows;
  }

  static int? _artifactId(Map<String, dynamic> row) {
    final value = row['artifactId'] ?? row['artifact_id'] ?? row['id'];
    return value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
  }

  /// Hiện vật đã nằm trong Yêu thích chưa (GET /api/me/favorites/{id}/exists).
  /// Không kết nối được máy chủ thì dựa vào cache trên thiết bị.
  static Future<bool> isFavorite(int artifactId) async {
    final userId = _userId;
    if (userId == null) return false;
    try {
      final response = await _get('$_favoritesPath/$artifactId/exists');
      if (_ok(response)) return _unwrap(response) == true;
    } catch (_) {
      // Mất mạng: dùng cache bên dưới
    }
    final cached = await _readCache(userId, 'favorites');
    return cached.any((row) => _artifactId(row) == artifactId);
  }

  static Future<PersonalizationActionResult> addFavorite({
    required int artifactId,
    required String artifactName,
    String siteName = 'Smart Heritage',
    String thumbnailUrl = '',
  }) async {
    final userId = _userId;
    if (userId == null) {
      return const PersonalizationActionResult(success: false, queuedOffline: false, message: 'Bạn cần đăng nhập trước khi lưu yêu thích.');
    }

    final old = await _readCache(userId, 'favorites');
    final item = <String, dynamic>{
      'artifactId': artifactId,
      'artifactName': artifactName,
      'siteName': siteName,
      'thumbnailUrl': thumbnailUrl,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
    };
    final updated = List<Map<String, dynamic>>.from(old)
      ..removeWhere((row) => _artifactId(row) == artifactId)
      ..insert(0, item);
    await _writeCache(userId, 'favorites', updated);

    try {
      final response = await _post('$_favoritesPath/$artifactId', const {});
      if (_ok(response)) {
        await _removeFavoriteOutboxFor(userId, artifactId);
        return const PersonalizationActionResult(success: true, queuedOffline: false, message: 'Đã lưu hiện vật vào Yêu thích.');
      }
      await _writeCache(userId, 'favorites', old);
      return PersonalizationActionResult(success: false, queuedOffline: false, message: _message(response));
    } on Exception {
      await _queueFavorite(userId, artifactId, 'ADD', item);
      return const PersonalizationActionResult(success: true, queuedOffline: true, message: 'Đã lưu trên thiết bị; sẽ đồng bộ khi có mạng.');
    }
  }

  static Future<PersonalizationActionResult> removeFavorite(int artifactId) async {
    final userId = _userId;
    if (userId == null) {
      return const PersonalizationActionResult(success: false, queuedOffline: false, message: 'Bạn cần đăng nhập trước.');
    }
    final old = await _readCache(userId, 'favorites');
    final updated = List<Map<String, dynamic>>.from(old)
      ..removeWhere((row) => _artifactId(row) == artifactId);
    await _writeCache(userId, 'favorites', updated);

    try {
      final response = await _delete('$_favoritesPath/$artifactId');
      if (_ok(response)) {
        await _removeFavoriteOutboxFor(userId, artifactId);
        return const PersonalizationActionResult(success: true, queuedOffline: false, message: 'Đã bỏ yêu thích.');
      }
      await _writeCache(userId, 'favorites', old);
      return PersonalizationActionResult(success: false, queuedOffline: false, message: _message(response));
    } on Exception {
      await _queueFavorite(userId, artifactId, 'REMOVE', null);
      return const PersonalizationActionResult(success: true, queuedOffline: true, message: 'Đã cập nhật trên thiết bị; sẽ đồng bộ khi có mạng.');
    }
  }

  static Future<void> _queueFavorite(int userId, int artifactId, String action, Map<String, dynamic>? localItem) async {
    final outbox = await _readOutbox(userId, 'favorites');
    outbox.removeWhere((op) => (op['artifactId'] as num?)?.toInt() == artifactId);
    outbox.add({
      'artifactId': artifactId,
      'action': action,
      if (localItem != null) 'item': localItem,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeOutbox(userId, 'favorites', outbox);
    if (localItem != null) {
      final cache = await _readCache(userId, 'favorites');
      if (!cache.any((row) => _artifactId(row) == artifactId)) {
        cache.insert(0, localItem);
        await _writeCache(userId, 'favorites', cache);
      }
    }
  }

  static Future<void> _removeFavoriteOutboxFor(int userId, int artifactId) async {
    final outbox = await _readOutbox(userId, 'favorites');
    outbox.removeWhere((op) => (op['artifactId'] as num?)?.toInt() == artifactId);
    await _writeOutbox(userId, 'favorites', outbox);
  }

  static Future<void> _syncFavoriteOutbox(int userId) async {
    final outbox = await _readOutbox(userId, 'favorites');
    while (outbox.isNotEmpty) {
      final op = outbox.first;
      final artifactId = (op['artifactId'] as num?)?.toInt();
      if (artifactId == null) {
        outbox.removeAt(0);
        await _writeOutbox(userId, 'favorites', outbox);
        continue;
      }
      try {
        final response = op['action'] == 'REMOVE'
            ? await _delete('$_favoritesPath/$artifactId')
            : await _post('$_favoritesPath/$artifactId', const {});
        if (!_ok(response)) break;
        outbox.removeAt(0);
        await _writeOutbox(userId, 'favorites', outbox);
      } catch (_) {
        break;
      }
    }
  }

  static Future<void> recordVisit({
    required int artifactId,
    required String artifactName,
    String siteName = 'Smart Heritage',
    String thumbnailUrl = '',
    String source = 'MANUAL',
    int? durationSeconds, // null = không đo được thời gian dừng (không gửi 0)
    String? clientEventId, // UUID sinh trên máy (luồng beacon); null → tự sinh
  }) async {
    final userId = _userId;
    if (userId == null) return; // history belongs to a signed-in visitor

    final eventId = clientEventId ?? _uuid.v4();
    final detectedAt = DateTime.now().toUtc().toIso8601String();
    final localRow = <String, dynamic>{
      'id': 'local:$eventId',
      'clientEventId': eventId,
      'artifactId': artifactId,
      'artifactName': artifactName,
      'siteName': siteName,
      'thumbnailUrl': thumbnailUrl,
      'detectedAt': detectedAt,
      if (durationSeconds != null) 'durationSeconds': durationSeconds,
      'source': source,
      'syncPending': true,
    };
    final history = await _readCache(userId, 'history');
    history.removeWhere((row) => row['clientEventId'] == eventId);
    history.insert(0, localRow);
    await _writeCache(userId, 'history', history);

    final outbox = await _readOutbox(userId, 'visits');
    outbox.add({
      'clientEventId': eventId,
      'artifactId': artifactId,
      'detectedAt': detectedAt,
      if (durationSeconds != null) 'durationSeconds': durationSeconds,
      'source': source,
    });
    await _writeOutbox(userId, 'visits', outbox);
    await _syncVisitOutbox(userId);
  }

  static Future<PersonalizationListResult> loadVisitHistory() async {
    final userId = _userId;
    if (userId == null) {
      return const PersonalizationListResult(items: [], fromCache: false, warning: 'Đăng nhập để xem lịch sử tham quan.');
    }
    await _syncVisitOutbox(userId);
    try {
      final response = await _get('$_visitsPath?page=0&size=100');
      if (!_ok(response)) throw Exception(_message(response));
      final remote = _rowsFromResponse(response);
      final local = await _readCache(userId, 'history');
      final pending = await _readOutbox(userId, 'visits');
      final pendingIds = pending.map((e) => e['clientEventId']?.toString()).toSet();
      final merged = <Map<String, dynamic>>[...remote];
      for (final row in local) {
        final eventId = row['clientEventId']?.toString();
        if (eventId != null && pendingIds.contains(eventId) &&
            !merged.any((remoteRow) => remoteRow['clientEventId']?.toString() == eventId)) {
          merged.add(row);
        }
      }
      merged.sort((a, b) => (b['detectedAt']?.toString() ?? '').compareTo(a['detectedAt']?.toString() ?? ''));
      await _writeCache(userId, 'history', merged);
      return PersonalizationListResult(
        items: merged,
        fromCache: false,
        warning: pending.isNotEmpty ? 'Đang ngoại tuyến – sẽ đồng bộ sau.' : null,
      );
    } catch (_) {
      return PersonalizationListResult(
        items: await _readCache(userId, 'history'),
        fromCache: true,
        warning: (await _readOutbox(userId, 'visits')).isNotEmpty
            ? 'Đang ngoại tuyến – sẽ đồng bộ sau. Hiển thị lịch sử đã lưu.'
            : 'Không kết nối được máy chủ. Đang hiển thị lịch sử đã lưu.',
      );
    }
  }

  static Future<void> _syncVisitOutbox(int userId) async {
    final outbox = await _readOutbox(userId, 'visits');
    if (outbox.isEmpty) return;
    // Send batches of up to 100; clientEventId is never regenerated during retry.
    for (var start = 0; start < outbox.length; start += 100) {
      final batch = outbox.skip(start).take(100).toList();
      try {
        final response = await _post('$_visitsPath/batch', {'events': batch});
        if (!_ok(response)) return;
        final accepted = batch.map((e) => e['clientEventId']?.toString()).whereType<String>().toSet();
        final remaining = (await _readOutbox(userId, 'visits'))
            .where((e) => !accepted.contains(e['clientEventId']?.toString())).toList();
        await _writeOutbox(userId, 'visits', remaining);
        final history = await _readCache(userId, 'history');
        for (final row in history) {
          if (accepted.contains(row['clientEventId']?.toString())) row['syncPending'] = false;
        }
        await _writeCache(userId, 'history', history);
      } catch (_) {
        return;
      }
    }
  }
}
