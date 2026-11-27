import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../features/auth/auth_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  MODELS  (map từ GET /api/artifacts/{id}?lang=vi|en)
// ─────────────────────────────────────────────────────────────────────────────

class ArtifactContentItem {
  final String languageCode;
  final String? title;
  final String? description;
  final String? audioUrl;
  final String? videoUrl;
  final List<String> imageUrls;
  final String? transcript;

  /// true khi server trả bản tiếng Việt thay cho ngôn ngữ yêu cầu
  /// (API: trường `fallback` ở data; cũng chấp nhận `fallbackUsed`).
  final bool fallbackUsed;

  const ArtifactContentItem({
    required this.languageCode,
    this.title,
    this.description,
    this.audioUrl,
    this.videoUrl,
    this.imageUrls = const [],
    this.transcript,
    this.fallbackUsed = false,
  });

  factory ArtifactContentItem.fromJson(
    Map<String, dynamic> json, {
    bool fallbackUsed = false,
  }) {
    return ArtifactContentItem(
      languageCode: json['languageCode']?.toString() ?? 'vi',
      title: _str(json['title']),
      description: _str(json['description']),
      audioUrl: _mediaUrl(_str(json['audioUrl'])),
      videoUrl: _mediaUrl(_str(json['videoUrl'])),
      imageUrls: _parseImageUrls(json['imageUrls']),
      transcript: _str(json['transcript']),
      fallbackUsed: fallbackUsed || json['fallbackUsed'] == true,
    );
  }

  String get languageLabel {
    if (languageCode == 'vi') return '🇻🇳 Tiếng Việt';
    if (languageCode == 'en') return '🇬🇧 English';
    return languageCode.toUpperCase();
  }
}

class ArtifactDetail {
  final int id;
  final String name;
  final String? artifactCode;
  final String? thumbnailUrl;
  final String? period;
  final String? material;
  final String? dimensions;
  final String? beaconUuid;
  final String? locationName;
  final String status;
  final String? requestedLanguage;
  final bool fallback;

  /// Bản content đã chọn theo ?lang= (ưu tiên data.content từ API).
  final ArtifactContentItem? selectedContent;

  /// Tất cả bản ngôn ngữ (nếu API trả contents[]).
  final List<ArtifactContentItem> contents;

  /// URL ảnh từ media[] (IMAGE) — bổ sung khi content.imageUrls trống.
  final List<String> mediaImageUrls;
  final String? mediaAudioUrl;
  final String? mediaVideoUrl;

  const ArtifactDetail({
    required this.id,
    required this.name,
    this.artifactCode,
    this.thumbnailUrl,
    this.period,
    this.material,
    this.dimensions,
    this.beaconUuid,
    this.locationName,
    required this.status,
    this.requestedLanguage,
    this.fallback = false,
    this.selectedContent,
    required this.contents,
    this.mediaImageUrls = const [],
    this.mediaAudioUrl,
    this.mediaVideoUrl,
  });

  factory ArtifactDetail.fromJson(Map<String, dynamic> json) {
    final fallback = json['fallback'] == true || json['fallbackUsed'] == true;
    final contentsRaw = json['contents'] as List<dynamic>? ?? [];
    final contents = contentsRaw
        .whereType<Map<String, dynamic>>()
        .map((c) => ArtifactContentItem.fromJson(c))
        .toList();

    ArtifactContentItem? selected;
    final contentRaw = json['content'];
    if (contentRaw is Map<String, dynamic>) {
      selected = ArtifactContentItem.fromJson(
        contentRaw,
        fallbackUsed: fallback,
      );
    } else if (contents.isNotEmpty) {
      final requested =
          json['requestedLanguage']?.toString() ??
          json['languageCode']?.toString();
      ArtifactContentItem match = contents.first;
      for (final c in contents) {
        if (requested != null && c.languageCode == requested) {
          match = c;
          break;
        }
      }
      selected = ArtifactContentItem(
        languageCode: match.languageCode,
        title: match.title,
        description: match.description,
        audioUrl: match.audioUrl,
        videoUrl: match.videoUrl,
        imageUrls: match.imageUrls,
        transcript: match.transcript,
        fallbackUsed: fallback,
      );
    }

    final media = json['media'] as List<dynamic>? ?? [];
    final imageUrls = <String>[];
    String? audioUrl;
    String? videoUrl;
    for (final item in media.whereType<Map<String, dynamic>>()) {
      final type = item['mediaType']?.toString().toUpperCase();
      final url = _mediaUrl(_str(item['fileUrl']));
      if (url == null) continue;
      switch (type) {
        case 'IMAGE':
          imageUrls.add(url);
        case 'AUDIO':
          audioUrl ??= url;
        case 'VIDEO':
          videoUrl ??= url;
      }
    }

    return ArtifactDetail(
      id: (json['id'] as num).toInt(),
      name: _str(json['name']) ?? '',
      artifactCode: _str(json['artifactCode']),
      thumbnailUrl: _mediaUrl(_str(json['thumbnailUrl'])),
      period: _str(json['period']),
      material: _str(json['material']),
      dimensions: _str(json['dimensions']),
      beaconUuid: _str(json['beaconUuid']),
      locationName: _str(json['locationName']),
      status: _str(json['status']) ?? 'ACTIVE',
      requestedLanguage: _str(json['requestedLanguage']),
      fallback: fallback,
      selectedContent: selected,
      contents: contents,
      mediaImageUrls: imageUrls,
      mediaAudioUrl: audioUrl,
      mediaVideoUrl: videoUrl,
    );
  }

