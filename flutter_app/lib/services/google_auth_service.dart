import 'dart:async';

import 'package:google_sign_in/google_sign_in.dart';

import '../config/app_config.dart';

const List<String> calendarScopes = <String>[
  'https://www.googleapis.com/auth/calendar.events',
  'https://www.googleapis.com/auth/calendar.events.readonly',
];

class GoogleAuthService {
  GoogleAuthService();

  final GoogleSignIn _signIn = GoogleSignIn.instance;
  GoogleSignInAccount? _user;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _sub;
  bool _initialized = false;

  GoogleSignInAccount? get user => _user;
  String? get email => _user?.email;
  bool get initialized => _initialized;
  bool get isSignedIn => _user != null;

  Future<void> init() async {
    if (_initialized) return;

    await _signIn.initialize(clientId: AppConfig.googleWebClientId);
    _initialized = true;

    _sub?.cancel();
    _sub = _signIn.authenticationEvents.listen((event) {
      _user = switch (event) {
        GoogleSignInAuthenticationEventSignIn() => event.user,
        GoogleSignInAuthenticationEventSignOut() => null,
      };
    });

    try {
      final account = await _signIn.attemptLightweightAuthentication();
      if (account != null) _user = account;
    } catch (_) {
      // 初回起動時は未ログインで失敗しても問題なし。
    }
  }

  /// 起動時の自動連携用。
  ///
  /// 以前ログイン済みで、Calendarスコープの許可も残っている場合だけtrueになる。
  /// ブラウザの仕様上、初回同意や追加権限が必要な場合は自動では開けないため、
  /// その場合はカレンダーページのGoogle連携ボタンを押す。
  Future<bool> tryAutoConnectCalendar() async {
    await init();
    if (_user == null) {
      try {
        final account = await _signIn.attemptLightweightAuthentication();
        if (account != null) _user = account;
      } catch (_) {
        return false;
      }
    }

    final header = await calendarAuthorizationHeader(interactive: false);
    return header != null && header.isNotEmpty;
  }

  Future<GoogleSignInAccount?> signIn() async {
    await init();
    if (_user != null) return _user;
    if (_signIn.supportsAuthenticate()) {
      _user = await _signIn.authenticate(scopeHint: calendarScopes);
    }
    return _user;
  }

  Future<String?> calendarAuthorizationHeader({bool interactive = true}) async {
    await init();

    var account = _user;
    if (account == null) {
      if (!interactive) return null;
      account = await signIn();
    }
    if (account == null) return null;

    var auth = await account.authorizationClient.authorizationForScopes(calendarScopes);
    if (auth == null) {
      if (!interactive) return null;
      auth = await account.authorizationClient.authorizeScopes(calendarScopes);
    }
    if (auth == null) return null;

    final headers = await account.authorizationClient.authorizationHeaders(calendarScopes);
    return headers?['Authorization'];
  }

  Future<void> signOut() async {
    if (_initialized) {
      await _signIn.disconnect();
    }
    _user = null;
  }

  void dispose() {
    _sub?.cancel();
  }
}
