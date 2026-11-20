import 'dart:async';

import 'package:flutter/widgets.dart';

import '../auth/auth_service.dart';
import 'personalization_service.dart';

/// Retries persisted work while the app is foregrounded, on resume and login.
/// No connectivity permission or third-party connectivity plugin is required.
class PersonalizationSync extends StatefulWidget {
  const PersonalizationSync({super.key, required this.child});

  final Widget child;

  @override
  State<PersonalizationSync> createState() => _PersonalizationSyncState();
}

class _PersonalizationSyncState extends State<PersonalizationSync>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AuthService.currentUser.addListener(_retry);
    _start();
  }

  void _start() {
    _active = true;
    _timer?.cancel();
    _retry();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _retry());
  }

  void _retry() {
    if (!mounted || !_active || AuthService.currentUser.value == null) return;
    unawaited(_sync());
  }

  Future<void> _sync() async {
    try {
      await PersonalizationService.syncPending();
    } catch (_) {
      // Keep persisted work for a later retry, including account changes.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
    } else {
      _active = false;
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    AuthService.currentUser.removeListener(_retry);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