  /// Nội dung theo lang: ưu tiên selectedContent (đã gắn fallback), rồi contents[].
  ArtifactContentItem? contentFor(String lang) {
    if (selectedContent != null) {
      // Khi API đã chọn bản theo ?lang=, dùng luôn (kể cả fallback).
      if (selectedContent!.languageCode == lang ||
          selectedContent!.fallbackUsed ||
          contents.length <= 1) {
        return _withMediaFallback(selectedContent!);
      }
    }
    for (final c in contents) {
      if (c.languageCode == lang) return _withMediaFallback(c);
    }
    if (selectedContent != null) return _withMediaFallback(selectedContent!);
    return contents.isNotEmpty ? _withMediaFallback(contents.first) : null;
  }

  ArtifactContentItem _withMediaFallback(ArtifactContentItem c) {
    final images = c.imageUrls.isNotEmpty ? c.imageUrls : mediaImageUrls;
    return ArtifactContentItem(
      languageCode: c.languageCode,
      title: c.title,
      description: c.description,
      audioUrl: c.audioUrl ?? mediaAudioUrl,
      videoUrl: c.videoUrl ?? mediaVideoUrl,
      imageUrls: images,
      transcript: c.transcript,
      fallbackUsed: c.fallbackUsed || fallback,
    );
  }
}

/// Kết quả tải hiện vật — phân biệt online / cache offline.
class ArtifactFetchResult {
  final ArtifactDetail artifact;
  final bool fromCache;

  const ArtifactFetchResult({required this.artifact, required this.fromCache});
}

class ArtifactUnavailableException implements Exception {
  final String message;
  const ArtifactUnavailableException(this.message);
  @override
  String toString() => message;
}

// ─────────────────────────────────────────────────────────────────────────────
//  SERVICE
// ─────────────────────────────────────────────────────────────────────────────

class ArtifactApiService {
  ArtifactApiService._();

  static const Duration _timeout = Duration(seconds: 10);
  static const int _maxCache = 20;
  static const String _cachePrefix = 'sh_artifact_';
  static const String _cacheKeysKey = 'sh_artifact_recent_v2';
  static Future<void>? _cacheQueue;

