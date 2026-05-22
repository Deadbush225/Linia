import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
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

class SyncService {
  static const _prefKeyBaseUrl = 'sync_base_url';
  static const _prefKeyEmail = 'sync_email';
  static const _firestoreHost = 'firestore.googleapis.com';

  static String get _apiKey => DefaultFirebaseOptions.currentPlatform.apiKey;
  static String get _projectId => DefaultFirebaseOptions.currentPlatform.projectId;

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

  static Future<bool> get isConfigured async => FirebaseAuth.instance.currentUser != null;

  static Future<void> clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKeyBaseUrl);
    await prefs.remove(_prefKeyEmail);
    await FirebaseAuth.instance.signOut();
  }

  static Future<String?> login({String? email, String? password}) async {
    try {
      final normalizedEmail = (email ?? '').trim();
      final pwd = password ?? '';
      if (normalizedEmail.isEmpty || pwd.isEmpty) {
        return 'Email and password are required.';
      }
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: normalizedEmail,
        password: pwd,
      );
      await configure(baseUrl: '', email: normalizedEmail, password: pwd);
      await _readRemote();
      return null;
    } on FirebaseAuthException catch (ex) {
      return ex.message ?? ex.code;
    } catch (ex) {
      return ex.toString();
    }
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
      return value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
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
      'project_folder': raw['project_folder']?.toString() ?? raw['projectFolder']?.toString() ?? '',
    };
  }

  static User _requireUser() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Not signed in. Please sign in first.');
    }
    return user;
  }

  static Future<String> _idToken() async {
    final user = _requireUser();
    final token = await user.getIdToken(true);
    if (token == null || token.isEmpty) {
      throw Exception('Unable to acquire Firebase Auth token.');
    }
    return token;
  }

  static String _userCollectionPath(String uid, String collection) {
    return 'users/${Uri.encodeComponent(uid)}/$collection';
  }

  static Uri _collectionUri(String uid, String collection, {Map<String, String>? query}) {
    return Uri.https(
      _firestoreHost,
      '/v1/projects/$_projectId/databases/(default)/documents/${_userCollectionPath(uid, collection)}',
      query,
    );
  }

  static Uri _documentUri(
    String uid,
    String collection,
    String documentId, {
    Map<String, String>? query,
  }) {
    return Uri.https(
      _firestoreHost,
      '/v1/projects/$_projectId/databases/(default)/documents/${_userCollectionPath(uid, collection)}/${Uri.encodeComponent(documentId)}',
      query,
    );
  }

  static Map<String, String> _jsonHeaders(String token) {
    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  static Map<String, String> _authHeaders(String token) {
    return {
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  static void _throwForHttpError(http.Response response, String operation) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw Exception('$operation failed (${response.statusCode}): ${response.body}');
  }

  static Map<String, dynamic> _encodeValue(dynamic value) {
    if (value == null) return {'nullValue': null};
    if (value is bool) return {'booleanValue': value};
    if (value is int) return {'integerValue': value.toString()};
    if (value is double) return {'doubleValue': value};
    if (value is String) return {'stringValue': value};
    if (value is DateTime) return {'timestampValue': value.toUtc().toIso8601String()};
    if (value is Map) {
      return {
        'mapValue': {
          'fields': {
            for (final entry in value.entries) entry.key.toString(): _encodeValue(entry.value),
          },
        },
      };
    }
    if (value is Iterable) {
      return {
        'arrayValue': {
          'values': value.map(_encodeValue).toList(),
        },
      };
    }
    return {'stringValue': value.toString()};
  }

  static dynamic _decodeValue(Map<String, dynamic> value) {
    if (value.containsKey('nullValue')) return null;
    if (value.containsKey('booleanValue')) return value['booleanValue'] == true;
    if (value.containsKey('integerValue')) return int.tryParse(value['integerValue'].toString()) ?? 0;
    if (value.containsKey('doubleValue')) return double.tryParse(value['doubleValue'].toString()) ?? 0.0;
    if (value.containsKey('timestampValue')) return value['timestampValue'].toString();
    if (value.containsKey('stringValue')) return value['stringValue']?.toString() ?? '';
    if (value.containsKey('mapValue')) {
      final fields = ((value['mapValue'] as Map?)?['fields'] as Map?)?.cast<String, dynamic>() ?? {};
      return {
        for (final entry in fields.entries)
          entry.key: _decodeValue((entry.value as Map).cast<String, dynamic>()),
      };
    }
    if (value.containsKey('arrayValue')) {
      final values = ((value['arrayValue'] as Map?)?['values'] as List?) ?? const [];
      return values
          .whereType<Map>()
          .map((item) => _decodeValue(item.cast<String, dynamic>()))
          .toList();
    }
    return value;
  }

  static Map<String, dynamic> _documentData(Map<String, dynamic> document) {
    final raw = <String, dynamic>{};
    final fields = (document['fields'] as Map?)?.cast<String, dynamic>() ?? {};
    for (final entry in fields.entries) {
      raw[entry.key] = _decodeValue((entry.value as Map).cast<String, dynamic>());
    }
    final name = document['name']?.toString() ?? '';
    if ((raw['id'] == null || raw['id'].toString().isEmpty) && name.isNotEmpty) {
      raw['id'] = name.split('/').last;
    }
    return raw;
  }

  static Map<String, dynamic> _normalizeDocument(Map<String, dynamic> document) {
    return _normalizeTask(_documentData(document));
  }

  static Future<List<Map<String, dynamic>>> _listCollection(String collection) async {
    final user = _requireUser();
    final token = await _idToken();
    final docs = <Map<String, dynamic>>[];
    String? pageToken;

    do {
      final query = <String, String>{
        'key': _apiKey,
        'pageSize': '300',
        if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken,
      };
      final response = await http.get(
        _collectionUri(user.uid, collection, query: query),
        headers: _authHeaders(token),
      );
      if (response.statusCode == 404) return [];
      _throwForHttpError(response, 'list $collection');

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final documents = (decoded['documents'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      for (final document in documents) {
        docs.add(_normalizeDocument(document));
      }
      pageToken = decoded['nextPageToken']?.toString();
    } while (pageToken != null && pageToken.isNotEmpty);

    return docs;
  }

  static Future<void> _writeDocument(
    String collection,
    String documentId,
    Map<String, dynamic> data,
  ) async {
    final user = _requireUser();
    final token = await _idToken();
    final response = await http.patch(
      _documentUri(user.uid, collection, documentId, query: {'key': _apiKey}),
      headers: _jsonHeaders(token),
      body: jsonEncode({
        'fields': {
          for (final entry in data.entries) entry.key: _encodeValue(entry.value),
        },
      }),
    );
    _throwForHttpError(response, 'write $collection/$documentId');
  }

  static Future<void> _deleteDocument(String collection, String documentId) async {
    final user = _requireUser();
    final token = await _idToken();
    final response = await http.delete(
      _documentUri(user.uid, collection, documentId, query: {'key': _apiKey}),
      headers: _authHeaders(token),
    );
    if (response.statusCode == 404) return;
    _throwForHttpError(response, 'delete $collection/$documentId');
  }

  static Future<String> debugProbe() async {
    try {
      final user = _requireUser();
      final token = await _idToken();
      final url = _collectionUri(
        user.uid,
        'tasks',
        query: {'key': _apiKey, 'pageSize': '5'},
      );
      final response = await http.get(url, headers: _authHeaders(token));
      if (response.statusCode == 404) {
        return 'REST OK, but no tasks collection for this user yet (404).';
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        return 'REST denied (${response.statusCode}). Check Firestore rules.';
      }
      _throwForHttpError(response, 'probe');

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final documents = (decoded['documents'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final ids = documents
          .map((d) => (d['name']?.toString() ?? '').split('/').last)
          .where((id) => id.isNotEmpty)
          .toList();

      return 'REST OK for uid ${user.uid}. tasks returned ${documents.length} docs: ${ids.join(', ')}';
    } catch (ex) {
      return 'REST probe failed: $ex';
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
        'folderPath': raw['folderPath']?.toString() ?? raw['project_folder']?.toString() ?? '',
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

  static Future<bool> get hasToken async => FirebaseAuth.instance.currentUser != null;

  static Future<String?> register({
    required String baseUrl,
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    try {
      final normalizedEmail = email.trim();
      if (normalizedEmail.isEmpty || password.isEmpty) {
        return 'Email and password are required.';
      }
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: normalizedEmail,
        password: password,
      );
      final displayName = [firstName.trim(), lastName.trim()]
          .where((p) => p.isNotEmpty)
          .join(' ')
          .trim();
      if (displayName.isNotEmpty) {
        await cred.user?.updateDisplayName(displayName);
      }
      await configure(baseUrl: baseUrl, email: normalizedEmail, password: password);
      return null;
    } on FirebaseAuthException catch (ex) {
      return ex.message ?? ex.code;
    } catch (ex) {
      return ex.toString();
    }
  }

  static Future<String?> verifyOtp({
    required String baseUrl,
    required String email,
    required String otp,
  }) async {
    return null;
  }
}
