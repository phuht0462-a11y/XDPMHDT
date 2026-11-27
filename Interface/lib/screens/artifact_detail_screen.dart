import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:video_player/video_player.dart';

import '../core/artifact_service.dart';
import '../core/media_lifecycle.dart';
import '../features/auth/auth_service.dart';
import '../features/feedback/feedback_screen.dart';
import '../features/personalization/personalization_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  ARTIFACT DETAIL SCREEN
// ─────────────────────────────────────────────────────────────────────────────

/// Màn hình chi tiết hiện vật.
///
/// - Gọi GET /api/artifacts/{id}?lang={lang} khi khởi động và khi đổi ngôn ngữ.
/// - Offline: đọc từ cache SharedPreferences, hiện banner "Đang xem bản đã tải".
/// - Không tự đóng khi rời vùng beacon – người dùng tự bấm Back.
class ArtifactDetailScreen extends StatefulWidget {
  final int artifactId;

  /// Ngôn ngữ ban đầu; null → AuthService.preferredLanguage.
  final String? initialLang;

  const ArtifactDetailScreen({
    super.key,
    required this.artifactId,
    this.initialLang,
  });

  @override
  State<ArtifactDetailScreen> createState() => _ArtifactDetailScreenState();
}

class _ArtifactDetailScreenState extends State<ArtifactDetailScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _primaryBrown = Color(0xFF6B3A1F);
  static const _bgColor = Color(0xFFF5F0EB);

  late TabController _tabController;
  late String _lang;
  List<(String, String)> _availableLanguages = const [
    ('vi', '🇻🇳 Tiếng Việt'),
    ('en', '🇬🇧 English'),
  ];

  ArtifactDetail? _artifact;
  bool _loading = true;
  String? _error;
  bool _isOffline = false; // đang xem từ cache

  bool _isFavorite = false;
  bool _favoriteBusy = false;
  int _favoriteVersion = 0;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lang = widget.initialLang ?? AuthService.preferredLanguage;
    _tabController = TabController(length: 4, vsync: this);
    _loadArtifact();
    _loadFavorite();
    unawaited(_loadLanguages());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading) _loadArtifact();
  }

  // ── Load dữ liệu ──────────────────────────────────────────────────────────

  Future<void> _loadArtifact() async {
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _artifact = null;
      _error = null;
      _isOffline = false;
    });
    try {
      final result = await ArtifactApiService.fetchArtifact(
        widget.artifactId,
        _lang,
      );
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _artifact = result.artifact;
        _isOffline = result.fromCache;
        _loading = false;
      });
    } on ArtifactUnavailableException catch (e) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } on SocketException {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _loading = false;
        _isOffline = true;
        _error = 'Không có kết nối mạng và chưa có bản đã tải.\nVui lòng kết nối internet rồi thử lại.';
      });
    } catch (e) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _loading = false;
        _error = 'Không tải được hiện vật.\n${e.toString()}';
      });
    }
  }

  /// The backend manages active languages dynamically; Vietnamese remains
  /// the safe fallback when the API is unavailable (including offline use).
  Future<void> _loadLanguages() async {
    try {
      final response = await AuthService.rawClient
          .get(Uri.parse('${AuthService.baseUrl}/api/languages'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final rows = body is Map ? body['data'] : body;
      if (rows is! List) return;
      final languages = <(String, String)>[];
      for (final row in rows) {
        if (row is! Map || row['active'] == false) continue;
        final code = row['code']?.toString().trim().toLowerCase() ?? '';
        final name = row['name']?.toString().trim() ?? '';
        if (!RegExp(r'^[a-z]{2,3}(-[a-z0-9]{2,6})?$').hasMatch(code)) {
          continue;
        }
        final label = code == 'vi'
            ? '🇻🇳 Tiếng Việt'
            : code == 'en'
                ? '🇬🇧 English'
                : '${name.isEmpty ? code.toUpperCase() : name} ($code)';
        if (!languages.any((item) => item.$1 == code)) {
          languages.add((code, label));
        }
      }
      if (languages.isNotEmpty && mounted) {
        setState(() => _availableLanguages = languages);
      }
    } catch (_) {
      // Network/older deployments: continue to offer the built-in VI/EN.
    }
  }

  void _switchLang(String lang) {
    if (lang == _lang) return;
    setState(() => _lang = lang);
    _loadArtifact();
  }

  // ── Yêu thích (API của Phú) ───────────────────────────────────────────────

  Future<void> _loadFavorite() async {
    final version = _favoriteVersion;
    if (!AuthService.isLoggedIn) return;
    try {
      final liked = await PersonalizationService.isFavorite(widget.artifactId);
      if (mounted && !_favoriteBusy && version == _favoriteVersion) {
        setState(() => _isFavorite = liked);
      }
    } catch (_) {}
  }

  Future<void> _toggleFavorite() async {
    if (_favoriteBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!AuthService.isLoggedIn) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Đăng nhập để lưu hiện vật yêu thích')),
      );
      return;
    }
    final next = !_isFavorite;
    ++_favoriteVersion;
    setState(() {
      _isFavorite = next;
      _favoriteBusy = true;
    });
    final a = _artifact;
    final result = next
        ? await PersonalizationService.addFavorite(
            artifactId: widget.artifactId,
            artifactName: a?.name ?? 'Hiện vật',
            siteName: a?.locationName ?? '',
            thumbnailUrl: a?.thumbnailUrl ?? '',
          )
        : await PersonalizationService.removeFavorite(widget.artifactId);
    if (!mounted) return;
    setState(() {
      _favoriteBusy = false;
      if (!result.success) _isFavorite = !next;
    });
    messenger.showSnackBar(SnackBar(content: Text(result.message)));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: _bgColor,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null && _artifact == null) {
      return _ErrorScreen(message: _error!, onRetry: _loadArtifact);
    }

    final artifact = _artifact!;
    final content = artifact.contentFor(_lang);

    return Scaffold(
      backgroundColor: _bgColor,
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          _buildSliverAppBar(artifact, content),
          _buildLangSelector(artifact),
          _buildMediaTabBar(),
        ],
        body: Column(
          children: [
            // Banners
            if (_isOffline)
              _Banner(
                color: Colors.blue.shade50,
                borderColor: Colors.blue.shade200,
                icon: Icons.cloud_off,
                iconColor: Colors.blue.shade600,
                text: 'Đang xem nội dung đã tải – có thể thiếu cập nhật mới nhất.',
              ),
            if (content != null && content.fallbackUsed)
              _Banner(
                color: Colors.orange.shade50,
                borderColor: Colors.orange.shade200,
                icon: Icons.translate,
                iconColor: Colors.orange.shade700,
                text: content.languageCode == 'vi'
                    ? 'Chưa có bản dịch, đang hiển thị tiếng Việt'
                    : 'Chưa lưu bản dịch này, đang hiển thị nội dung ${content.languageCode}',
              ),
            Expanded(child: _buildTabBarView(content)),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomActions(content),
    );
  }

  // ── Sliver App Bar ────────────────────────────────────────────────────────

  SliverAppBar _buildSliverAppBar(
    ArtifactDetail artifact,
    ArtifactContentItem? content,
  ) {
    return SliverAppBar(
      expandedHeight: MediaQuery.sizeOf(context).height < 600 ? 180 : 280,
      pinned: true,
      backgroundColor: _primaryBrown,
      foregroundColor: Colors.white,
      actions: [
        IconButton(
          tooltip: 'Tải lại hiện vật',
          onPressed: _loadArtifact,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          icon: Icon(
            _isFavorite ? Icons.favorite : Icons.favorite_border,
            color: _isFavorite ? Colors.red.shade300 : Colors.white,
          ),
          tooltip: 'Yêu thích',
          onPressed: _toggleFavorite,
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(56, 0, 104, 16),
        title: Text(
          content?.title ?? artifact.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
          ),
        ),
        background: Stack(
          fit: StackFit.expand,
          children: [
            _HeroImage(url: artifact.thumbnailUrl),
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                  stops: [0.5, 1.0],
                ),
              ),
            ),
            if (artifact.beaconUuid != null)
              Positioned(
                top: 16,
                right: 16,
                child: _BeaconBadge(active: artifact.status == 'ACTIVE'),
              ),
          ],
        ),
      ),
    );
  }

  // ── Language Selector ─────────────────────────────────────────────────────

  SliverPersistentHeader _buildLangSelector(ArtifactDetail artifact) {
    final height = 44 + (MediaQuery.textScalerOf(context).scale(12) - 12);
    final langs = [
      ..._availableLanguages,
      if (!_availableLanguages.any((item) => item.$1 == _lang))
        (_lang, _lang.toUpperCase()),
    ];
    return SliverPersistentHeader(
      pinned: true,
      delegate: _StickyHeaderDelegate(
        height: height,
        child: Container(
          color: const Color(0xFF8B4A26),
          height: height,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: langs.map((pair) {
              final selected = _lang == pair.$1;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => _switchLang(pair.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      pair.$2,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: selected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: selected ? _primaryBrown : Colors.white,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  // ── Media Tab Bar ─────────────────────────────────────────────────────────

  SliverPersistentHeader _buildMediaTabBar() {
    final height = 72 + (MediaQuery.textScalerOf(context).scale(12) - 12);
    return SliverPersistentHeader(
      pinned: true,
      delegate: _StickyHeaderDelegate(
        height: height,
        child: Container(
          color: Colors.white,
          child: TabBar(
            controller: _tabController,
            labelColor: _primaryBrown,
            unselectedLabelColor: Colors.grey.shade500,
            indicatorColor: _primaryBrown,
            indicatorWeight: 2.5,
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            labelStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            tabs: const [
              Tab(icon: Icon(Icons.article_outlined, size: 18), text: 'Mô tả'),
              Tab(
                icon: Icon(Icons.photo_library_outlined, size: 18),
                text: 'Hình ảnh',
              ),
              Tab(
                icon: Icon(Icons.volume_up_outlined, size: 18),
                text: 'Âm thanh',
              ),
              Tab(icon: Icon(Icons.info_outline, size: 18), text: 'Thông tin'),
            ],
          ),
        ),
      ),
    );
  }

  // ── Tab Bar View ──────────────────────────────────────────────────────────

  Widget _buildTabBarView(ArtifactContentItem? content) {
    return TabBarView(
      controller: _tabController,
      children: [
        _DescriptionTab(content: content),
        _GalleryTab(
          key: ValueKey((_lang, content?.imageUrls.join("|"))),
          images: content?.imageUrls ?? [],
        ),
        _AudioTab(
          // Key theo URL để đổi ngôn ngữ → tải lại audio mới
          key: ValueKey(content?.audioUrl ?? 'no-audio'),
          audioUrl: content?.audioUrl,
        ),
        _InfoTab(artifact: _artifact!),
      ],
    );
  }

  // ── Bottom Actions ────────────────────────────────────────────────────────

  Widget _buildBottomActions(ArtifactContentItem? content) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _showRatingDialog,
                icon: const Icon(Icons.star_outline_rounded, size: 18),
                label: const Text('Đánh giá'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _primaryBrown,
                  side: const BorderSide(color: _primaryBrown),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            if (content?.videoUrl != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _openVideoFullscreen(content!.videoUrl!),
                  icon: const Icon(Icons.play_circle_outline, size: 18),
                  label: const Text('Xem video'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryBrown,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openVideoFullscreen(String url) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _VideoFullscreenScreen(videoUrl: url)),
    );
  }

  void _showRatingDialog() {
    final name =
        _artifact?.contentFor(_lang)?.title ?? _artifact?.name ?? 'Hiện vật';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            FeedbackScreen(artifactId: widget.artifactId, artifactName: name),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  TAB: MÔ TẢ
// ─────────────────────────────────────────────────────────────────────────────

class _DescriptionTab extends StatelessWidget {
  final ArtifactContentItem? content;
  const _DescriptionTab({this.content});

  @override
  Widget build(BuildContext context) {
    if (content == null) {
      return const _EmptyContent(message: 'Chưa có nội dung mô tả.');
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (content!.title != null) ...[
            Text(
              content!.title!,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF3E2000),
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 16),
          ],
          if (content!.description != null)
            Text(
              content!.description!,
              style: const TextStyle(
                fontSize: 15,
                height: 1.7,
                color: Color(0xFF4A3728),
              ),
            ),
          if (content!.transcript != null) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF6B3A1F).withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: const Color(0xFF6B3A1F).withValues(alpha: 0.2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.record_voice_over_outlined,
                        size: 16,
                        color: Color(0xFF6B3A1F),
                      ),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Phụ đề thuyết minh',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Color(0xFF6B3A1F),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    content!.transcript!,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.brown.shade600,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  TAB: HÌNH ẢNH
// ─────────────────────────────────────────────────────────────────────────────

class _GalleryTab extends StatefulWidget {
  final List<String> images;
  const _GalleryTab({super.key, required this.images});

  @override
  State<_GalleryTab> createState() => _GalleryTabState();
}

class _GalleryTabState extends State<_GalleryTab> {
  int _current = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _openFullscreen(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            _PhotoGalleryScreen(images: widget.images, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) {
      return const _EmptyContent(
        message: 'Chưa có hình ảnh cho hiện vật này.',
        icon: Icons.photo_library_outlined,
      );
    }

    return Column(
      children: [
        // PageView lướt ngang
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.images.length,
            onPageChanged: (i) => setState(() => _current = i),
            itemBuilder: (context, index) => GestureDetector(
              onTap: () => _openFullscreen(index),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CachedNetworkImage(
                    imageUrl: widget.images[index],
                    fit: BoxFit.cover,
                    placeholder: (_, _) => Container(
                      color: const Color(0xFFEDD9C0),
                      child: const Center(child: CircularProgressIndicator()),
                    ),
                    errorWidget: (_, _, _) => Container(
                      color: const Color(0xFFEDD9C0),
                      child: const Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          size: 48,
                          color: Color(0xFF6B3A1F),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Dot indicator
        if (widget.images.length > 1) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              widget.images.length,
              (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: _current == i ? 20 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _current == i
                      ? const Color(0xFF6B3A1F)
                      : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Bấm vào ảnh để phóng to  •  ${_current + 1}/${widget.images.length}',
            style: TextStyle(fontSize: 12, color: Colors.brown.shade400),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  FULLSCREEN PHOTO GALLERY
// ─────────────────────────────────────────────────────────────────────────────

class _PhotoGalleryScreen extends StatefulWidget {
  final List<String> images;
  final int initialIndex;
  const _PhotoGalleryScreen({required this.images, required this.initialIndex});

  @override
  State<_PhotoGalleryScreen> createState() => _PhotoGalleryScreenState();
}

class _PhotoGalleryScreenState extends State<_PhotoGalleryScreen> {
  late int _current;
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_current + 1} / ${widget.images.length}'),
      ),
      body: PhotoViewGallery.builder(
        itemCount: widget.images.length,
        pageController: _controller,
        onPageChanged: (i) => setState(() => _current = i),
        builder: (context, index) => PhotoViewGalleryPageOptions(
          imageProvider: CachedNetworkImageProvider(widget.images[index]),
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 4,
          errorBuilder: (_, _, _) => const Center(
            child: Icon(
              Icons.broken_image_outlined,
              size: 64,
              color: Colors.white54,
            ),
          ),
        ),
        loadingBuilder: (_, _) =>
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  TAB: ÂM THANH
// ─────────────────────────────────────────────────────────────────────────────

class _AudioTab extends StatelessWidget {
  final String? audioUrl;
  const _AudioTab({super.key, this.audioUrl});

  @override
  Widget build(BuildContext context) {
    if (audioUrl == null) {
      return const _EmptyContent(
        message: 'Chưa có file âm thanh cho ngôn ngữ này.',
        icon: Icons.volume_off_outlined,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: _AudioPlayerWidget(audioUrl: audioUrl!),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  AUDIO PLAYER WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class _AudioPlayerWidget extends StatefulWidget {
  final String audioUrl;
  const _AudioPlayerWidget({required this.audioUrl});

  @override
  State<_AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<_AudioPlayerWidget>
    with MediaLifecycle<_AudioPlayerWidget> {
  static const _primaryBrown = Color(0xFF6B3A1F);

  late final AudioPlayer _player;
  StreamSubscription<PlaybackEvent>? _audioEvents;
  Timer? _bufferTimer;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _audioEvents = _player.playbackEventStream.listen(
      (event) {
        if (event.processingState == ProcessingState.buffering ||
            event.processingState == ProcessingState.loading) {
          _bufferTimer ??= Timer(const Duration(seconds: 20), _failAudio);
        } else {
          _bufferTimer?.cancel();
          _bufferTimer = null;
        }
      },
      onError: (Object error, StackTrace stack) {
        _failAudio();
      },
    );
    _initAudio();
  }

  Future<void> _initAudio() async {
    try {
      final uri = Uri.parse(widget.audioUrl);
      if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
        throw const FormatException();
      }
      await _player
          .setUrl(widget.audioUrl)
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      _failAudio();
    }
  }

  void _failAudio() {
    _bufferTimer?.cancel();
    if (mounted) setState(() => _hasError = true);
    unawaited(pauseMedia());
  }

  @override
  void dispose() {
    _bufferTimer?.cancel();
    _audioEvents?.cancel();
    _player.dispose().catchError((Object _) {});
    super.dispose();
  }

  Future<void> _audioAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      _failAudio();
    }
  }

  @override
  Future<void> pauseMedia() async {
    try {
      await _player.pause();
    } catch (_) {}
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: const Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Không tải được file âm thanh. Kiểm tra đường link hoặc kết nối mạng.',
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6B3A1F), Color(0xFF9C5932)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6B3A1F).withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          // Album art
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.museum_outlined,
              size: 48,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Thuyết minh âm thanh',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),

          // Progress bar
          StreamBuilder<Duration>(
            stream: _player.positionStream,
            builder: (context, posSnap) {
              final position = posSnap.data ?? Duration.zero;
              final duration = _player.duration ?? Duration.zero;
              final maxVal = duration.inMilliseconds.toDouble();
              final maxSafe = maxVal.isFinite && maxVal > 0 ? maxVal : 1.0;
              final curVal = position.inMilliseconds
                  .toDouble()
                  .clamp(0.0, maxSafe)
                  .toDouble();

              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                    ),
                    child: Slider(
                      value: curVal,
                      min: 0,
                      max: maxSafe,
                      onChanged: (v) => _audioAction(
                        () => _player.seek(Duration(milliseconds: v.toInt())),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(position),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          _formatDuration(_player.duration),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),

          // Controls
          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (context, snap) {
              final isPlaying = snap.data?.playing ?? false;
              final isLoading =
                  snap.data?.processingState == ProcessingState.loading ||
                  snap.data?.processingState == ProcessingState.buffering;

              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.replay_10_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: () {
                      final pos = _player.position;
                      final seek = pos - const Duration(seconds: 10);
                      _audioAction(
                        () => _player.seek(
                          seek < Duration.zero ? Duration.zero : seek,
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      if (isPlaying) {
                        _audioAction(_player.pause);
                      } else {
                        _audioAction(_player.play);
                      }
                    },
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: isLoading
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF6B3A1F),
                              ),
                            )
                          : Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: _primaryBrown,
                              size: 32,
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(
                      Icons.forward_10_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: () {
                      final pos = _player.position;
                      final duration = _player.duration ?? Duration.zero;
                      final seek = pos + const Duration(seconds: 10);
                      _audioAction(
                        () => _player.seek(seek > duration ? duration : seek),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  VIDEO FULLSCREEN SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class _VideoFullscreenScreen extends StatefulWidget {
  final String videoUrl;
  const _VideoFullscreenScreen({required this.videoUrl});

  @override
  State<_VideoFullscreenScreen> createState() => _VideoFullscreenScreenState();
}

class _VideoFullscreenScreenState extends State<_VideoFullscreenScreen>
    with MediaLifecycle<_VideoFullscreenScreen> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _hasError = false;
  int _generation = 0;
  bool _fullscreen = false;
  Timer? _videoBufferTimer;

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    try {
      await SystemChrome.setEnabledSystemUIMode(
        next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
      await SystemChrome.setPreferredOrientations(
        next
            ? [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : [],
      );
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    _videoBufferTimer?.cancel();
    _videoBufferTimer = null;
    final generation = ++_generation;
    final old = _controller;
    _controller = null;
    try {
      await _releaseVideo(old);
      if (!mounted || generation != _generation) return;
      final uri = Uri.parse(widget.videoUrl);
      if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
        throw const FormatException();
      }
      final controller = VideoPlayerController.networkUrl(uri);
      _controller = controller;
      controller.addListener(() {
        if (!mounted || !identical(_controller, controller)) return;
        if (controller.value.isBuffering) {
          _videoBufferTimer ??= Timer(const Duration(seconds: 20), () {
            if (mounted && identical(_controller, controller)) {
              setState(() => _hasError = true);
              unawaited(pauseMedia());
            }
          });
        } else {
          _videoBufferTimer?.cancel();
          _videoBufferTimer = null;
        }
        if (mounted &&
            identical(_controller, controller) &&
            controller.value.hasError &&
            !_hasError) {
          setState(() => _hasError = true);
        }
      });
      await controller.initialize().timeout(const Duration(seconds: 20));
      if (!mounted || generation != _generation) return;
      setState(() => _initialized = true);
      await _videoAction(controller.play);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _hasError = true);
      }
    }
  }

  Future<void> _videoAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _hasError = true);
    }
  }

  @override
  Future<void> pauseMedia() async {
    try {
      await _controller?.pause();
    } catch (_) {}
  }

  Future<void> _releaseVideo(VideoPlayerController? player) async {
    if (player == null) return;
    try {
      await player.pause();
    } catch (_) {}
    try {
      await player.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  @override
  void dispose() {
    ++_generation;
    _videoBufferTimer?.cancel();
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([]);
    }
    final controller = _controller;
    _controller = null;
    unawaited(_releaseVideo(controller));
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _fullscreen
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: const Text('Video thuyết minh'),
            ),
      body: _hasError
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.video_library_outlined,
                    color: Colors.white54,
                    size: 64,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Không tải được video.\nKiểm tra đường link hoặc kết nối mạng.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _hasError = false;
                        _initialized = false;
                      });
                      _initVideo();
                    },
                    child: const Text('Thử lại'),
                  ),
                ],
              ),
            )
          : !_initialized
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Video
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _controller!.value.aspectRatio,
                      child: VideoPlayer(_controller!),
                    ),
                  ),
                ),
                // Controls
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: _controller!,
                  builder: (_, val, _) {
                    final pos = val.position;
                    final dur = val.duration;
                    final maxMs = dur.inMilliseconds.toDouble();

                    return Container(
                      color: Colors.black87,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Column(
                        children: [
                          // Seek bar
                          Slider(
                            value: pos.inMilliseconds.toDouble().clamp(
                              0,
                              maxMs > 0 ? maxMs : 1,
                            ),
                            min: 0,
                            max: maxMs > 0 ? maxMs : 1,
                            activeColor: Colors.white,
                            inactiveColor: Colors.white24,
                            thumbColor: Colors.white,
                            onChanged: (v) => _videoAction(
                              () => _controller!.seekTo(
                                Duration(milliseconds: v.toInt()),
                              ),
                            ),
                          ),
                          // Time
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(pos),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                _formatDuration(dur),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          // Play / Pause
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: Icon(
                                  val.isPlaying
                                      ? Icons.pause_circle_filled_rounded
                                      : Icons.play_circle_filled_rounded,
                                  color: Colors.white,
                                  size: 48,
                                ),
                                onPressed: () {
                                  val.isPlaying
                                      ? _videoAction(() => _controller!.pause())
                                      : _videoAction(() => _controller!.play());
                                },
                              ),
                              IconButton(
                                tooltip: _fullscreen
                                    ? 'Thoát toàn màn hình'
                                    : 'Toàn màn hình',
                                icon: Icon(
                                  _fullscreen
                                      ? Icons.fullscreen_exit
                                      : Icons.fullscreen,
                                  color: Colors.white,
                                ),
                                onPressed: _toggleFullscreen,
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  TAB: THÔNG TIN VẬT LÝ
// ─────────────────────────────────────────────────────────────────────────────

class _InfoTab extends StatelessWidget {
  final ArtifactDetail artifact;
  const _InfoTab({required this.artifact});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoCard(
            title: 'Thông tin hiện vật',
            icon: Icons.info_outline,
            children: [
              _InfoRow(label: 'Mã hiện vật', value: artifact.artifactCode),
              _InfoRow(label: 'Niên đại', value: artifact.period),
              _InfoRow(label: 'Chất liệu', value: artifact.material),
              _InfoRow(label: 'Kích thước', value: artifact.dimensions),
              _InfoRow(
                label: 'Trạng thái',
                value: artifact.status == 'ACTIVE'
                    ? 'Đang trưng bày'
                    : 'Tạm ẩn',
              ),
            ],
          ),
          const SizedBox(height: 16),
          _InfoCard(
            title: 'Vị trí',
            icon: Icons.location_on_outlined,
            children: [
              _InfoRow(label: 'Di tích', value: artifact.locationName),
              if (artifact.beaconUuid != null)
                _InfoRow(label: 'Beacon UUID', value: artifact.beaconUuid),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _InfoCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: const Color(0xFF6B3A1F)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Color(0xFF6B3A1F),
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          ...children,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String? value;
  const _InfoRow({required this.label, this.value});

  @override
  Widget build(BuildContext context) {
    if (value == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final labelWidget = Text(
            label,
            style: TextStyle(fontSize: 13, color: Colors.brown.shade500),
          );
          final valueWidget = Text(
            value!,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFF3E2000),
            ),
          );
          if (constraints.maxWidth < 250 ||
              MediaQuery.textScalerOf(context).scale(13) > 18) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelWidget, const SizedBox(height: 4), valueWidget],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 110, child: labelWidget),
              const Text(
                ' : ',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              Expanded(child: valueWidget),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SHARED HELPERS
// ─────────────────────────────────────────────────────────────────────────────

class _HeroImage extends StatelessWidget {
  final String? url;
  const _HeroImage({this.url});

  @override
  Widget build(BuildContext context) {
    if (url != null) {
      return CachedNetworkImage(
        imageUrl: url!,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() => Container(
    color: const Color(0xFFEDD9C0),
    child: const Center(
      child: Icon(Icons.museum_outlined, size: 80, color: Color(0xFF6B3A1F)),
    ),
  );
}

class _BeaconBadge extends StatelessWidget {
  final bool active;
  const _BeaconBadge({required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? Colors.green.shade600.withValues(alpha: 0.9)
            : Colors.grey.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white54, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.bluetooth_searching_rounded,
            color: Colors.white,
            size: 14,
          ),
          const SizedBox(width: 4),
          Text(
            active ? 'Beacon Active' : 'Beacon Off',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final Color color;
  final Color borderColor;
  final IconData icon;
  final Color iconColor;
  final String text;
  const _Banner({
    required this.color,
    required this.borderColor,
    required this.icon,
    required this.iconColor,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

class _EmptyContent extends StatelessWidget {
  final String message;
  final IconData icon;
  const _EmptyContent({
    required this.message,
    this.icon = Icons.article_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.brown.shade200),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.brown.shade400,
                fontSize: 15,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorScreen({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chi tiết hiện vật')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 20),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, height: 1.5),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;
  const _StickyHeaderDelegate({required this.child, required this.height});

  @override
  Widget build(_, double shrink, bool overlaps) =>
      SizedBox(height: height, child: child);
  @override
  double get maxExtent => height;
  @override
  double get minExtent => height;
  @override
  bool shouldRebuild(_StickyHeaderDelegate old) =>
      child != old.child || height != old.height;
}
