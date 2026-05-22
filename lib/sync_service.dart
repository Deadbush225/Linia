import 'dart:async';
import 'dart:convert';

import 'package:firedart/firedart.dart';
import 'package:google_sign_in_all_platforms/google_sign_in_all_platforms.dart';
import 'package:grpc/grpc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

class SyncConflict {
  final Map<String, dynamic> serverTask;
  const SyncConflict(this.serverTask);
}

class SyncResult {
  final int pushed;
  final int pulled;
  final List<SyncConflict> conflicts;
  final List<Map<String, dynamic>> pulledTasks;
  final List<String> archivedIds;
  final List<Map<String, dynamic>> archivedTasks;
  final String? error;

  const SyncResult({
    this.pushed = 0,
    this.pulled = 0,
    this.conflicts = const [],
    this.pulledTasks = const [],
    this.archivedIds = const [],
    this.archivedTasks = const [],
    this.error,
  });

  bool get hasConflicts => conflicts.isNotEmpty;
  bool get ok => error == null;
}

class _SyncUser {
  final String uid;
  final String email;
  final String displayName;

  const _SyncUser({
    required this.uid,
    required this.email,
    required this.displayName,
  });
}

class SyncService {
  static const _prefKeyBaseUrl = 'sync_base_url';
  static const _prefKeyEmail = 'sync_email';
  static const _prefKeyUid = 'sync_uid';
  static const _prefKeyDisplayName = 'sync_display_name';
  static const _prefKeyIdToken = 'sync_firebase_id_token';
  static const _prefKeyRefreshToken = 'sync_firebase_refresh_token';
  static const _prefKeyTokenExpiryMs = 'sync_firebase_token_expiry_ms';

  static const _desktopGoogleClientId = String.fromEnvironment(
    'LINIA_GOOGLE_CLIENT_ID',
    defaultValue: '',
  );
  static const _desktopGoogleClientSecret = String.fromEnvironment(
    'LINIA_GOOGLE_CLIENT_SECRET',
    defaultValue: '',
  );

  static String get _apiKey => DefaultFirebaseOptions.currentPlatform.apiKey;
  static String get _projectId => DefaultFirebaseOptions.currentPlatform.projectId;

  static final StreamController<bool> _authStateCtrl =
      StreamController<bool>.broadcast();

  static GoogleSignIn? _googleSignIn;
  static Firestore? _firestore;