  static Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _cacheQueue;
    final release = Completer<void>();
    _cacheQueue = release.future;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      if (identical(_cacheQueue, release.future)) _cacheQueue = null;
      release.complete();
    }
  }

  static Future<ArtifactFetchResult> fetchArtifact(int id, String lang) async {
    try {
      final uri = Uri.parse('${AuthService.baseUrl}/api/artifacts/$id')
          .replace(queryParameters: {'lang': lang});
      final response = await AuthService.rawClient.get(uri).timeout(_timeout);
      if (response.statusCode == 404 || response.statusCode == 410) {
        try {
          await _locked(() => _removeCache(id));
        } catch (_) {}
        throw const ArtifactUnavailableException(
          'Hiện vật đã bị xóa hoặc không còn được cung cấp.',
        );
      }
      if (response.statusCode >= 400 && response.statusCode < 500) {
        throw const ArtifactUnavailableException(
          'Không thể mở hiện vật với yêu cầu hiện tại. Vui lòng thử lại.',
        );
      }
      if (response.statusCode != 200) {
        throw HttpException(
          'Không tải được hiện vật (mã ${response.statusCode}).',
        );
      }
      final raw = utf8.decode(response.bodyBytes);
      final artifact = _decode(raw);
      // A storage failure must not discard a successful HTTP response.
      try {
        await _locked(() => _saveCache(id, lang, raw));
      } catch (_) {}
      return ArtifactFetchResult(artifact: artifact, fromCache: false);
    } on ArtifactUnavailableException {
      rethrow;
    } catch (_) {
      final cached = await _locked(() => _loadCache(id, lang));
      if (cached != null) {
        return ArtifactFetchResult(artifact: cached, fromCache: true);
      }
      rethrow;
    }
  }

  static ArtifactDetail _decode(String raw) {
    final body = jsonDecode(raw) as Map<String, dynamic>;
    return ArtifactDetail.fromJson(
      (body['data'] as Map<String, dynamic>?) ?? body,
    );
  }

  static Future<void> _removeCache(int id) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key
        in prefs
            .getKeys()
            .where(
              (key) =>
                  key == '$_cachePrefix$id' ||
                  key.startsWith('$_cachePrefix${id}_'),
            )
            .toList()) {
      await prefs.remove(key);
    }
    final recent = await _recent(prefs);
    recent.remove('$id');
    await prefs.setStringList(_cacheKeysKey, recent);
  }

  static Future<bool> hasCached(int id, [String lang = 'vi']) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_cachePrefix$id');
  }

  // Migrate previous cache keys without counting language variants as separate artifacts.
  static Future<List<String>> _recent(SharedPreferences prefs) async {
    final current = prefs.getStringList(_cacheKeysKey);
    if (current != null) return current;
    final ids = <String>[];
    for (final key in prefs.getStringList('sh_artifact_keys') ?? <String>[]) {
      final id = key.split(':').first;
      if (!ids.contains(id) && prefs.containsKey('$_cachePrefix$id')) {
        ids.add(id);
      }
    }
    await prefs.setStringList(_cacheKeysKey, ids.take(_maxCache).toList());
    return ids.take(_maxCache).toList();
  }

  static Future<void> _touch(SharedPreferences prefs, int id) async {
    final ids = await _recent(prefs);
    ids.remove('$id');
    ids.insert(0, '$id');
    while (ids.length > _maxCache) {
      final old = ids.removeLast();
      for (final key
          in prefs
              .getKeys()
              .where(
                (k) =>
                    k == '$_cachePrefix$old' ||
                    k.startsWith('$_cachePrefix${old}_'),
              )
              .toList()) {
        await prefs.remove(key);
      }
    }
    await prefs.setStringList(_cacheKeysKey, ids);
  }

  static Future<void> _saveCache(int id, String lang, String raw) async {
    final prefs = await SharedPreferences.getInstance();
    await _recent(prefs);
    await prefs.setString('$_cachePrefix${id}_$lang', raw);
    await prefs.setString('$_cachePrefix$id', raw);
    await _touch(prefs, id);
  }

  static Future<ArtifactDetail?> _loadCache(int id, String lang) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw =
          prefs.getString('$_cachePrefix${id}_$lang') ??
          prefs.getString('$_cachePrefix${id}_vi') ??
          prefs.getString('$_cachePrefix$id');
      if (raw == null) return null;
      final saved = _decode(raw);
      final content = saved.contentFor(lang);
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final data = (body['data'] as Map<String, dynamic>?) ?? body;
      // Recompute fallback for the current request language.
      data['requestedLanguage'] = lang;
      data['fallback'] = content != null && content.languageCode != lang;
      data['fallbackUsed'] = data['fallback'];
      await _touch(prefs, id);
      return ArtifactDetail.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  static Future<List<ArtifactDetail>> recentArtifacts() => _locked(() async {
    final prefs = await SharedPreferences.getInstance();
    final result = <ArtifactDetail>[];
    for (final id in await _recent(prefs)) {
      try {
        final raw = prefs.getString('$_cachePrefix$id');
        if (raw != null) result.add(_decode(raw));
      } catch (_) {}
    }
    return result;
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────────────────────────────────────────

List<String> _parseImageUrls(dynamic raw) {
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .map((s) => _mediaUrl(s)!)
            .toList();
      }
    } catch (_) {}
  } else if (raw is List) {
    return raw
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .map((s) => _mediaUrl(s)!)
        .toList();
  }
  return const [];
}

String? _str(dynamic v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

// Uploaded media always follows the configured Gateway origin (including Android emulator).
String? _mediaUrl(String? raw) {
  if (raw == null) return null;
  final uri = Uri.tryParse(raw);
  if (uri != null && uri.path.startsWith('/api/media/files/')) {
    return Uri.parse(AuthService.baseUrl).resolve(uri.path).toString();
  }
  return raw;
}
