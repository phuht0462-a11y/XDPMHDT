
import 'package:flutter/material.dart';

import '../../screens/artifact_detail_screen.dart';
import '../personalization/personalization_service.dart';

const _cream = Color(0xFFF7F5EF);
const _sage = Color(0xFF718B78);
const _ink = Color(0xFF26352B);

/// Màn hình hiện vật yêu thích.
/// Hỗ trợ làm mới, thông báo trạng thái cache và bỏ yêu thích.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  bool _loading = true;
  bool _fromCache = false;
  String? _warning;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoader = true}) async {
    if (showLoader && mounted) {
      setState(() => _loading = true);
    }

    try {
      final result = await PersonalizationService.loadFavorites();

      if (!mounted) return;

      setState(() {
        _items = result.items;
        _fromCache = result.fromCache;
        _warning = result.warning;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _warning = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  int? _artifactId(Map<String, dynamic> item) {
    final rawId =
        item['artifactId'] ?? item['artifact_id'] ?? item['id'];

    if (rawId is num) {
      return rawId.toInt();
    }

    return int.tryParse(rawId?.toString() ?? '');
  }

  String _string(
    Map<String, dynamic> item,
    String key, [
    String fallback = '',
  ]) {
    final value = item[key];
    return value?.toString() ?? fallback;
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    final id = _artifactId(item);

    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Không xác định được mã hiện vật.'),
        ),
      );
      return;
    }

    // Optimistic UI: remove immediately; restore the list on a server error.
    final previous = List<Map<String, dynamic>>.from(_items);
    setState(() => _items.removeWhere((row) => _artifactId(row) == id));

    try {
      final result = await PersonalizationService.removeFavorite(id);
      if (!mounted) return;

      if (!result.success) {
        setState(() => _items = previous);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
      if (result.success) {
        await _load(showLoader: false);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _items = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.toString().replaceFirst('Exception: ', ''),
          ),
        ),
      );
    }
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    final id = _artifactId(item);

    if (id == null) return;

    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ArtifactDetailScreen(artifactId: id),
      ),
    );

    if (mounted) {
      await _load(showLoader: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        title: const Text(
          'Hiện vật yêu thích',
          style: TextStyle(
            color: _ink,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: _ink),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => _load(),
            tooltip: 'Làm mới',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: _sage),
              )
            : RefreshIndicator(
                onRefresh: () => _load(showLoader: false),
                color: _sage,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_warning != null &&
                        _warning!.trim().isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFECEDE5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _fromCache
                                  ? Icons.cloud_off
                                  : Icons.info_outline,
                              color: _sage,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _warning!,
                                style: const TextStyle(color: _ink),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_items.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 90),
                        child: Column(
                          children: [
                            Icon(
                              Icons.favorite_border,
                              size: 64,
                              color: _sage,
                            ),
                            SizedBox(height: 12),
                            Text(
                              'Chưa có hiện vật yêu thích',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: _ink,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Mở chi tiết hiện vật và chọn '
                              '“Lưu yêu thích”.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    else
                      ..._items.map((item) {
                        final imageUrl = _string(
                          item,
                          'thumbnailUrl',
                          _string(item, 'image'),
                        );
                        final name = _string(
                          item,
                          'artifactName',
                          _string(item, 'name', 'Hiện vật'),
                        );
                        final site = _string(
                          item,
                          'siteName',
                          'Di tích',
                        );

                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          elevation: 0,
                          color: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _openDetail(item),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: imageUrl.isEmpty
                                        ? Container(
                                            width: 88,
                                            height: 88,
                                            color: const Color(0xFFECEDE5),
                                            child: const Icon(
                                              Icons.account_balance,
                                              color: _sage,
                                            ),
                                          )
                                        : Image.network(
                                            imageUrl,
                                            width: 88,
                                            height: 88,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                Container(
                                              width: 88,
                                              height: 88,
                                              color: const Color(0xFFECEDE5),
                                              child: const Icon(
                                                Icons.account_balance,
                                                color: _sage,
                                              ),
                                            ),
                                          ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: _ink,
                                          ),
                                        ),
                                        const SizedBox(height: 5),
                                        Text(
                                          site,
                                          style: const TextStyle(
                                            color: Colors.black54,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Đã lưu: ${_string(item, 'savedAt', '—')}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.black45,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Bỏ yêu thích',
                                    onPressed: () => _remove(item),
                                    icon: const Icon(
                                      Icons.favorite,
                                      color: _sage,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
      ),
    );
  }
}