  static bool _initialized = false;
  static _SyncUser? _currentUser;
  static String _idToken = '';
  static String _refreshToken = '';
  static int _idTokenExpiryMs = 0;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    await _restoreSession();
  }

  static Future<void> configure({
    required String baseUrl,
    required String email,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyBaseUrl, baseUrl.trim());
    await prefs.setString(_prefKeyEmail, email.trim());
  }

  static Future<String?> get baseUrl async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKeyBaseUrl) ?? '';
  }

  static Stream<bool> authStateChanges() async* {
    await _ensureInitialized();
    yield _currentUser != null;
    yield* _authStateCtrl.stream;
  }

  static Future<bool> get isConfigured async {
    await _ensureInitialized();
    return _currentUser != null;
  }

  static bool get _desktopMissingGoogleClientConfig {
    if (!isDesktop) return false;
    return _desktopGoogleClientId.trim().isEmpty ||
        _desktopGoogleClientSecret.trim().isEmpty;
  }

  static GoogleSignIn _google() {
    final existing = _googleSignIn;
    if (existing != null) return existing;

    final created = isDesktop
        ? GoogleSignIn(
            params: GoogleSignInParams(
              clientId: _desktopGoogleClientId.trim(),
              clientSecret: _desktopGoogleClientSecret.trim(),
            ),
          )
        : GoogleSignIn();
    _googleSignIn = created;
    return created;
  }

  static Firestore _db() {
    final existing = _firestore;
    if (existing != null) return existing;

    final created = Firestore(
      _projectId,
      authenticator: _authenticateFirestoreRequest,
    );
    _firestore = created;
    return created;
  }

  static Future<void> clearCredentials() async {
    await _ensureInitialized();

    try {
      await _google().signOut();
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKeyBaseUrl);
    await prefs.remove(_prefKeyEmail);
    await prefs.remove(_prefKeyUid);
    await prefs.remove(_prefKeyDisplayName);
    await prefs.remove(_prefKeyIdToken);
    await prefs.remove(_prefKeyRefreshToken);
    await prefs.remove(_prefKeyTokenExpiryMs);

    _currentUser = null;
    _idToken = '';
    _refreshToken = '';
    _idTokenExpiryMs = 0;

    _authStateCtrl.add(false);
  }

  static Future<String?> signInWithGoogle() async {
    try {
      await _ensureInitialized();

      if (_desktopMissingGoogleClientConfig) {
        return 'Desktop Google sign-in requires --dart-define=LINIA_GOOGLE_CLIENT_ID and --dart-define=LINIA_GOOGLE_CLIENT_SECRET.';
      }

      final creds = await _google().signIn();
      if (creds == null) {
        return 'Google sign-in was canceled.';
      }

      if (creds.accessToken.trim().isEmpty &&
          (creds.idToken?.trim().isEmpty ?? true)) {
        return 'Google sign-in succeeded but returned no usable tokens.';
      }

      await _exchangeGoogleCredentials(creds);
      await _readRemote();
      _authStateCtrl.add(true);
      return null;
    } catch (ex) {
      return _humanizeAuthError(ex);
    }
  }

  static Future<String?> login({String? email, String? password}) async {
    return signInWithGoogle();
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static List<String> _asStringList(dynamic value) {
    if (value is List) return value.map((e) => e.toString()).toList();
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return <String>[];
  }

  static Map<String, dynamic> _normalizeTask(Map<String, dynamic> raw) {
    final noteBody = raw['noteBody']?.toString() ??
        raw['note_body']?.toString() ??
        raw['description']?.toString() ??
        '';

    return {
      'id': raw['id']?.toString() ?? '',
      'title': raw['title']?.toString() ?? '',
      'noteBody': noteBody,
      'status': raw['status']?.toString() ?? 'todo',
      'priority': raw['priority']?.toString() ?? 'medium',
      'startDate': raw['startDate']?.toString() ?? raw['start_date']?.toString() ?? '',
      'endDate': raw['endDate']?.toString() ?? raw['end_date']?.toString() ?? '',
      'updatedAt': _asInt(raw['updatedAt']),
      'rawFrontmatter': raw['rawFrontmatter']?.toString(),
      'isArchived': raw['isArchived'] == true,
      'tags': _asStringList(raw['tags']),
      'description': noteBody,
      'assignee': raw['assignee']?.toString() ?? '',
      'projectRoot': raw['projectRoot']?.toString() ?? '',
      'projectKey': raw['projectKey']?.toString() ?? '',
      'project_folder':
          raw['project_folder']?.toString() ?? raw['projectFolder']?.toString() ?? '',
    };
  }

  static _SyncUser _requireUser() {
    final user = _currentUser;
    if (user == null) {
      throw Exception('Not signed in. Please sign in first.');
    }
    return user;
  }

  static Future<String> _firebaseIdToken() async {
    await _ensureInitialized();
    if (_idToken.isEmpty) {
      throw Exception('Missing Firebase token. Sign in again.');
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_idTokenExpiryMs <= nowMs + 60000) {
      await _refreshFirebaseToken();
    }

    if (_idToken.isEmpty) {
      throw Exception('Unable to acquire Firebase token. Sign in again.');
    }
    return _idToken;
  }

  static String _userCollectionPath(String uid, String collection) {
    return 'users/$uid/$collection';
  }

  static void _throwForHttpError(http.Response response, String operation) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw Exception('$operation failed (${response.statusCode}): ${response.body}');
  }

  static Future<void> _authenticateFirestoreRequest(
    Map<String, String> metadata,
    String uri,
  ) async {
    final token = await _firebaseIdToken();
    metadata['authorization'] = 'Bearer $token';
  }

  static Future<List<Map<String, dynamic>>> _listCollection(String collection) async {
    final user = _requireUser();
    final docs = <Map<String, dynamic>>[];

    final col = _db().collection(_userCollectionPath(user.uid, collection));
    String nextPageToken = '';

    do {
      final page = await col.get(pageSize: 300, nextPageToken: nextPageToken);
      for (final document in page) {
        docs.add(_normalizeTask(document.map));
      }
      nextPageToken = page.nextPageToken;
    } while (nextPageToken.isNotEmpty);

    return docs;
  }

  static Future<void> _writeDocument(
    String collection,
    String documentId,
    Map<String, dynamic> data,
  ) async {
    final user = _requireUser();
    await _db()
        .document('${_userCollectionPath(user.uid, collection)}/$documentId')
        .set(data);
  }

  static Future<void> _deleteDocument(String collection, String documentId) async {
    final user = _requireUser();
    try {
      await _db()
          .document('${_userCollectionPath(user.uid, collection)}/$documentId')
          .delete();
    } on GrpcError catch (ex) {
      if (ex.code == StatusCode.notFound) return;
      rethrow;
    }
  }

  static Future<String> debugProbe() async {
    try {
      final user = _requireUser();
      final col = _db().collection(_userCollectionPath(user.uid, 'tasks'));
      final page = await col.get(pageSize: 5);
      final ids = page.map((d) => d.id).toList();
      return 'Firestore OK for uid ${user.uid}. tasks returned ${page.length} docs: ${ids.join(', ')}';
    } catch (ex) {
      return 'Firestore probe failed: $ex';
    }
  }

  static Future<List<Map<String, dynamic>>> _readRemote() async {
    return _listCollection('tasks');
  }

  static Future<List<Map<String, dynamic>>> _readArchivedRemote() async {
    return _listCollection('archive');
  }

  static String _projectDocId(String key) {
    return key.replaceAll(RegExp(r'[\s/]+'), '__').toLowerCase();
  }

  static Future<void> upsertProjects(List<Map<String, dynamic>> projects) async {
    for (final raw in projects) {
      final key = (raw['projectKey']?.toString().trim().isNotEmpty == true)
          ? raw['projectKey'].toString().trim()
          : raw['name']?.toString().trim() ?? '';
      if (key.isEmpty) continue;

      final id = (raw['id']?.toString().trim().isNotEmpty == true)
          ? raw['id'].toString().trim()
          : _projectDocId(key);

      await _writeDocument('projects', id, {
        'id': id,
        'name': raw['name']?.toString() ?? key,
        'projectKey': key,
        'projectRoot': raw['projectRoot']?.toString() ?? '',
        'folderPath':
            raw['folderPath']?.toString() ?? raw['project_folder']?.toString() ?? '',
        'updatedAt': _asInt(raw['updatedAt']) > 0
            ? _asInt(raw['updatedAt'])
            : DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  static Future<List<Map<String, dynamic>>> readRemoteProjects() async {
    final docs = await _listCollection('projects');
    return docs.map((data) {
      final key = data['projectKey']?.toString().trim().isNotEmpty == true
          ? data['projectKey'].toString().trim()
          : (data['name']?.toString().trim().isNotEmpty == true
              ? data['name'].toString().trim()
              : data['id']?.toString() ?? '');
      return {
        'id': data['id']?.toString() ?? key,
        'name': data['name']?.toString() ?? key,
        'projectKey': key,
        'projectRoot': data['projectRoot']?.toString() ?? '',
        'folderPath': data['folderPath']?.toString() ?? '',
        'updatedAt': _asInt(data['updatedAt']),
      };
    }).toList();
  }

  static Future<SyncResult> sync(List<Map<String, dynamic>> localTasks) async {
    try {
      final remote = await _readRemote();
      final remoteById = {for (final t in remote) t['id'] as String: t};

      var pushed = 0;
      final conflicts = <SyncConflict>[];

      for (final raw in localTasks) {
        final task = _normalizeTask(raw);
        final id = task['id'] as String;
        if (id.isEmpty) continue;

        final localTs = _asInt(task['updatedAt']);
        final remoteTask = remoteById[id];
        final remoteTs = remoteTask == null ? 0 : _asInt(remoteTask['updatedAt']);

        if (remoteTask != null && remoteTs > localTs) {
          conflicts.add(SyncConflict(remoteTask));
          continue;
        }

        await _writeDocument('tasks', id, {
          ...task,
          'isArchived': false,
          'updatedAt': localTs > 0 ? localTs : DateTime.now().millisecondsSinceEpoch,
        });
        pushed += 1;
      }

      final latest = await _readRemote();
      final archived = await _readArchivedRemote();

      final byId = <String, Map<String, dynamic>>{};
      for (final t in latest) {
        final id = (t['id'] as String?) ?? '';
        if (id.isEmpty) continue;
        byId[id] = t;
      }
      for (final t in archived) {
        final id = (t['id'] as String?) ?? '';
        if (id.isEmpty) continue;

        final existing = byId[id];
        if (existing == null) {
          byId[id] = t;
          continue;
        }

        final archivedTs = _asInt(t['updatedAt']);
        final existingTs = _asInt(existing['updatedAt']);
        if (archivedTs >= existingTs) {
          byId[id] = t;
        }
      }

      final pulledTasks = byId.values.where((t) => t['isArchived'] != true).toList();
      final archivedIds = byId.values
          .where((t) => t['isArchived'] == true)
          .map((t) => t['id'] as String)
          .where((id) => id.isNotEmpty)
          .toList();

      return SyncResult(
        pushed: pushed,
        pulled: pulledTasks.length + archivedIds.length,
        conflicts: conflicts,
        pulledTasks: pulledTasks,
        archivedIds: archivedIds,
        archivedTasks: archived,
      );
    } catch (ex) {
      return SyncResult(error: ex.toString());
    }
  }

  static Future<SyncResult> pushOne(Map<String, dynamic> task) async {
    return sync([task]);
  }

  static Future<String?> forcePushOne(Map<String, dynamic> task) async {
    try {
      final normalized = _normalizeTask(task);
      final taskId = normalized['id'] as String;
      if (taskId.isEmpty) return 'Cannot force-push task without id';

      final ts = _asInt(normalized['updatedAt']);
      final winningTs = ts > 0 ? ts : DateTime.now().millisecondsSinceEpoch;

      await _writeDocument('tasks', taskId, {
        ...normalized,
        'isArchived': false,
        'updatedAt': winningTs,
      });

      await _deleteDocument('archive', taskId);
      return null;
    } catch (ex) {
      return ex.toString();
    }
  }

  static Future<String?> archiveRemote(Map<String, dynamic> task) async {
    try {
      final normalized = _normalizeTask(task);
      final taskId = normalized['id'] as String;
      if (taskId.isEmpty) return 'Cannot archive task without id';

      final nowTs = DateTime.now().millisecondsSinceEpoch;
      await _writeDocument('archive', taskId, {
        ...normalized,
        'isArchived': true,
        'archivedAt': nowTs,
        'updatedAt': nowTs,
      });

      await _deleteDocument('tasks', taskId);
      return null;
    } catch (ex) {
      return ex.toString();
    }
  }

  static Future<String?> unarchiveRemote(Map<String, dynamic> task) async {
    try {
      final normalized = _normalizeTask(task);
      final taskId = normalized['id'] as String;
      if (taskId.isEmpty) return 'Cannot unarchive task without id';

      final nowTs = DateTime.now().millisecondsSinceEpoch;
      await _writeDocument('tasks', taskId, {
        ...normalized,
        'isArchived': false,
        'updatedAt': nowTs,
      });

      await _deleteDocument('archive', taskId);
      return null;
    } catch (ex) {
      return ex.toString();
    }
  }

  static Future<({List<Map<String, dynamic>> tasks, String? error})> pullAll() async {
    try {
      final active = await _readRemote();
      final archived = await _readArchivedRemote();
      return (tasks: [...active, ...archived], error: null);
    } catch (ex) {
      return (tasks: <Map<String, dynamic>>[], error: ex.toString());
    }
  }

  static Future<({String email, String baseUrl})> savedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      email: prefs.getString(_prefKeyEmail) ?? '',
      baseUrl: prefs.getString(_prefKeyBaseUrl) ?? '',
    );
  }

  static Future<bool> get hasToken async => isConfigured;

  static Future<String?> register({
    required String baseUrl,
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    return 'Email/password registration was replaced by Google sign-in.';
  }

  static Future<String?> verifyOtp({
    required String baseUrl,
    required String email,
    required String otp,
  }) async {
    return 'OTP verification is not used with Google sign-in.';
  }

  static Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = (prefs.getString(_prefKeyUid) ?? '').trim();
    final email = (prefs.getString(_prefKeyEmail) ?? '').trim();
    final displayName = (prefs.getString(_prefKeyDisplayName) ?? '').trim();
    final idToken = (prefs.getString(_prefKeyIdToken) ?? '').trim();
    final refreshToken = (prefs.getString(_prefKeyRefreshToken) ?? '').trim();
    final expiryMs = prefs.getInt(_prefKeyTokenExpiryMs) ?? 0;

    if (uid.isEmpty || idToken.isEmpty || refreshToken.isEmpty) {
      _currentUser = null;
      _idToken = '';
      _refreshToken = '';
      _idTokenExpiryMs = 0;
      return;
    }

    _currentUser = _SyncUser(
      uid: uid,
      email: email,
      displayName: displayName,
    );
    _idToken = idToken;
    _refreshToken = refreshToken;
    _idTokenExpiryMs = expiryMs;
  }

  static Future<void> _saveSession(_SyncUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyUid, user.uid);
    await prefs.setString(_prefKeyEmail, user.email);
    await prefs.setString(_prefKeyDisplayName, user.displayName);
    await prefs.setString(_prefKeyIdToken, _idToken);
    await prefs.setString(_prefKeyRefreshToken, _refreshToken);
    await prefs.setInt(_prefKeyTokenExpiryMs, _idTokenExpiryMs);
  }

  static Future<void> _exchangeGoogleCredentials(
    GoogleSignInCredentials creds,
  ) async {
    final postBodyParts = <String>[
      if (creds.accessToken.trim().isNotEmpty)
        'access_token=${Uri.encodeQueryComponent(creds.accessToken.trim())}',
      if ((creds.idToken?.trim().isNotEmpty ?? false))
        'id_token=${Uri.encodeQueryComponent(creds.idToken!.trim())}',
      'providerId=google.com',
    ];

    final response = await http.post(
      Uri.https(
        'identitytoolkit.googleapis.com',
        '/v1/accounts:signInWithIdp',
        {'key': _apiKey},
      ),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'postBody': postBodyParts.join('&'),
        'requestUri': 'http://localhost',
        'returnSecureToken': true,
        'returnIdpCredential': true,
      }),
    );

    _throwForHttpError(response, 'Google identity exchange');

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    _idToken = payload['idToken']?.toString() ?? '';
    _refreshToken = payload['refreshToken']?.toString() ?? '';
    final expiresInSec = _asInt(payload['expiresIn']);
    _idTokenExpiryMs =
        DateTime.now().millisecondsSinceEpoch + (expiresInSec * 1000);

    final uid = payload['localId']?.toString() ?? '';
    final email = payload['email']?.toString() ?? '';
    final displayName = payload['displayName']?.toString() ?? '';

    if (uid.isEmpty || _idToken.isEmpty || _refreshToken.isEmpty) {
      throw Exception('Google sign-in exchange returned incomplete auth data.');
    }

    _currentUser = _SyncUser(uid: uid, email: email, displayName: displayName);
    await _saveSession(_currentUser!);
  }

  static Future<void> _refreshFirebaseToken() async {
    if (_refreshToken.isEmpty) {
      throw Exception('Missing refresh token. Sign in again.');
    }

    final response = await http.post(
      Uri.https(
        'securetoken.googleapis.com',
        '/v1/token',
        {'key': _apiKey},
      ),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body:
          'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(_refreshToken)}',
    );

    _throwForHttpError(response, 'Firebase token refresh');

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    _idToken = payload['id_token']?.toString() ?? _idToken;
    _refreshToken = payload['refresh_token']?.toString() ?? _refreshToken;

    final expiresInSec = _asInt(payload['expires_in']);
    _idTokenExpiryMs =
        DateTime.now().millisecondsSinceEpoch + (expiresInSec * 1000);

    final uid = payload['user_id']?.toString() ?? _currentUser?.uid ?? '';
    _currentUser = _SyncUser(
      uid: uid,
      email: _currentUser?.email ?? '',
      displayName: _currentUser?.displayName ?? '',
    );

    if (_currentUser != null) {
      await _saveSession(_currentUser!);
    }
  }

  static String _humanizeAuthError(Object ex) {
    final text = ex.toString();
    final match = RegExp(r'message\":\s*\"([^\"]+)\"').firstMatch(text);
    if (match != null && match.group(1) != null) {
      return match.group(1)!.replaceAll('_', ' ').toLowerCase();
    }
    return text;
  }
}
