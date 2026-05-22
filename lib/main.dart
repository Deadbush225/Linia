import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:home_widget/home_widget.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'firebase_options.dart';
import 'sync_service.dart';
import 'widgets/auth_gate.dart';

// ─── Entry point ─────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  if (Platform.isAndroid || Platform.isIOS) {
    HomeWidget.setAppGroupId('com.deadbush225.linia');
  }

  if (Platform.isLinux) {
    await windowManager.ensureInitialized();
    await windowManager.setIcon('assets/Linia.png');
    const windowOptions = WindowOptions(
      size: Size(1280, 720),
      center: true,
      title: 'Linia',
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const GanttApp());
}

class _ToggleAlwaysOnTopIntent extends Intent {
  const _ToggleAlwaysOnTopIntent();
}

class _MinimizeWindowIntent extends Intent {
  const _MinimizeWindowIntent();
}

// ─── App root ─────────────────────────────────────────────────────────────────
class GanttApp extends StatelessWidget {
  const GanttApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Linia',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF7C6AF7),
          secondary: const Color(0xFFF7926A),
          surface: const Color(0xFF1E1E2E),
        ),
        scaffoldBackgroundColor: const Color(0xFF181825),
        cardColor: const Color(0xFF1E1E2E),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E2E),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const AuthGate(child: HomePage()),
    );
  }
}

// ─── Palette ─────────────────────────────────────────────────────────────────
const List<Color> kPalette = [
  Color(0xFF7C6AF7), Color(0xFFF7926A), Color(0xFF6BBFF7),
  Color(0xFFF7C86A), Color(0xFF6AF79E), Color(0xFFF76A9E),
  Color(0xFF6AF7F0), Color(0xFFC86AF7), Color(0xFFF7F06A),
  Color(0xFF6A9EF7),
];

const List<String> kStatuses   = ['todo', 'in-progress', 'blocked', 'done'];
const List<String> kPriorities = ['low', 'medium', 'high', 'critical'];
const String kPrefDefaultNoteTemplate = 'default_note_template';
const String kUpdateConfigAsset = 'assets/update_config.json';

// ─── Helpers ─────────────────────────────────────────────────────────────────
String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';

DateTime? _parseDate(String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    final p = s.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  } catch (_) { return null; }
}

String? _normalizeDateString(String? s) {
  final d = _parseDate(s);
  return d == null ? null : _fmtDate(d);
}

/// Returns today's date with time zeroed out — used for due-date comparisons
/// so that a task due today is never treated as overdue.
DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

List<int>? _parseSemver(String raw) {
  final cleaned = raw.trim().replaceFirst(RegExp(r'^[vV]\s*'), '');
  final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(cleaned);
  if (match == null) return null;
  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}

bool _isNewerVersion(String current, String latest) {
  final curr = _parseSemver(current);
  final next = _parseSemver(latest);
  if (curr == null || next == null) return false;
  for (var i = 0; i < 3; i++) {
    if (next[i] > curr[i]) return true;
    if (next[i] < curr[i]) return false;
  }
  return false;
}

Future<String?> _loadUpdateRepo() async {
  try {
    final raw = await rootBundle.loadString(kUpdateConfigAsset);
    final data = jsonDecode(raw);
    if (data is Map && data['repo'] is String) {
      final repo = (data['repo'] as String).trim();
      return repo.isEmpty ? null : repo;
    }
  } catch (_) {}
  return null;
}

class _ReleaseAsset {
  final String name;
  final String url;
  final int size;

  const _ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
  });
}

class _ReleaseInfo {
  final String tag;
  final String name;
  final String body;
  final String htmlUrl;
  final List<_ReleaseAsset> assets;

  const _ReleaseInfo({
    required this.tag,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.assets,
  });
}

Future<_ReleaseInfo> _fetchLatestRelease(String repo) async {
  final uri = Uri.parse('https://api.github.com/repos/$repo/releases/latest');
  final resp = await http.get(uri, headers: {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'Linia',
  });
  if (resp.statusCode != 200) {
    throw Exception('GitHub API error (${resp.statusCode})');
  }

  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final tag = (data['tag_name'] as String? ?? '').trim();
  if (tag.isEmpty) throw Exception('No release tag found');

  final assets = <_ReleaseAsset>[];
  final rawAssets = (data['assets'] as List?) ?? const [];
  for (final raw in rawAssets) {
    if (raw is! Map<String, dynamic>) continue;
    final name = (raw['name'] as String? ?? '').trim();
    final url = (raw['browser_download_url'] as String? ?? '').trim();
    final size = (raw['size'] as num?)?.toInt() ?? 0;
    if (name.isEmpty || url.isEmpty) continue;
    assets.add(_ReleaseAsset(name: name, url: url, size: size));
  }

  return _ReleaseInfo(
    tag: tag,
    name: (data['name'] as String? ?? '').trim(),
    body: (data['body'] as String? ?? '').trim(),
    htmlUrl: (data['html_url'] as String? ?? '').trim(),
    assets: assets,
  );
}

_ReleaseAsset? _pickAssetForPlatform(List<_ReleaseAsset> assets) {
  if (assets.isEmpty) return null;

  if (Platform.isLinux) {
    final candidates = assets.where((asset) {
      final name = asset.name.toLowerCase();
      return name.contains('linux') && (name.endsWith('.tar.gz') || name.endsWith('.tgz'));
    }).toList();
    if (candidates.isNotEmpty) return candidates.first;

    return assets.firstWhere(
      (asset) {
        final name = asset.name.toLowerCase();
        return name.endsWith('.tar.gz') || name.endsWith('.tgz');
      },
      orElse: () => assets.first,
    );
  }

  if (Platform.isAndroid) {
    final candidates = assets.where((asset) {
      final name = asset.name.toLowerCase();
      return name.contains('android') && name.endsWith('.apk');
    }).toList();
    if (candidates.isNotEmpty) return candidates.first;

    return assets.firstWhere(
      (asset) => asset.name.toLowerCase().endsWith('.apk'),
      orElse: () => assets.first,
    );
  }

  return null;
}

String _normalizeNoteBody(String body, {String? title}) {
  var text = body.replaceAll('\r\n', '\n').trim();
  if (text.isEmpty) return '';

  // If the scaffold was accidentally prepended twice, collapse it.
  final scaffoldRx = RegExp(
    r'^(#\s+.+?)\n+##\s+Description\s*\n+\1\n+##\s+Description\s*\n*',
    caseSensitive: false,
  );
  text = text.replaceFirstMapped(scaffoldRx, (m) => '${m.group(1)}\n\n## Description\n\n');

  if (title != null && title.trim().isNotEmpty) {
    final escaped = RegExp.escape(title.trim());
    final byTitleRx = RegExp(
      '^#\\s+$escaped\\s*\\n+##\\s+Description\\s*\\n+#\\s+$escaped\\s*\\n+##\\s+Description\\s*\\n*',
      caseSensitive: false,
    );
    text = text.replaceFirst(byTitleRx, '# ${title.trim()}\n\n## Description\n\n');
  }

  // Collapse repeated Notes headings that can appear after cross-client sync.
  while (text.contains(RegExp(r'\n##\s+Notes\s*\n+##\s+Notes\b', caseSensitive: false))) {
    text = text.replaceAll(
      RegExp(r'\n##\s+Notes\s*\n+##\s+Notes\b', caseSensitive: false),
      '\n## Notes',
    );
  }

  return text.trim();
}

// ─── Task model ───────────────────────────────────────────────────────────────
class Task {
  final String id;
  final String title;
  final String noteBody;
  final String status;
  final String priority;
  final String? startDate;
  final String? endDate;
  final String filePath;
  final int colorIdx;
  /// Unix milliseconds — used for conflict resolution (last-write-wins).
  final int updatedAt;

  const Task({
    required this.id,
    required this.title,
    this.noteBody = '',
    required this.status,
    required this.priority,
    this.startDate,
    this.endDate,
    required this.filePath,
    required this.colorIdx,
    this.updatedAt = 0,
  });

  Task copyWith({
    String? title, String? noteBody, String? status, String? priority,
    String? startDate, String? endDate,
    bool clearStartDate = false, bool clearEndDate = false,
    int? updatedAt,
  }) => Task(
    id: id,
    title: title ?? this.title,
    noteBody: noteBody ?? this.noteBody,
    status: status ?? this.status,
    priority: priority ?? this.priority,
    startDate: clearStartDate ? null : (startDate ?? this.startDate),
    endDate: clearEndDate ? null : (endDate ?? this.endDate),
    filePath: filePath,
    colorIdx: colorIdx,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Color get color => kPalette[colorIdx % kPalette.length];

  bool get isOverdue {
    final due = _parseDate(endDate);
    if (due == null) return false;
    final today = _today();
    return due.isBefore(today) && status != 'done';
  }

  int get daysUntilDue {
    final due = _parseDate(endDate);
    if (due == null) return 9999;
    return due.difference(_today()).inDays;
  }

  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'noteBody': noteBody, 'status': status, 'priority': priority,
    'startDate': startDate, 'endDate': endDate, 'colorIdx': colorIdx,
    'updatedAt': updatedAt,
  };
}

// ─── File I/O helpers ─────────────────────────────────────────────────────────

/// Generate a short random alphanumeric ID (12 chars), similar to nanoid.
String _nanoid([int len = 12]) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rand = StringBuffer();
  for (var i = 0; i < len; i++) {
    rand.write(chars[(DateTime.now().microsecondsSinceEpoch + i * 7919) % chars.length]);
  }
  return rand.toString();
}

/// Build a YAML frontmatter markdown file for a new task.
String _buildFrontmatter({
  required String id,
  required String title,
  required String status,
  required String priority,
  String? noteBody,
  String? startDate,
  String? endDate,
  int? updatedAt,
}) {
  final ts = updatedAt ?? DateTime.now().millisecondsSinceEpoch;
  final body = _normalizeNoteBody(noteBody ?? '', title: title);
  final fallbackBody = '''# $title

## Description

## Notes''';
  return '''---
id: $id
title: $title
status: $status
priority: $priority
startDate: ${startDate ?? ''}
endDate: ${endDate ?? ''}
updated_at: $ts
---

${body.isEmpty ? fallbackBody : body}
''';
}

/// Rewrite a single frontmatter field in a markdown file on disk.
/// Always bumps `updated_at` to the current time so the file's timestamp
/// is fresh and conflict resolution works correctly on next push.
Future<void> _writeTaskField(String filePath, Map<String, String?> fields) async {
  final file = File(filePath);
  if (!await file.exists()) return;
  var content = await file.readAsString();

  // Auto-stamp updated_at unless caller explicitly provides one.
  final allFields = <String, String?>{
    ...fields,
    if (!fields.containsKey('updated_at'))
      'updated_at': DateTime.now().millisecondsSinceEpoch.toString(),
  };

  for (final entry in allFields.entries) {
    final key = entry.key;
    final val = entry.value;
    final lineRx = RegExp('^$key\\s*:.*\$', multiLine: true);
    if (val == null || val.isEmpty) {
      content = content.replaceAll(lineRx, '');
    } else if (lineRx.hasMatch(content)) {
      content = content.replaceAll(lineRx, '$key: $val');
    } else {
      // Insert before closing ---
      content = content.replaceFirst(RegExp(r'\n---'), '\n$key: $val\n---');
    }
  }
  // Remove consecutive blank lines that might appear after deletion
  content = content.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  await file.writeAsString(content);
}

/// Rewrites the markdown body section (everything after frontmatter).
Future<void> _writeTaskBody(String filePath, String noteBody) async {
  final file = File(filePath);
  if (!await file.exists()) return;

  final content = await file.readAsString();
  final fmMatch = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---', multiLine: true).firstMatch(content);
  final cleanBody = _normalizeNoteBody(noteBody);

  if (fmMatch == null) {
    await file.writeAsString(cleanBody);
    return;
  }

  final frontmatter = content.substring(0, fmMatch.end);
  final rebuilt = cleanBody.isEmpty ? '$frontmatter\n' : '$frontmatter\n\n$cleanBody\n';
  await file.writeAsString(rebuilt);
}

/// Move a file into projectRoot/archive/, timestamping on collision.
Future<void> _archiveFile(String filePath, String projectRoot) async {
  final file = File(filePath);
  if (!await file.exists()) return;
  final archiveDir = Directory('$projectRoot/archive');
  if (!await archiveDir.exists()) await archiveDir.create(recursive: true);
  final name = filePath.split('/').last;
  var dest = '${archiveDir.path}/$name';
  if (await File(dest).exists()) {
    dest = '${archiveDir.path}/${name.replaceAll('.md', '')}-${DateTime.now().millisecondsSinceEpoch}.md';
  }
  await file.rename(dest);
}

// ─── Markdown parser ──────────────────────────────────────────────────────────
Task? parseMarkdownTask(String filePath, String content, int colorIdx) {
  final fmMatch = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---', multiLine: true).firstMatch(content);
  if (fmMatch == null) return null;
  final fm = fmMatch.group(1)!;
  final rawBody = content.substring(fmMatch.end).trim();

  String? field(String key) {
    final m = RegExp('^$key\\s*:\\s*(.+)\$', multiLine: true).firstMatch(fm);
    return m?.group(1)?.trim().replaceAll(RegExp("^[\"']|[\"']\$"), '');
  }

  final parsedTitle = field('title') ?? filePath.split('/').last.replaceAll('.md', '');
  final noteBody = _normalizeNoteBody(rawBody, title: parsedTitle);

  final startDate = _normalizeDateString(
    field('startDate') ?? field('start_date') ?? field('start'),
  );
  final endDate = _normalizeDateString(
    field('endDate') ?? field('end_date') ?? field('due') ?? field('end'),
  );

  return Task(
    id:        field('id') ?? filePath.split('/').last.replaceAll('.md', ''),
    title:     parsedTitle,
    noteBody:  noteBody,
    status:    field('status') ?? 'todo',
    priority:  field('priority') ?? 'medium',
    startDate: startDate,
    endDate:   endDate,
    filePath:  filePath,
    colorIdx:  colorIdx,
    updatedAt: int.tryParse(field('updated_at') ?? '') ?? 0,
  );
}

// ─── Folder scanner ───────────────────────────────────────────────────────────
Future<List<Task>> scanProjectFolder(String rootPath) async {
  final dir = Directory(rootPath);
  if (!await dir.exists()) return [];
  final tasks = <Task>[];
  int colorIdx = 0;

  Future<void> scanDirRecursive(Directory d) async {
    await for (final entry in d.list()) {
      if (entry is Directory) {
        if (entry.path.split('/').last == 'archive') continue;
        await scanDirRecursive(entry);
        continue;
      }
      if (entry is! File || !entry.path.endsWith('.md')) continue;
      try {
        final task = parseMarkdownTask(entry.path, await entry.readAsString(), colorIdx);
        if (task != null) {
          tasks.add(task);
          colorIdx++;
        }
      } catch (_) {}
    }
  }

  await scanDirRecursive(dir);
  tasks.sort((a, b) => a.daysUntilDue.compareTo(b.daysUntilDue));
  return tasks;
}

Future<List<Task>> scanArchiveFolder(String rootPath) async {
  final archive = Directory('$rootPath/archive');
  if (!await archive.exists()) return [];

  final tasks = <Task>[];
  int colorIdx = 0;
  await for (final entry in archive.list()) {
    if (entry is! File || !entry.path.endsWith('.md')) continue;
    try {
      final task = parseMarkdownTask(entry.path, await entry.readAsString(), colorIdx);
      if (task != null) {
        tasks.add(task.copyWith(status: 'done'));
        colorIdx++;
      }
    } catch (_) {}
  }

  tasks.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return tasks;
}

// ─── Home page ────────────────────────────────────────────────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin, WidgetsBindingObserver, TrayListener, WindowListener {
  static const _prefProjectRootLegacy = 'project_root';
  static const _prefProjectRoots = 'project_roots';
  static const _prefActiveProjectRoot = 'active_project_root';
  static const _prefActiveProjectKeys = 'active_project_keys';
  static const _prefAotWidth = 'linux_aot_width';
  static const _prefAotHeight = 'linux_aot_height';
  static const _prefAotEdge = 'linux_aot_edge';
  static const _prefAotAlign = 'linux_aot_align';
  static const _prefAotOffsetX = 'linux_aot_offset_x';
  static const _prefAotOffsetY = 'linux_aot_offset_y';

  List<String> _projectRoots = [];
  int _activeRootIndex = 0;
  Map<String, String> _activeProjectKeyByRoot = {};
  List<String> _currentRootProjects = [];
  List<Task> _tasks = [];
  List<Task> _archivedTasks = [];
  bool _loading = false;
  String _scanInfo = '';
  bool _permissionDenied = false;
  bool _isAlwaysOnTop = false;
  late final TabController _tabs;
  static const MethodChannel _hotkeyChannel = MethodChannel('linia/global_hotkey');
  double _aotWidth = 400.0;
  double _aotHeight = 700.0;
  String _aotEdge = 'right';
  String _aotAlign = 'center';
  double _aotOffsetX = 0.0;
  double _aotOffsetY = 0.0;
  bool _trayReady = false;
  bool _checkingUpdate = false;
  bool _allowWindowClose = false;
  bool _blockingDialogOpen = false;

  String? get _projectRoot => _projectRoots.isEmpty ? null : _projectRoots[_activeRootIndex];

  String _rootName(String root) {
    final normalized = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    final parts = normalized.split('/');
    return parts.isEmpty ? normalized : parts.last;
  }

  String _projectDocId(String rootOrKey) {
    return rootOrKey.replaceAll(RegExp(r'[\s/]+'), '__').toLowerCase();
  }

  Future<bool> _isContainerRoot(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) return false;
    bool hasTopLevelMarkdown = false;
    bool hasTopLevelDirs = false;
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.md')) {
        hasTopLevelMarkdown = true;
      }
      if (entry is Directory && entry.path.split('/').last != 'archive') {
        hasTopLevelDirs = true;
      }
      if (hasTopLevelMarkdown && hasTopLevelDirs) break;
    }
    return hasTopLevelDirs && !hasTopLevelMarkdown;
  }

  Future<List<String>> _projectFoldersUnderRoot(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) return [];
    final names = <String>[];
    await for (final entry in dir.list()) {
      if (entry is! Directory) continue;
      final name = entry.path.split('/').last;
      if (name == 'archive') continue;
      names.add(name);
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  String _projectKeyForTaskPath(String root, String filePath, {required bool isContainerRoot}) {
    if (!isContainerRoot) return _rootName(root);
    if (!filePath.startsWith('$root/')) return _rootName(root);

    final rel = filePath.substring(root.length + 1);
    if (rel.isEmpty) return _rootName(root);
    final first = rel.split('/').first;
    if (first.isEmpty || first == 'archive' || first.endsWith('.md')) return _rootName(root);
    return first;
  }

  String _currentProjectPathForRoot(String root) {
    final key = _activeProjectKeyByRoot[root];
    if (key == null || key.isEmpty) return root;
    return '$root/$key';
  }

  String? _projectRootForFilePath(String filePath) {
    String? best;
    for (final root in _projectRoots) {
      if (filePath == root || filePath.startsWith('$root/')) {
        if (best == null || root.length > best.length) {
          best = root;
        }
      }
    }
    return best;
  }

  List<String> _normalizeProjectRoots(List<String> roots) {
    final cleaned = roots.map((r) => r.trim()).where((r) => r.isNotEmpty).toSet().toList();
    cleaned.sort((a, b) => a.length.compareTo(b.length));

    final normalized = <String>[];
    for (final candidate in cleaned) {
      final isNested = normalized.any((base) => candidate.startsWith('$base/'));
      if (!isNested) normalized.add(candidate);
    }
    return normalized;
  }

  // Sync state
  _SyncStatus _syncStatus = _SyncStatus.idle;
  String _syncInfo = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabs = TabController(length: 4, vsync: this);
    _initLinuxWindowState();
    _initTray();
    _initHotkeyChannel();
    _checkPermissionThenLoad();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdates());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoSyncOnExit();
    if (Platform.isLinux) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _initTray() async {
    if (!Platform.isLinux) return;
    try {
      trayManager.addListener(this);
      await trayManager.setIcon('assets/tray_icon.png');
      await trayManager.setToolTip('Linia');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Show'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit'),
      ]));
      setState(() => _trayReady = true);
    } catch (ex) {
      debugPrint('Tray init failed: $ex');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _autoSyncOnExit();
    }
  }

  Future<void> _initLinuxWindowState() async {
    if (!Platform.isLinux) return;
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    final alwaysOnTop = await windowManager.isAlwaysOnTop();
    await _loadAlwaysOnTopPrefs();
    if (!mounted) return;
    setState(() => _isAlwaysOnTop = alwaysOnTop);
  }

  Future<void> _loadAlwaysOnTopPrefs() async {
    if (!Platform.isLinux) return;
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _aotWidth = prefs.getDouble(_prefAotWidth) ?? 400.0;
      _aotHeight = prefs.getDouble(_prefAotHeight) ?? 700.0;
      _aotEdge = prefs.getString(_prefAotEdge) ?? 'right';
      _aotAlign = prefs.getString(_prefAotAlign) ?? 'center';
      _aotOffsetX = prefs.getDouble(_prefAotOffsetX) ?? 0.0;
      _aotOffsetY = prefs.getDouble(_prefAotOffsetY) ?? 0.0;
    });
  }

  Future<void> _saveAlwaysOnTopPrefs() async {
    if (!Platform.isLinux) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefAotWidth, _aotWidth);
    await prefs.setDouble(_prefAotHeight, _aotHeight);
    await prefs.setString(_prefAotEdge, _aotEdge);
    await prefs.setString(_prefAotAlign, _aotAlign);
    await prefs.setDouble(_prefAotOffsetX, _aotOffsetX);
    await prefs.setDouble(_prefAotOffsetY, _aotOffsetY);
  }

  Future<void> _openAlwaysOnTopSettings() async {
    if (!Platform.isLinux) return;
    final widthCtrl = TextEditingController(text: _aotWidth.toStringAsFixed(0));
    final heightCtrl = TextEditingController(text: _aotHeight.toStringAsFixed(0));
    final offsetXCtrl = TextEditingController(text: _aotOffsetX.toStringAsFixed(0));
    final offsetYCtrl = TextEditingController(text: _aotOffsetY.toStringAsFixed(0));
    var edge = _aotEdge;
    var align = _aotAlign;

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Always-on-top layout'),
        content: StatefulBuilder(
          builder: (ctx, setLocalState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: widthCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Width (px)'),
              ),
              TextField(
                controller: heightCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Height (px)'),
              ),
              TextField(
                controller: offsetXCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Offset X (px)'),
              ),
              TextField(
                controller: offsetYCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Offset Y (px)'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: edge,
                decoration: const InputDecoration(labelText: 'Horizontal position'),
                items: const [
                  DropdownMenuItem(value: 'left', child: Text('Left')),
                  DropdownMenuItem(value: 'right', child: Text('Right')),
                ],
                onChanged: (val) => setLocalState(() => edge = val ?? 'right'),
              ),
              DropdownButtonFormField<String>(
                value: align,
                decoration: const InputDecoration(labelText: 'Vertical position'),
                items: const [
                  DropdownMenuItem(value: 'top', child: Text('Top')),
                  DropdownMenuItem(value: 'center', child: Text('Center')),
                  DropdownMenuItem(value: 'bottom', child: Text('Bottom')),
                ],
                onChanged: (val) => setLocalState(() => align = val ?? 'center'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final w = double.tryParse(widthCtrl.text.trim());
              final h = double.tryParse(heightCtrl.text.trim());
              final ox = double.tryParse(offsetXCtrl.text.trim());
              final oy = double.tryParse(offsetYCtrl.text.trim());
              setState(() {
                _aotWidth = (w == null || w <= 0) ? _aotWidth : w;
                _aotHeight = (h == null || h <= 0) ? _aotHeight : h;
                _aotOffsetX = ox ?? _aotOffsetX;
                _aotOffsetY = oy ?? _aotOffsetY;
                _aotEdge = edge;
                _aotAlign = align;
              });
              _saveAlwaysOnTopPrefs();
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _initHotkeyChannel() {
    if (!Platform.isLinux) return;
    _hotkeyChannel.setMethodCallHandler((call) async {
      debugPrint('Hotkey method received: ${call.method}');
      switch (call.method) {
        case 'minimize':
          try {
            await _minimizeToTray();
          } catch (ex) {
            debugPrint('Hotkey minimize failed: $ex');
          }
          return true;
        case 'toggleAlwaysOnTop':
          await windowManager.show();
          await windowManager.focus();
          await _toggleAlwaysOnTop();
          return true;
      }
      return false;
    });
  }

  Future<void> _toggleAlwaysOnTop() async {
    if (!Platform.isLinux) return;
    final next = !_isAlwaysOnTop;
    Rect? targetBounds;
    if (next) {
      final display = await screenRetriever.getPrimaryDisplay();
      final visibleSize = display.visibleSize ?? display.size;
      final visiblePosition = display.visiblePosition ?? Offset.zero;
      final width = visibleSize.width < _aotWidth ? visibleSize.width : _aotWidth;
      final height = visibleSize.height < _aotHeight ? visibleSize.height : _aotHeight;
      final x = _aotEdge == 'left'
          ? visiblePosition.dx
          : visiblePosition.dx + (visibleSize.width - width);
      final y = _aotAlign == 'top'
          ? visiblePosition.dy
          : _aotAlign == 'bottom'
              ? visiblePosition.dy + (visibleSize.height - height)
              : visiblePosition.dy + ((visibleSize.height - height) / 2);
      targetBounds = Rect.fromLTWH(x + _aotOffsetX, y + _aotOffsetY, width, height);
    }
    await windowManager.setAlwaysOnTop(next);
    if (next && targetBounds != null) {
      await windowManager.setBounds(targetBounds);
    }
    if (!mounted) return;
    setState(() => _isAlwaysOnTop = next);
  }

  Future<void> _minimizeWindow() async {
    if (!Platform.isLinux) return;
    await windowManager.minimize();
  }

  Future<void> _minimizeToTray() async {
    if (!Platform.isLinux) return;
    if (!_trayReady) {
      await _initTray();
    }
    debugPrint('Minimize to tray: hide window, skip taskbar');
    try {
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
    } catch (ex) {
      debugPrint('Minimize to tray failed: $ex');
    }
  }

  Future<void> _restoreFromTray() async {
    if (!Platform.isLinux) return;
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() {
    _restoreFromTray();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _restoreFromTray();
        break;
      case 'quit':
        _allowWindowClose = true;
        windowManager.close();
        break;
    }
  }

  @override
  void onWindowClose() async {
    if (!Platform.isLinux) return;
    if (_allowWindowClose) {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      return;
    }
    if (await windowManager.isPreventClose()) {
      await _minimizeToTray();
    }
  }

  Future<bool> _hasStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    return false;
  }

  Future<void> _checkPermissionThenLoad() async {
    if (!Platform.isAndroid) {
      setState(() => _permissionDenied = false);
      _loadSavedRoots();
      return;
    }
    if (await _hasStoragePermission()) { setState(() => _permissionDenied = false); _loadSavedRoots(); return; }
    final s = await Permission.storage.request();
    if (s.isGranted) { setState(() => _permissionDenied = false); _loadSavedRoots(); return; }
    setState(() => _permissionDenied = true);
  }

  Future<void> _openStorageSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await const MethodChannel('com.deadbush225.linia/widget').invokeMethod('openAllFilesSettings');
    } catch (_) { await openAppSettings(); }
  }

  Future<void> _recheckPermission() async {
    if (await _hasStoragePermission()) {
      setState(() => _permissionDenied = false);
      _loadSavedRoots();
    } else {
      setState(() => _permissionDenied = true);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Still no permission. Enable "Allow all files access" in Settings.'),
      ));
    }
  }

  Future<void> _persistProjectRoots() async {
    final prefs = await SharedPreferences.getInstance();
    _projectRoots = _normalizeProjectRoots(_projectRoots);
    await prefs.setStringList(_prefProjectRoots, _projectRoots);
    await prefs.setString(_prefActiveProjectKeys, jsonEncode(_activeProjectKeyByRoot));
    if (_projectRoot != null) {
      await prefs.setString(_prefActiveProjectRoot, _projectRoot!);
    }
  }

  Future<void> _loadSavedRoots() async {
    final prefs = await SharedPreferences.getInstance();
    var roots = prefs.getStringList(_prefProjectRoots) ?? <String>[];

    // One-time migration for older builds that stored a single root.
    final legacy = prefs.getString(_prefProjectRootLegacy);
    if (legacy != null && legacy.trim().isNotEmpty && !roots.contains(legacy.trim())) {
      roots = [...roots, legacy.trim()];
      await prefs.remove(_prefProjectRootLegacy);
    }

    roots = _normalizeProjectRoots(roots);

    final projectKeysRaw = prefs.getString(_prefActiveProjectKeys);
    Map<String, String> activeProjectMap = {};
    if (projectKeysRaw != null && projectKeysRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(projectKeysRaw);
        if (decoded is Map) {
          activeProjectMap = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      } catch (_) {}
    }

    final active = prefs.getString(_prefActiveProjectRoot);
    final idx = active == null ? 0 : roots.indexOf(active);
    setState(() {
      _projectRoots = roots;
      _activeProjectKeyByRoot = activeProjectMap;
      _activeRootIndex = roots.isEmpty ? 0 : (idx >= 0 ? idx : 0);
    });

    await prefs.setStringList(_prefProjectRoots, roots);

    if (_projectRoot != null) {
      final projects = await _projectFoldersUnderRoot(_projectRoot!);
      final savedKey = _activeProjectKeyByRoot[_projectRoot!];
      if (savedKey == null || !projects.contains(savedKey)) {
        if (projects.isNotEmpty) {
          _activeProjectKeyByRoot[_projectRoot!] = projects.first;
        }
      }
      setState(() => _currentRootProjects = projects);
    }

    if (_projectRoot != null) {
      await _refresh(_projectRoot);
    }
  }

  Future<void> _setActiveRoot(String root) async {
    final idx = _projectRoots.indexOf(root);
    if (idx < 0) return;
    setState(() => _activeRootIndex = idx);
    final projects = await _projectFoldersUnderRoot(root);
    if (projects.isNotEmpty && !_activeProjectKeyByRoot.containsKey(root)) {
      _activeProjectKeyByRoot[root] = projects.first;
    }
    setState(() => _currentRootProjects = projects);
    await _persistProjectRoots();
    await _refresh(root);
  }

  Future<void> _setActiveProjectKey(String key) async {
    final root = _projectRoot;
    if (root == null) return;
    _activeProjectKeyByRoot[root] = key;
    await _persistProjectRoots();
    await _refresh(root);
  }

  Future<void> _createProjectFolder(String name) async {
    final root = _projectRoot;
    if (root == null || name.trim().isEmpty) return;
    final safeName = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
    final dir = Directory('$root/$safeName');
    if (await dir.exists()) return;
    await dir.create(recursive: true);
    _activeProjectKeyByRoot[root] = safeName;
    await _persistProjectRoots();
    if (await SyncService.isConfigured) {
      await _syncProjectRegistry();
    }
    await _refresh(root);
  }

  Future<void> _deleteProjectFolder(String name) async {
    final root = _projectRoot;
    if (root == null || name.trim().isEmpty) return;
    final dir = Directory('$root/$name');
    if (!await dir.exists()) return;
    await dir.delete(recursive: true);
    if (_activeProjectKeyByRoot[root] == name) {
      _activeProjectKeyByRoot.remove(root);
    }
    await _persistProjectRoots();
    if (await SyncService.isConfigured) {
      await _syncProjectRegistry();
    }
    await _refresh(root);
  }

  Future<void> _removeProjectRootFromList(String root) async {
    if (!_projectRoots.contains(root)) return;
    setState(() {
      _projectRoots = _projectRoots.where((r) => r != root).toList();
      if (_activeRootIndex >= _projectRoots.length) {
        _activeRootIndex = _projectRoots.isEmpty ? 0 : _projectRoots.length - 1;
      }
    });
    await _persistProjectRoots();
    if (_projectRoot != null) {
      await _refresh(_projectRoot);
    } else {
      setState(() => _currentRootProjects = []);
    }
  }

  Future<void> _openProjectManagerSheet() async {
    final root = _projectRoot;
    if (root == null) return;
    final isContainer = await _isContainerRoot(root);
    final nameCtrl = TextEditingController();

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocalState) {
          final projects = _currentRootProjects;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Project management', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                if (isContainer) ...[
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'New project name',
                      filled: true,
                      fillColor: Color(0xFF252535),
                      border: OutlineInputBorder(borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) return;
                        await _createProjectFolder(name);
                        nameCtrl.clear();
                        if (mounted) {
                          setLocalState(() {});
                        }
                      },
                      icon: const Icon(Icons.create_new_folder),
                      label: const Text('Create project'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Existing projects', style: TextStyle(fontSize: 12, color: Colors.white54)),
                  const SizedBox(height: 6),
                  ...projects.map((p) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder, size: 18, color: Colors.white54),
                    title: Text(p, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Color(0xFFE84040)),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: ctx,
                          builder: (_) => AlertDialog(
                            title: const Text('Delete project?'),
                            content: Text('Delete folder "$p" and all its files?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                              FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE84040)),
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        await _deleteProjectFolder(p);
                        if (mounted) {
                          setLocalState(() {});
                        }
                      },
                    ),
                  )),
                ] else ...[
                  const Text(
                    'This root is a single project (not a container).\n'
                    'You can remove it from the list or pick a different root.',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE84040)),
                      onPressed: () async {
                        await _removeProjectRootFromList(root);
                        if (mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.remove_circle_outline),
                      label: const Text('Remove root from list'),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _pickFolder() async {
    if (!await _hasStoragePermission()) { await _openStorageSettings(); return; }
    final result = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Select Obsidian projects folder');
    if (result == null) return;

    final parentIdx = _projectRoots.indexWhere((root) => result.startsWith('$root/'));
    if (parentIdx >= 0) {
      setState(() => _activeRootIndex = parentIdx);
      await _persistProjectRoots();
      await _refresh(_projectRoots[parentIdx]);
      return;
    }

    final existingIdx = _projectRoots.indexOf(result);
    setState(() {
      if (existingIdx >= 0) {
        _activeRootIndex = existingIdx;
      } else {
        _projectRoots = [..._projectRoots, result];
        _activeRootIndex = _projectRoots.length - 1;
      }
    });
    await _persistProjectRoots();
    if (await SyncService.isConfigured) {
      // Publish actual project folders only; do not register the root itself as a project.
      await _syncProjectRegistry();
    }
    await _refresh(result);
  }

  Future<void> _refresh([String? root]) async {
    final r = root ?? _projectRoot;
    if (r == null) return;
    final projects = await _projectFoldersUnderRoot(r);
    if (projects.isNotEmpty) {
      final active = _activeProjectKeyByRoot[r];
      if (active == null || !projects.contains(active)) {
        _activeProjectKeyByRoot[r] = projects.first;
      }
    }
    setState(() => _currentRootProjects = projects);

    final scanRoot = _currentProjectPathForRoot(r);
    setState(() { _loading = true; _scanInfo = ''; });
    final tasks = await scanProjectFolder(scanRoot);
    final archived = await scanArchiveFolder(scanRoot);
    await _pushToWidget(tasks);
    setState(() {
      _tasks = tasks;
      _archivedTasks = archived;
      _loading = false;
      _scanInfo = '${tasks.length} active | ${archived.length} archived';
    });
  }

  Future<void> _pushToWidget(List<Task> tasks) async {
    if (!Platform.isAndroid) return;
    final limited = tasks.take(10).map((t) => {
      'title': t.title,
      'endDate': t.endDate ?? '',
      'colorIdx': t.colorIdx,
    }).toList();
    await HomeWidget.saveWidgetData<String>('tasks_json', jsonEncode(limited));
    await HomeWidget.updateWidget(androidName: 'GanttWidgetProvider');
    try { await const MethodChannel('com.deadbush225.linia/widget').invokeMethod('updateWidget'); } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _buildSyncPayloadForAllRoots() async {
    final payload = <Map<String, dynamic>>[];
    for (final root in _projectRoots) {
      final isContainer = await _isContainerRoot(root);
      final tasks = await scanProjectFolder(root);
      for (final t in tasks) {
        final key = _projectKeyForTaskPath(root, t.filePath, isContainerRoot: isContainer);
        payload.add({
          ...t.toJson(),
          'updatedAt': t.updatedAt > 0 ? t.updatedAt : DateTime.now().millisecondsSinceEpoch,
          'projectRoot': root,
          'projectKey': key,
        });
      }
    }
    return payload;
  }

  Future<Map<String, Task>> _scanLocalTasksByIdAllRoots() async {
    final map = <String, Task>{};
    for (final root in _projectRoots) {
      final tasks = await scanProjectFolder(root);
      for (final t in tasks) {
        map[t.id] = t;
      }
    }
    return map;
  }

  Future<void> _syncProjectRegistry() async {
    if (_projectRoots.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final localProjects = <Map<String, dynamic>>[];
    for (final root in _projectRoots) {
      final projectNames = await _projectFoldersUnderRoot(root);
      if (projectNames.isEmpty) {
        final key = _rootName(root);
        localProjects.add({
          'id': _projectDocId(root),
          'name': key,
          'projectKey': key,
          'projectRoot': root,
          'folderPath': root,
          'updatedAt': now,
        });
        continue;
      }

      for (final key in projectNames) {
        final projectPath = '$root/$key';
        localProjects.add({
          'id': _projectDocId(projectPath),
          'name': key,
          'projectKey': key,
          'projectRoot': root,
          'folderPath': projectPath,
          'updatedAt': now,
        });
      }
    }
    await SyncService.upsertProjects(localProjects);
  }

  Future<void> _pullRemoteProjectRegistry() async {
    if (_projectRoots.isEmpty) return;
    final remoteProjects = await SyncService.readRemoteProjects();
    final baseRoot = _projectRoot ?? _projectRoots.first;
    if (baseRoot == null) return;
    final baseRootName = _rootName(baseRoot).toLowerCase();

    for (final rp in remoteProjects) {
      final key = (rp['projectKey'] as String?)?.trim()
          ?? (rp['name'] as String?)?.trim()
          ?? '';
      final projectRoot = (rp['projectRoot'] as String?)?.trim() ?? '';
      final folderPath = (rp['folderPath'] as String?)?.trim() ?? '';
      final folderName = key.isNotEmpty
          ? key
          : (folderPath.isNotEmpty ? folderPath.split('/').last.trim() : '');
      if (folderName.isEmpty) continue;

      // Skip root alias entries (legacy docs where project == root folder).
      final folderNameLower = folderName.toLowerCase();
      final isRootAlias = folderNameLower == baseRootName ||
          (projectRoot.isNotEmpty && folderPath.isNotEmpty && projectRoot == folderPath);
      if (isRootAlias) continue;

      final targetDir = '$baseRoot/$folderName';
      await Directory(targetDir).create(recursive: true);
    }
  }

  String? _rootForRemoteTask(Map<String, dynamic> rt) {
    if (_projectRoots.isEmpty) return null;

    final explicitRoot = (rt['projectRoot'] as String?)?.trim();
    if (explicitRoot != null && explicitRoot.isNotEmpty && _projectRoots.contains(explicitRoot)) {
      return explicitRoot;
    }

    String? key = (rt['projectKey'] as String?)?.trim();
    key ??= (rt['project_folder'] as String?)?.split('/').last.trim();
    key ??= (rt['projectFolder'] as String?)?.split('/').last.trim();
    if (key != null && key.isNotEmpty) {
      final matches = _projectRoots.where((r) => _rootName(r) == key).toList();
      if (matches.length == 1) return matches.first;
    }

    return _projectRoot;
  }

  // ── Cloud sync ──────────────────────────────────────────────────────────────

  Future<void> _syncToCloud({bool silent = false}) async {
    if (!await SyncService.isConfigured) return;
    if (_projectRoots.isEmpty) return;
    if (!silent) {
      setState(() { _syncStatus = _SyncStatus.syncing; _syncInfo = ''; });
    }

    await _syncProjectRegistry();
    final payload = await _buildSyncPayloadForAllRoots();

    final result = await SyncService.sync(payload);

    if (!mounted) return;
    if (!result.ok) {
      if (!silent) {
        setState(() { _syncStatus = _SyncStatus.error; _syncInfo = result.error!; });
      }
      return;
    }

    // Apply pulled tasks (server is authoritative for these)
    await _pullRemoteProjectRegistry();
    if (result.pulledTasks.isNotEmpty || result.archivedIds.isNotEmpty || result.archivedTasks.isNotEmpty) {
      await _applyPulledTasks(result.pulledTasks, result.archivedIds, result.archivedTasks);
    }

    // Refresh local state after applying remote changes
    await _refresh();

    if (!mounted) return;
    if (!silent) {
      setState(() {
        _syncStatus = _SyncStatus.ok;
        _syncInfo = '↑${result.pushed} ↓${result.pulled}';
      });
    }

    if (!silent && result.hasConflicts) _showConflictDialog(result.conflicts);
  }

  Future<void> _autoSyncOnExit() async {
    if (!await SyncService.isConfigured || _projectRoots.isEmpty) return;
    await _syncToCloud(silent: true);
  }

  /// Write server-side tasks to local .md files and delete archived ones.
  /// For each pulled task, if a matching local file exists and server is newer,
  /// update it; otherwise create a new file in the project root.
  Future<void> _applyPulledTasks(
    List<Map<String, dynamic>> pulled,
    List<String> archivedIds,
    List<Map<String, dynamic>> archivedTasks,
  ) async {
    if (_projectRoot == null) return;

    // Build id → filePath map from all configured roots.
    final localById = await _scanLocalTasksByIdAllRoots();

    // Move archived tasks into local archive folder.
    for (final id in archivedIds) {
      final local = localById[id];
      if (local != null) {
        final localRoot = _projectRootForFilePath(local.filePath) ?? _projectRoot;
        if (localRoot == null) continue;
        await _archiveFile(local.filePath, localRoot);
      }
    }

    // Write / update pulled tasks
    for (final rt in pulled) {
      final id           = rt['id'] as String? ?? '';
      final serverTs     = (rt['updatedAt'] as int?) ?? 0;
      final title        = rt['title'] as String? ?? id;
      final noteBody     = rt['noteBody'] as String? ?? '';
      final status       = rt['status'] as String? ?? 'todo';
      final priority     = rt['priority'] as String? ?? 'medium';
      final startDate    = rt['startDate'] as String?;
      final endDate      = rt['endDate'] as String?;
      // rawFrontmatter: full .md file content pushed by the originating client
      final rawFm        = rt['rawFrontmatter'] as String?;
      final targetRoot   = _rootForRemoteTask(rt);
      if (targetRoot == null) continue;

      final projectFolderField = (rt['project_folder'] as String?)?.trim() ?? '';
      final remoteProjectKey = (rt['projectKey'] as String?)?.trim()
          ?? (projectFolderField.isNotEmpty ? projectFolderField.split('/').last.trim() : '');
      final targetDir = remoteProjectKey.isNotEmpty &&
              _rootName(targetRoot).toLowerCase() != remoteProjectKey.toLowerCase()
          ? '$targetRoot/$remoteProjectKey'
          : targetRoot;
      await Directory(targetDir).create(recursive: true);

      final local = localById[id];
      final localInTargetRoot = local != null && local.filePath.startsWith('$targetDir/');

      if (localInTargetRoot) {
        // Only overwrite if server is strictly newer
        if (serverTs <= local.updatedAt) continue;

        if (rawFm != null && rawFm.startsWith('---')) {
          // Use the verbatim file the other client pushed — preserves all fields
          // Stamp the correct updated_at in case the raw content has a stale value
          var content = rawFm.replaceAllMapped(
            RegExp(r'^(updated_at:\s*).*$', multiLine: true),
            (_) => 'updated_at: $serverTs',
          );
          if (!content.contains(RegExp(r'^updated_at:', multiLine: true))) {
            content = content.replaceFirst(RegExp(r'\n---\n'), '\nupdated_at: $serverTs\n---\n');
          }
          await File(local.filePath).writeAsString(content);
        } else {
          // Fallback: patch individual fields for tasks without rawFrontmatter
          await _writeTaskBody(local.filePath, noteBody);
          await _writeTaskField(local.filePath, {
            'title':      title,
            'status':     status,
            'priority':   priority,
            'startDate':  startDate ?? '',
            'endDate':    endDate ?? '',
            'updated_at': serverTs.toString(),
          });
        }
      } else {
        // New task from server — create a local file
        final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
        final filePath = '$targetDir/$safeName.md';

        String content;
        if (rawFm != null && rawFm.startsWith('---')) {
          // Use the verbatim content — preserves every field from the source client
          content = rawFm.replaceAllMapped(
            RegExp(r'^(updated_at:\s*).*$', multiLine: true),
            (_) => 'updated_at: $serverTs',
          );
          if (!content.contains(RegExp(r'^updated_at:', multiLine: true))) {
            content = content.replaceFirst(RegExp(r'\n---\n'), '\nupdated_at: $serverTs\n---\n');
          }
        } else {
          // Fallback for tasks that didn't include rawFrontmatter (older clients)
          content = _buildFrontmatter(
            id: id, title: title, status: status, priority: priority,
            noteBody: noteBody,
            startDate: startDate, endDate: endDate,
            updatedAt: serverTs,
          );
        }
        await File(filePath).writeAsString(content);
      }
    }

    // Materialize archived tasks from server so users can view/unarchive locally.
    for (final rt in archivedTasks) {
      final id = rt['id'] as String? ?? '';
      if (id.isEmpty) continue;

      final targetRoot = _rootForRemoteTask(rt);
      if (targetRoot == null) continue;

      final title = rt['title'] as String? ?? id;
      final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
      final archivePath = '$targetRoot/archive/$safeName.md';
      final rawFm = rt['rawFrontmatter'] as String?;
      final updatedAt = (rt['updatedAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch;

      String content;
      if (rawFm != null && rawFm.startsWith('---')) {
        content = rawFm.replaceAllMapped(
          RegExp(r'^(updated_at:\s*).*$', multiLine: true),
          (_) => 'updated_at: $updatedAt',
        );
      } else {
        content = _buildFrontmatter(
          id: id,
          title: title,
          status: rt['status'] as String? ?? 'done',
          priority: rt['priority'] as String? ?? 'medium',
          noteBody: rt['noteBody'] as String? ?? '',
          startDate: rt['startDate'] as String?,
          endDate: rt['endDate'] as String?,
          updatedAt: updatedAt,
        );
      }
      await File(archivePath).create(recursive: true);
      await File(archivePath).writeAsString(content);
    }
  }

  void _showConflictDialog(List<SyncConflict> conflicts) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        title: Row(children: [
          const Icon(Icons.sync_problem, color: Color(0xFFF7926A)),
          const SizedBox(width: 8),
          Text('${conflicts.length} sync conflict${conflicts.length > 1 ? 's' : ''}'),
        ]),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('The server has newer versions of these tasks. '
                'Accept server versions?',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            ...conflicts.map((c) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                const Icon(Icons.circle, size: 6, color: Color(0xFFF7926A)),
                const SizedBox(width: 8),
                Expanded(child: Text(c.serverTask['title'] ?? c.serverTask['id'] ?? '?',
                    style: const TextStyle(fontSize: 13))),
              ]),
            )),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // Force-push local versions so the server (and other clients) adopt ours
              _keepMineConflicts(conflicts);
            },
            child: const Text('Keep mine'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF7C6AF7)),
            onPressed: () {
              Navigator.pop(context);
              // Apply server versions to local markdown files
              _applyServerConflicts(conflicts);
            },
            child: const Text('Accept server'),
          ),
        ],
      ),
    );
  }

  Future<void> _applyServerConflicts(List<SyncConflict> conflicts) async {
    final localById = await _scanLocalTasksByIdAllRoots();
    for (final c in conflicts) {
      // Find matching local task by id
      final local = localById[c.serverTask['id'] as String? ?? ''];
      if (local == null) continue;

      final serverTs  = (c.serverTask['updatedAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch;
      final rawFm     = c.serverTask['rawFrontmatter'] as String?;

      if (rawFm != null && rawFm.startsWith('---')) {
        // Write the verbatim file content from the server — preserves all fields
        var content = rawFm.replaceAllMapped(
          RegExp(r'^(updated_at:\s*).*$', multiLine: true),
          (_) => 'updated_at: $serverTs',
        );
        if (!content.contains(RegExp(r'^updated_at:', multiLine: true))) {
          content = content.replaceFirst(RegExp(r'\n---\n'), '\nupdated_at: $serverTs\n---\n');
        }
        await File(local.filePath).writeAsString(content);
      } else {
        // Fallback: patch known fields when rawFrontmatter isn't available
        await _writeTaskBody(local.filePath, c.serverTask['noteBody'] as String? ?? local.noteBody);
        await _writeTaskField(local.filePath, {
          'title':      c.serverTask['title'] as String? ?? local.title,
          'status':     c.serverTask['status'] as String? ?? local.status,
          'priority':   c.serverTask['priority'] as String? ?? local.priority,
          'startDate':  (c.serverTask['startDate'] as String?) ?? local.startDate ?? '',
          'endDate':    (c.serverTask['endDate'] as String?) ?? local.endDate ?? '',
          'updated_at': serverTs.toString(),
        });
      }
    }
    await _refresh();
  }

  /// Force-push local versions of conflicting tasks so the server (and all
  /// other clients like the Obsidian plugin) adopt the Flutter user's version.
  ///
  /// Strategy: bump each task's `updated_at` to `serverTs + 1` so it is
  /// strictly newer than the server copy, guaranteeing the push wins.
  Future<void> _keepMineConflicts(List<SyncConflict> conflicts) async {
    if (!await SyncService.isConfigured) return;

    final localById = await _scanLocalTasksByIdAllRoots();
    final failed = <String>[];

    for (final c in conflicts) {
      final local = localById[c.serverTask['id'] as String? ?? ''];
      if (local == null) continue;

      // Use serverTs + 1 so our timestamp beats the server's current value
      final serverTs    = (c.serverTask['updatedAt'] as int?) ?? 0;
      final winningTs   = serverTs + 1;

      // Persist the winning timestamp to the local file
      await _writeTaskField(local.filePath, {
        'updated_at': winningTs.toString(),
      });

      // Force-push with the winning timestamp — server will overwrite its copy.
      final taskRoot = _projectRootForFilePath(local.filePath) ?? _projectRoot ?? File(local.filePath).parent.path;
      final err = await SyncService.forcePushOne({
        ...local.toJson(),
        'projectRoot': taskRoot,
        'projectKey': _rootName(taskRoot),
        'updatedAt': winningTs,
      });
      if (err != null) {
        failed.add(local.title.isNotEmpty ? local.title : local.id);
      }
    }

    await _refresh();
    if (failed.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Keep mine failed for ${failed.length} task(s). Please sync again.')),
      );
    }
  }

  void _openSyncSetup() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _SyncSetupSheet(
        onSaved: () { Navigator.pop(context); _syncToCloud(); },
      ),
    );
  }

  Future<void> _checkForUpdates() async {
    if (_checkingUpdate) return;
    _checkingUpdate = true;
    try {
      final repo = await _loadUpdateRepo();
      if (repo == null) return;

      final uri = Uri.parse('https://api.github.com/repos/$repo/releases/latest');
      final resp = await http.get(uri, headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'Linia',
      });
      if (resp.statusCode != 200) return;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String? ?? '').trim();
      final url = (data['html_url'] as String? ?? '').trim();
      final name = (data['name'] as String? ?? '').trim();
      final body = (data['body'] as String? ?? '').trim();
      if (tag.isEmpty) return;

      final info = await PackageInfo.fromPlatform();
      final current = info.version.trim();
      if (!_isNewerVersion(current, tag)) return;

      if (!mounted) return;
      _showUpdateDialog(
        latestTag: tag,
        releaseName: name,
        releaseUrl: url,
        releaseNotes: body,
      );
    } catch (_) {
      // Ignore update errors to avoid blocking app startup.
    } finally {
      _checkingUpdate = false;
    }
  }

  void _showUpdateDialog({
    required String latestTag,
    required String releaseName,
    required String releaseUrl,
    required String releaseNotes,
  }) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Update available'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('New version: $latestTag'),
                if (releaseName.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(releaseName, style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
                if (releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(releaseNotes, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          if (releaseUrl.isNotEmpty)
            FilledButton(
              onPressed: () async {
                final uri = Uri.tryParse(releaseUrl);
                if (uri != null) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
                if (mounted) Navigator.pop(context);
              },
              child: const Text('Open release'),
            ),
        ],
      ),
    );
  }

  /// Persist changes to the markdown file and reload task in state.
  Future<void> _saveTask(Task updated) async {
    final taskRoot = _projectRootForFilePath(updated.filePath) ?? _projectRoot ?? File(updated.filePath).parent.path;
    final projectKey = _activeProjectKeyByRoot[_projectRoot ?? ''] ?? _rootName(taskRoot);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _writeTaskBody(updated.filePath, updated.noteBody);
    await _writeTaskField(updated.filePath, {
      'title':      updated.title,
      'status':     updated.status,
      'priority':   updated.priority,
      'startDate':  updated.startDate ?? '',
      'endDate':    updated.endDate ?? '',
      'updated_at': now.toString(),   // explicit ts so file and push stay in sync
    });
    await _refresh();
    // Push the single changed task immediately if sync is configured
    if (await SyncService.isConfigured) {
      SyncService.pushOne({
        ...updated.toJson(),
        'projectRoot': taskRoot,
        'projectKey': projectKey,
        'updatedAt': now,
      });
    }
  }

  Future<void> _archiveTask(Task t) async {
    if (_projectRoot == null) return;
    final projectPath = _currentProjectPathForRoot(_projectRoot!);
    final projectKey = _activeProjectKeyByRoot[_projectRoot!] ?? _rootName(projectPath);
    final rawFrontmatter = await File(t.filePath).readAsString();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _archiveFile(t.filePath, projectPath);
    await _refresh();
    if (await SyncService.isConfigured) {
      final err = await SyncService.archiveRemote({
        ...t.toJson(),
        'projectRoot': _projectRoot,
        'projectKey': projectKey,
        'rawFrontmatter': rawFrontmatter,
        'updatedAt': now,
      });
      if (err != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Archived locally, but cloud archive failed: $err')),
        );
      }
    }
  }

  Future<void> _unarchiveTask(Task t) async {
    if (_projectRoot == null) return;
    final projectPath = _currentProjectPathForRoot(_projectRoot!);
    final projectKey = _activeProjectKeyByRoot[_projectRoot!] ?? _rootName(projectPath);

    final file = File(t.filePath);
    if (!await file.exists()) return;

    final rawFrontmatter = await file.readAsString();
    final fileName = t.filePath.split('/').last;
    var dest = '$projectPath/$fileName';
    if (await File(dest).exists()) {
      dest = '$projectPath/${fileName.replaceAll('.md', '')}-${DateTime.now().millisecondsSinceEpoch}.md';
    }

    await file.rename(dest);
    await _refresh();

    if (await SyncService.isConfigured) {
      await SyncService.unarchiveRemote({
        ...t.toJson(),
        'projectRoot': _projectRoot,
        'projectKey': projectKey,
        'rawFrontmatter': rawFrontmatter,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  void _openTaskSheet(Task t) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _TaskEditSheet(
        task: t,
        onSave: (updated) { Navigator.pop(context); _saveTask(updated); },
        onArchive: () { Navigator.pop(context); _archiveTask(t); },
      ),
    );
  }

  /// Create a brand-new markdown task file in the project root.
  Future<void> _createTask({
    required String title,
    required String noteBody,
    required String status,
    required String priority,
    String? startDate,
    String? endDate,
  }) async {
    if (_projectRoot == null) return;
    final projectPath = _currentProjectPathForRoot(_projectRoot!);
    final projectKey = _activeProjectKeyByRoot[_projectRoot!] ?? _rootName(projectPath);
    await Directory(projectPath).create(recursive: true);
    final id       = _nanoid();
    final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
    final filePath = '$projectPath/$safeName.md';
    final now      = DateTime.now().millisecondsSinceEpoch;
    final content  = _buildFrontmatter(
      id: id, title: title, status: status, priority: priority,
      noteBody: noteBody,
      startDate: startDate, endDate: endDate,
      updatedAt: now,
    );
    await File(filePath).writeAsString(content);
    await _refresh();
    if (await SyncService.isConfigured) {
      SyncService.pushOne({
        'id': id, 'title': title, 'noteBody': noteBody, 'status': status, 'priority': priority,
        'startDate': startDate, 'endDate': endDate,
        'projectRoot': _projectRoot,
        'projectKey': projectKey,
        'rawFrontmatter': content,
        'updatedAt': now,
      });
    }
  }

  Future<void> _openNewTaskSheet() async {
    if (_projectRoot == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a project folder first')),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final defaultTemplate = prefs.getString(kPrefDefaultNoteTemplate)
        ?? '## Description\n\n## Notes';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _NewTaskSheet(
        defaultNoteBody: defaultTemplate,
        onCreate: (title, noteBody, status, priority, start, end) {
          Navigator.pop(context);
          _createTask(
            title: title, noteBody: noteBody, status: status, priority: priority,
            startDate: start, endDate: end,
          );
        },
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SettingsScreen(onSignOut: _signOutAndSwitchAccount),
    ));
  }

  Future<void> _signOutAndSwitchAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This will sign you out of cloud sync on this device so you can switch accounts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await SyncService.clearCredentials();
    if (!mounted) return;
    setState(() {
      _syncStatus = _SyncStatus.idle;
      _syncInfo = '';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Signed out. You can now switch accounts.')),
    );
  }

  Future<void> _openAboutDialog() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('About Linia'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version ${info.version} (${info.buildNumber})'),
            const SizedBox(height: 8),
            const Text('Auto-updates are delivered from GitHub Releases.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              await _runUpdateFlow();
            },
            icon: const Icon(Icons.system_update_alt),
            label: const Text('Check & download'),
          ),
        ],
      ),
    );
  }

  Future<void> _runUpdateFlow() async {
    final repo = await _loadUpdateRepo();
    if (repo == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Update repo not configured in this build.')),
      );
      return;
    }

    _showBlockingDialog('Checking for updates…');
    _ReleaseInfo release;
    try {
      release = await _fetchLatestRelease(repo);
    } catch (_) {
      _hideBlockingDialog();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Update check failed.')),
      );
      return;
    }
    _hideBlockingDialog();

    final info = await PackageInfo.fromPlatform();
    final current = info.version.trim();
    if (!_isNewerVersion(current, release.tag)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are up to date.')),
      );
      return;
    }

    final asset = _pickAssetForPlatform(release.assets);
    if (asset == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No matching update asset found.')),
      );
      return;
    }

    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Update available'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('New version: ${release.tag}'),
              if (release.name.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(release.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
              if (release.body.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(release.body, style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ],
              const SizedBox(height: 10),
              Text('Package: ${asset.name}', style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    _showBlockingDialog('Downloading update…');
    File downloaded;
    try {
      downloaded = await _downloadReleaseAsset(asset);
    } catch (_) {
      _hideBlockingDialog();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Download failed.')),
      );
      return;
    }
    _hideBlockingDialog();

    try {
      if (Platform.isLinux) {
        _showBlockingDialog('Installing update…');
        await _installLinuxUpdate(downloaded);
        _hideBlockingDialog();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Update installed. Please restart Linia.')),
        );
      } else if (Platform.isAndroid) {
        final result = await OpenFilex.open(downloaded.path);
        if (!mounted) return;
        if (result.type == ResultType.error) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to launch installer.')),
          );
        }
      }
    } catch (_) {
      _hideBlockingDialog();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Update install failed.')),
      );
    }
  }

  void _showBlockingDialog(String message) {
    if (!mounted) return;
    if (_blockingDialogOpen) {
      _hideBlockingDialog();
    }
    _blockingDialogOpen = true;
    showDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }

  void _hideBlockingDialog() {
    if (!mounted || !_blockingDialogOpen) return;
    Navigator.of(context, rootNavigator: true).maybePop();
    _blockingDialogOpen = false;
  }

  Future<File> _downloadReleaseAsset(_ReleaseAsset asset) async {
    final tempDir = await getTemporaryDirectory();
    final outFile = File('${tempDir.path}/${asset.name}');
    final resp = await http.get(Uri.parse(asset.url));
    if (resp.statusCode != 200) {
      throw Exception('Download failed (${resp.statusCode})');
    }
    await outFile.writeAsBytes(resp.bodyBytes, flush: true);
    return outFile;
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }
    await for (final entity in source.list(recursive: false)) {
      final name = entity.path.split('/').last;
      final targetPath = '${destination.path}/$name';
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        await entity.copy(targetPath);
      }
    }
  }

  Future<void> _installLinuxUpdate(File tarball) async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw Exception('HOME not set');
    }
    final installDir = Directory('$home/.local/share/linia');
    final tempDir = await Directory.systemTemp.createTemp('linia-update-');
    final extractDir = Directory('${tempDir.path}/extract');
    await extractDir.create(recursive: true);
    final result = await Process.run(
      'tar',
      ['-xzf', tarball.path, '-C', extractDir.path],
    );
    if (result.exitCode != 0) {
      await tempDir.delete(recursive: true);
      throw Exception('tar failed: ${result.stderr}');
    }

    final entries = await extractDir.list().toList();
    final dirs = entries.whereType<Directory>().toList();
    final bundleRoot = (dirs.length == 1 && entries.every((e) => e is Directory))
        ? dirs.first
        : extractDir;

    if (await installDir.exists()) {
      await installDir.delete(recursive: true);
    }
    await installDir.create(recursive: true);
    await _copyDirectory(bundleRoot, installDir);
    await tempDir.delete(recursive: true);
  }

  @override
  Widget build(BuildContext context) {
    final showTabs = _projectRoot != null && !_permissionDenied;
    final scaffold = Scaffold(
      appBar: AppBar(
        toolbarHeight: 52,
        titleSpacing: 12,
        title: Row(
          children: [
            const Text('Linia', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            if (_projectRoot != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _activeProjectKeyByRoot[_projectRoot!] ?? _rootName(_projectRoot!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (_projectRoot != null && _currentRootProjects.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Quick switch project',
              onSelected: _setActiveProjectKey,
              icon: const Icon(Icons.swap_horiz, size: 20),
              itemBuilder: (_) => _currentRootProjects.map((projectName) {
                final selected = projectName == _activeProjectKeyByRoot[_projectRoot!];
                return PopupMenuItem<String>(
                  value: projectName,
                  child: Row(children: [
                    Icon(selected ? Icons.check_circle : Icons.folder, size: 16, color: selected ? const Color(0xFF7C6AF7) : Colors.white54),
                    const SizedBox(width: 8),
                    Expanded(child: Text(projectName, overflow: TextOverflow.ellipsis)),
                  ]),
                );
              }).toList(),
            ),
          if (_projectRoot != null)
            IconButton(
              icon: const Icon(Icons.tune, size: 20),
              tooltip: 'Manage projects',
              onPressed: _openProjectManagerSheet,
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            icon: const Icon(Icons.settings, size: 20),
            tooltip: 'Settings',
            onPressed: _openSettings,
            visualDensity: VisualDensity.compact,
          ),
          if (_syncStatus != _SyncStatus.syncing)
            IconButton(
              icon: const Icon(Icons.logout, size: 20),
              tooltip: 'Sign out / switch account',
              onPressed: () async {
                if (await SyncService.isConfigured) {
                  _signOutAndSwitchAccount();
                } else {
                  _openSyncSetup();
                }
              },
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            icon: const Icon(Icons.info_outline, size: 20),
            tooltip: 'About',
            onPressed: _openAboutDialog,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.folder_open, size: 20),
            tooltip: 'Add project folder',
            onPressed: _pickFolder,
            visualDensity: VisualDensity.compact,
          ),
          if (_projectRoot != null)
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: 'Refresh',
              onPressed: () => _refresh(),
              visualDensity: VisualDensity.compact,
            ),
          if (Platform.isLinux)
            Tooltip(
              message: _isAlwaysOnTop
                  ? 'Disable always on top (Ctrl+Shift+Y)\nLong-press to edit layout'
                  : 'Enable always on top (Ctrl+Shift+Y)\nLong-press to edit layout',
              child: InkWell(
                onTap: _toggleAlwaysOnTop,
                onLongPress: _openAlwaysOnTopSettings,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Icon(
                    _isAlwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 20,
                  ),
                ),
              ),
            ),
          // Sync button — shows status icon + opens setup if not configured
          _SyncButton(
            status: _syncStatus,
            info: _syncInfo,
            onTap: () async {
              if (await SyncService.isConfigured) {
                _syncToCloud();
              } else {
                _openSyncSetup();
              }
            },
            onLongPress: _openSyncSetup,
          ),
        ],
        bottom: showTabs
            ? PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: TabBar(
                    controller: _tabs,
                    isScrollable: true,
                    indicatorColor: const Color(0xFF7C6AF7),
                    labelColor: const Color(0xFF7C6AF7),
                    unselectedLabelColor: Colors.white38,
                    indicatorSize: TabBarIndicatorSize.label,
                    tabs: const [
                      Tab(icon: Icon(Icons.list, size: 18), height: 34),
                      Tab(icon: Icon(Icons.view_column, size: 18), height: 34),
                      Tab(icon: Icon(Icons.bar_chart, size: 18), height: 34),
                      Tab(icon: Icon(Icons.archive_outlined, size: 18), height: 34),
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: _buildBody(),
      floatingActionButton: _projectRoot != null && !_permissionDenied
          ? FloatingActionButton(
              onPressed: _openNewTaskSheet,
              backgroundColor: const Color(0xFF7C6AF7),
              tooltip: 'New task',
              child: const Icon(Icons.add),
            )
          : null,
    );

    if (!Platform.isLinux) return scaffold;

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(
          LogicalKeyboardKey.keyM,
          control: true,
          shift: true,
        ): _MinimizeWindowIntent(),
        SingleActivator(
          LogicalKeyboardKey.keyT,
          control: true,
          shift: true,
        ): _ToggleAlwaysOnTopIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _MinimizeWindowIntent: CallbackAction<_MinimizeWindowIntent>(
            onInvoke: (_) {
              _minimizeWindow();
              return null;
            },
          ),
          _ToggleAlwaysOnTopIntent: CallbackAction<_ToggleAlwaysOnTopIntent>(
            onInvoke: (_) {
              _toggleAlwaysOnTop();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: scaffold),
      ),
    );
  }

  Widget _buildBody() {
    if (_permissionDenied) return _PermissionGate(onOpenSettings: _openStorageSettings, onRecheck: _recheckPermission);
    if (_projectRoot == null) return _FolderPicker(onPick: _pickFolder);
    if (_loading) return const Center(child: CircularProgressIndicator());

    final body = TabBarView(
      controller: _tabs,
      children: [
        _ListView(tasks: _tasks, projectRoot: _projectRoot!, scanInfo: _scanInfo, onTap: _openTaskSheet, onRefresh: _refresh),
        _KanbanView(tasks: _tasks, onTap: _openTaskSheet),
        _GanttView(tasks: _tasks, onTap: _openTaskSheet),
        _ArchiveView(tasks: _archivedTasks, onUnarchive: _unarchiveTask),
      ],
    );
    return body;
  }
}

// ─── Permission gate ──────────────────────────────────────────────────────────
class _PermissionGate extends StatelessWidget {
  final VoidCallback onOpenSettings, onRecheck;
  const _PermissionGate({required this.onOpenSettings, required this.onRecheck});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock, size: 72, color: Color(0xFFF7926A)),
        const SizedBox(height: 20),
        const Text('Storage permission required', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        const Text(
          'On Android 11+, this app needs "All Files Access" to read your Obsidian vault.\n\n'
          '1. Tap "Open Settings"\n2. Enable "Allow all files access"\n3. Return and tap "I\'ve granted it"',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, height: 1.6)),
        const SizedBox(height: 28),
        FilledButton.icon(onPressed: onOpenSettings, icon: const Icon(Icons.settings), label: const Text('Open Settings')),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: onRecheck, icon: const Icon(Icons.check_circle_outline), label: const Text("I've granted it")),
      ]),
    ),
  );
}

// ─── Folder picker splash ─────────────────────────────────────────────────────
class _FolderPicker extends StatelessWidget {
  final VoidCallback onPick;
  const _FolderPicker({required this.onPick});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.folder_open, size: 72, color: Color(0xFF7C6AF7)),
      const SizedBox(height: 20),
      const Text('No folder selected', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text('Choose your Obsidian projects folder', style: TextStyle(color: Colors.white54)),
      const SizedBox(height: 28),
      FilledButton.icon(onPressed: onPick, icon: const Icon(Icons.folder_open), label: const Text('Select folder')),
    ]),
  );
}

// ─── Folder banner ────────────────────────────────────────────────────────────
class _FolderBanner extends StatelessWidget {
  final String path;
  final String info;
  const _FolderBanner({required this.path, this.info = ''});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    color: const Color(0xFF13131F),
    child: Row(children: [
      const Icon(Icons.folder, color: Color(0xFF7C6AF7), size: 14),
      const SizedBox(width: 6),
      Expanded(child: Text(path, style: const TextStyle(fontSize: 11, color: Colors.white38), overflow: TextOverflow.ellipsis)),
      if (info.isNotEmpty) Text(info, style: const TextStyle(fontSize: 11, color: Color(0xFF7C6AF7))),
    ]),
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// ─── LIST VIEW ───────────────────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════════
class _ListView extends StatelessWidget {
  final List<Task> tasks;
  final String projectRoot, scanInfo;
  final void Function(Task) onTap;
  final Future<void> Function() onRefresh;
  const _ListView({required this.tasks, required this.projectRoot, required this.scanInfo, required this.onTap, required this.onRefresh});

  @override
  Widget build(BuildContext context) => Column(children: [
    _FolderBanner(path: projectRoot, info: scanInfo),
    Expanded(
      child: RefreshIndicator(
        onRefresh: onRefresh,
        child: tasks.isEmpty
          ? const Center(child: Text('No tasks found\n\nFiles need --- frontmatter ---', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, height: 1.6)))
          : ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: tasks.length,
              itemBuilder: (_, i) => _TaskCard(task: tasks[i], onTap: onTap)),
      ),
    ),
  ]);
}

class _ArchiveView extends StatelessWidget {
  final List<Task> tasks;
  final Future<void> Function(Task) onUnarchive;
  const _ArchiveView({required this.tasks, required this.onUnarchive});

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return const Center(
        child: Text('No archived tasks', style: TextStyle(color: Colors.white38)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: tasks.length,
      itemBuilder: (_, i) {
        final task = tasks[i];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 5),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            leading: Icon(Icons.archive, color: task.color),
            title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: task.endDate == null
                ? const Text('Archived')
                : Text('Archived task | due ${task.endDate}'),
            trailing: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF4CAF50),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => onUnarchive(task),
              icon: const Icon(Icons.unarchive, size: 16),
              label: const Text('Unarchive'),
            ),
          ),
        );
      },
    );
  }
}

class _LinePreviewMarkdownEditor extends StatefulWidget {
  final String initialText;
  final String hintText;
  final ValueChanged<String> onChanged;

  const _LinePreviewMarkdownEditor({
    required this.initialText,
    required this.hintText,
    required this.onChanged,
  });

  @override
  State<_LinePreviewMarkdownEditor> createState() => _LinePreviewMarkdownEditorState();
}

class _LinePreviewMarkdownEditorState extends State<_LinePreviewMarkdownEditor> {
  late List<String> _lines;
  final TextEditingController _lineCtrl = TextEditingController();
  final FocusNode _lineFocus = FocusNode();
  int _activeLine = -1;
  int _lastSelectedLine = -1;

  @override
  void initState() {
    super.initState();
    _lines = _splitLines(widget.initialText);
    _lineFocus.addListener(_onLineFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _LinePreviewMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialText != widget.initialText) {
      _lines = _splitLines(widget.initialText);
      if (_activeLine >= _lines.length) {
        _activeLine = _lines.isEmpty ? -1 : _lines.length - 1;
      }
      if (_activeLine >= 0 && _activeLine < _lines.length) {
        _lineCtrl.value = TextEditingValue(
          text: _lines[_activeLine],
          selection: TextSelection.collapsed(offset: _lines[_activeLine].length),
        );
      }
    }
  }

  @override
  void dispose() {
    _lineFocus.removeListener(_onLineFocusChanged);
    _lineCtrl.dispose();
    _lineFocus.dispose();
    super.dispose();
  }

  void _onLineFocusChanged() {
    if (!_lineFocus.hasFocus) {
      _commitActiveLineAndClearSelection();
    }
  }

  List<String> _splitLines(String text) {
    if (text.isEmpty) return [''];
    return text.replaceAll('\r\n', '\n').split('\n');
  }

  void _emit() {
    widget.onChanged(_lines.join('\n'));
  }

  void _startEditingLine(int lineIndex) {
    setState(() {
      _activeLine = lineIndex;
      _lastSelectedLine = lineIndex;
      _lineCtrl.value = TextEditingValue(
        text: _lines[lineIndex],
        selection: TextSelection.collapsed(offset: _lines[lineIndex].length),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _lineFocus.requestFocus();
    });
  }

  void _stopEditingLine() {
    _commitActiveLineAndClearSelection();
    _lineFocus.unfocus();
  }

  void _commitActiveLineAndClearSelection() {
    if (_activeLine < 0 || _activeLine >= _lines.length) return;

    if (_activeLine >= 0 && _activeLine < _lines.length) {
      _lines[_activeLine] = _lineCtrl.text;
      _emit();
    }
    if (mounted) {
      setState(() => _activeLine = -1);
    } else {
      _activeLine = -1;
    }
  }

  bool _deleteActiveLineIfPossible() {
    if (_activeLine < 0 || _activeLine >= _lines.length) return false;
    if (_lineCtrl.text.isNotEmpty) return false;

    setState(() {
      if (_lines.length == 1) {
        _lines[0] = '';
        _lineCtrl.value = const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );
        _emit();
        return;
      }

      _lines.removeAt(_activeLine);
      final prevLine = (_activeLine - 1).clamp(0, _lines.length - 1);
      _activeLine = prevLine;
      _lineCtrl.value = TextEditingValue(
        text: _lines[prevLine],
        selection: TextSelection.collapsed(offset: _lines[prevLine].length),
      );
      _emit();
    });
    return true;
  }

  KeyEventResult _onEditingKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    return _deleteActiveLineIfPossible() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _applyEditingValue(String value) {
    if (_activeLine < 0 || _activeLine >= _lines.length) return;
    if (!value.contains('\n')) {
      _lines[_activeLine] = value;
      _emit();
      return;
    }

    final parts = value.split('\n');
    _lines[_activeLine] = parts.first;
    if (parts.length > 1) {
      _lines.insertAll(_activeLine + 1, parts.skip(1));
      _activeLine = (_activeLine + parts.length - 1).clamp(0, _lines.length - 1);
      _lineCtrl.value = TextEditingValue(
        text: _lines[_activeLine],
        selection: TextSelection.collapsed(offset: _lines[_activeLine].length),
      );
    }
    _emit();
    setState(() {});
  }

  bool _isCheckboxLine(String line) {
    return RegExp(r'^\s*-\s*\[( |x|X)\]\s+').hasMatch(line);
  }

  ({bool checked, String text}) _parseCheckboxLine(String line) {
    final m = RegExp(r'^(\s*-\s*\[)( |x|X)(\]\s+)(.*)$').firstMatch(line);
    if (m == null) return (checked: false, text: line);
    final checked = (m.group(2) ?? ' ').toLowerCase() == 'x';
    return (checked: checked, text: m.group(4) ?? '');
  }

  void _toggleCheckbox(int lineIndex, bool checked) {
    final line = _lines[lineIndex];
    final toggled = line.replaceFirstMapped(
      RegExp(r'^(\s*-\s*\[)( |x|X)(\])'),
      (m) => '${m.group(1)}${checked ? 'x' : ' '}${m.group(3)}',
    );
    setState(() => _lines[lineIndex] = toggled);
    _emit();
  }

  void _insertCheckboxLine() {
    final targetLine = _activeLine >= 0
        ? _activeLine
        : (_lastSelectedLine >= 0 ? _lastSelectedLine : -1);
    if (targetLine >= 0 && targetLine < _lines.length) {
      final current = _lines[targetLine];
      final cleaned = current.trim();
      final updated = cleaned.isEmpty ? '- [ ] ' : '- [ ] $cleaned';
      _lines[targetLine] = updated;
      _emit();
      setState(() {
        _activeLine = targetLine;
        _lastSelectedLine = targetLine;
        _lineCtrl.value = TextEditingValue(
          text: _lines[targetLine],
          selection: TextSelection.collapsed(offset: _lines[targetLine].length),
        );
      });
    } else {
      _lines.add('- [ ] ');
      _emit();
      setState(() {
        _activeLine = _lines.length - 1;
        _lastSelectedLine = _activeLine;
        _lineCtrl.value = const TextEditingValue(
          text: '- [ ] ',
          selection: TextSelection.collapsed(offset: 6),
        );
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _lineFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF252535),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Note body (tap a line to edit)', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 6),
          Row(
            children: [
              IconButton(
                tooltip: 'Add checkbox',
                onPressed: _insertCheckboxLine,
                icon: const Icon(Icons.check_box_outlined, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: _stopEditingLine,
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 160),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E2E),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF303040)),
              ),
              child: _lines.every((line) => line.trim().isEmpty)
                  ? Text(widget.hintText, style: const TextStyle(color: Colors.white24, fontSize: 12))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: List.generate(_lines.length, (i) {
                        final line = _lines[i];
                        if (i == _activeLine) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Focus(
                              onKeyEvent: _onEditingKeyEvent,
                              child: TextField(
                                controller: _lineCtrl,
                                focusNode: _lineFocus,
                                minLines: 1,
                                maxLines: null,
                                autofocus: true,
                                style: const TextStyle(fontSize: 14, height: 1.4, color: Color(0xFF7C6AF7)),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                  border: OutlineInputBorder(
                                    borderSide: BorderSide(color: Color(0xFF7C6AF7)),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: Color(0xFF7C6AF7)),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: Color(0xFF7C6AF7)),
                                  ),
                                ),
                                onChanged: _applyEditingValue,
                                onEditingComplete: _stopEditingLine,
                              ),
                            ),
                          );
                        }

                        if (_isCheckboxLine(line)) {
                          final parsed = _parseCheckboxLine(line);
                          return InkWell(
                            onTap: () => _startEditingLine(i),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 1),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: Checkbox(
                                      value: parsed.checked,
                                      visualDensity: VisualDensity.compact,
                                      onChanged: (v) => _toggleCheckbox(i, v ?? false),
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: IgnorePointer(
                                        ignoring: true,
                                        child: MarkdownBody(
                                          data: parsed.text.isEmpty ? ' ' : parsed.text,
                                          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                                            p: TextStyle(
                                              fontSize: 14,
                                              height: 1.4,
                                              decoration: parsed.checked ? TextDecoration.lineThrough : null,
                                              color: parsed.checked ? Colors.white54 : null,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        return InkWell(
                          onTap: () => _startEditingLine(i),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: line.trim().isEmpty
                                ? Container(
                                    width: double.infinity,
                                    height: 18,
                                    alignment: Alignment.centerLeft,
                                    child: const Text(' ', style: TextStyle(fontSize: 14)),
                                  )
                                : IgnorePointer(
                                    ignoring: true,
                                    child: MarkdownBody(
                                      data: line,
                                      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                                        p: const TextStyle(fontSize: 14, height: 1.4),
                                      ),
                                    ),
                                  ),
                          ),
                        );
                      }),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// ─── KANBAN VIEW ─────────────────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════════
class _KanbanView extends StatelessWidget {
  final List<Task> tasks;
  final void Function(Task) onTap;
  const _KanbanView({required this.tasks, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cols = {for (final s in kStatuses) s: tasks.where((t) => t.status == s).toList()};
    final labels = {'todo': '📋 To Do', 'in-progress': '🔄 In Progress', 'blocked': '🚫 Blocked', 'done': '✅ Done'};
    final colors = {
      'todo': Colors.white38, 'in-progress': const Color(0xFFFFCD5E),
      'blocked': const Color(0xFFE84040), 'done': const Color(0xFF4CAF50),
    };

    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      children: kStatuses.map((s) {
        final col = cols[s]!;
        return Container(
          width: 240,
          margin: const EdgeInsets.only(right: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Text(labels[s]!, style: TextStyle(fontWeight: FontWeight.bold, color: colors[s])),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: colors[s]!.withAlpha(40), borderRadius: BorderRadius.circular(10)),
                  child: Text('${col.length}', style: TextStyle(fontSize: 11, color: colors[s])),
                ),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: col.length,
                itemBuilder: (_, i) => _KanbanCard(task: col[i], onTap: onTap),
              ),
            ),
          ]),
        );
      }).toList(),
    );
  }
}

class _KanbanCard extends StatelessWidget {
  final Task task;
  final void Function(Task) onTap;
  const _KanbanCard({required this.task, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final priorityColor = {
      'low': const Color(0xFF6BB6FF), 'medium': const Color(0xFFFFCD5E),
      'high': const Color(0xFFF7926A), 'critical': const Color(0xFFE84040),
    }[task.priority] ?? Colors.white38;

    return GestureDetector(
      onTap: () => onTap(task),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: task.color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Expanded(child: Text(task.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
              _Badge(label: task.priority.toUpperCase(), color: priorityColor),
            ]),
            if (task.endDate != null) ...[
              const SizedBox(height: 6),
              _DueBadge(task: task),
            ],
          ]),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// ─── GANTT VIEW ──────────────────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════════
class _GanttView extends StatefulWidget {
  final List<Task> tasks;
  final void Function(Task) onTap;
  const _GanttView({required this.tasks, required this.onTap});
  @override
  State<_GanttView> createState() => _GanttViewState();
}

class _GanttViewState extends State<_GanttView> {
  static const double kDayW = 28.0;
  static const double kRowH = 40.0;
  static const double kLabelW = 160.0;
  static const double kHeaderH = 56.0;

  final _scrollCtrl = ScrollController();

  late DateTime _start;
  late DateTime _end;
  late int _days;

  @override
  void initState() {
    super.initState();
    _computeRange();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToToday());
  }

  @override
  void didUpdateWidget(_GanttView old) {
    super.didUpdateWidget(old);
    _computeRange();
  }

  void _computeRange() {
    final now = DateTime.now();
    DateTime earliest = now.subtract(const Duration(days: 14));
    DateTime latest   = now.add(const Duration(days: 60));
    for (final t in widget.tasks) {
      final s = _parseDate(t.startDate);
      final e = _parseDate(t.endDate);
      if (s != null && s.isBefore(earliest)) earliest = s.subtract(const Duration(days: 3));
      if (e != null && e.isAfter(latest))    latest   = e.add(const Duration(days: 3));
    }
    _start = DateTime(earliest.year, earliest.month, earliest.day);
    _end   = DateTime(latest.year, latest.month, latest.day);
    _days  = _end.difference(_start).inDays + 1;
  }

  void _scrollToToday() {
    final offset = DateTime.now().difference(_start).inDays * kDayW - 80.0;
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(offset.clamp(0, _scrollCtrl.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tasks.isEmpty) {
      return const Center(child: Text('No tasks to display', style: TextStyle(color: Colors.white38)));
    }

    // Build month header spans
    final months = <({String label, int span})>[];
    DateTime cursor = _start;
    while (!cursor.isAfter(_end)) {
      final label = _monthLabel(cursor);
      int span = 0;
      while (!cursor.isAfter(_end) && _monthLabel(cursor) == label) { span++; cursor = cursor.add(const Duration(days: 1)); }
      months.add((label: label, span: span));
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Left label column ─────────────────────────────────────────────────
        SizedBox(
          width: kLabelW,
          child: Column(children: [
            // Header spacer matching the Gantt header height
            Container(
              height: kHeaderH,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 12),
              decoration: const BoxDecoration(
                color: Color(0xFF13131F),
                border: Border(bottom: BorderSide(color: Color(0xFF2E2E3E))),
              ),
              child: const Text('Tasks', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white54, fontSize: 13)),
            ),
            // Task labels
            ...widget.tasks.map((t) => GestureDetector(
              onTap: () => widget.onTap(t),
              child: Container(
                height: kRowH,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF2E2E3E)))),
                child: Row(children: [
                  Container(width: 6, height: 6, decoration: BoxDecoration(color: t.color, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Expanded(child: Text(t.title, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                ]),
              ),
            )),
          ]),
        ),

        // ── Right scrollable grid ─────────────────────────────────────────────
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollCtrl,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: _days * kDayW,
              child: Column(children: [
                // Month + day header
                SizedBox(
                  height: kHeaderH,
                  child: Stack(children: [
                    // Month labels row (top 26px)
                    Positioned(
                      top: 0, left: 0, right: 0, height: 26,
                      child: Row(children: months.map((m) => Container(
                        width: m.span * kDayW,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: Color(0xFF13131F),
                          border: Border(right: BorderSide(color: Color(0xFF2E2E3E))),
                        ),
                        child: Text(m.label, style: const TextStyle(fontSize: 10, color: Colors.white54, fontWeight: FontWeight.bold)),
                      )).toList()),
                    ),
                    // Day numbers row (bottom 30px)
                    Positioned(
                      top: 26, left: 0, right: 0, bottom: 0,
                      child: Row(children: List.generate(_days, (i) {
                        final d = _start.add(Duration(days: i));
                        final isToday = _sameDay(d, DateTime.now());
                        return Container(
                          width: kDayW,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isToday ? const Color(0xFF7C6AF7).withAlpha(40) : const Color(0xFF13131F),
                            border: const Border(right: BorderSide(color: Color(0xFF2E2E3E))),
                          ),
                          child: Text(
                            '${d.day}',
                            style: TextStyle(fontSize: 9, color: isToday ? const Color(0xFF7C6AF7) : Colors.white38),
                          ),
                        );
                      })),
                    ),
                  ]),
                ),

                // Task bars
                ...widget.tasks.map((t) {
                  final start = _parseDate(t.startDate) ?? _parseDate(t.endDate);
                  final end   = _parseDate(t.endDate) ?? _parseDate(t.startDate);
                  return SizedBox(
                    height: kRowH,
                    child: Stack(children: [
                      // Today line
                      Positioned(
                        left: DateTime.now().difference(_start).inDays * kDayW + kDayW / 2,
                        top: 0, bottom: 0, width: 1,
                        child: Container(color: const Color(0xFF7C6AF7).withAlpha(80)),
                      ),
                      // Grid lines
                      Row(children: List.generate(_days, (i) => Container(
                        width: kDayW,
                        decoration: const BoxDecoration(border: Border(right: BorderSide(color: Color(0xFF2E2E3E)))),
                      ))),
                      // Bar
                      if (start != null && end != null)
                        Positioned(
                          left:  start.difference(_start).inDays * kDayW + 2,
                          top:   8,
                          height: kRowH - 16,
                          width: (end.difference(start).inDays + 1) * kDayW - 4,
                          child: GestureDetector(
                            onTap: () => widget.onTap(t),
                            child: Container(
                              decoration: BoxDecoration(
                                color: t.color.withAlpha(200),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Text(t.title,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ),
                    ]),
                  );
                }),
              ]),
            ),
          ),
        ),
      ],
    );
  }

  String _monthLabel(DateTime d) => ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][d.month - 1] + ' ${d.year}';
  bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
}

// ══════════════════════════════════════════════════════════════════════════════
// ─── TASK EDIT BOTTOM SHEET ──────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════════
class _TaskEditSheet extends StatefulWidget {
  final Task task;
  final void Function(Task) onSave;
  final VoidCallback onArchive;
  const _TaskEditSheet({required this.task, required this.onSave, required this.onArchive});
  @override
  State<_TaskEditSheet> createState() => _TaskEditSheetState();
}

class _TaskEditSheetState extends State<_TaskEditSheet> {
  late TextEditingController _titleCtrl;
  late TextEditingController _noteBodyCtrl;
  late String _status, _priority;
  DateTime? _startDate, _endDate;
  String? _dateError;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.task.title);
    _noteBodyCtrl = TextEditingController(text: widget.task.noteBody);
    _status    = widget.task.status;
    _priority  = widget.task.priority;
    _startDate = _parseDate(widget.task.startDate);
    _endDate   = _parseDate(widget.task.endDate);
  }

  @override
  void dispose() { _titleCtrl.dispose(); _noteBodyCtrl.dispose(); super.dispose(); }

  /// Validate that end >= start, returns true if valid.
  bool _validateDates() {
    if (_startDate != null && _endDate != null && _endDate!.isBefore(_startDate!)) {
      setState(() => _dateError = 'End date must be after start date');
      return false;
    }
    setState(() => _dateError = null);
    return true;
  }

  Future<void> _pickDate(bool isStart) async {
    final initial = (isStart ? _startDate : _endDate) ?? DateTime.now();
    final first   = isStart ? DateTime(2000) : (_startDate ?? DateTime(2000));
    final picked  = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(colorScheme: const ColorScheme.dark(primary: Color(0xFF7C6AF7))),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
        // Auto-push end date if it's now before start
        if (_endDate != null && _endDate!.isBefore(picked)) _endDate = picked;
      } else {
        _endDate = picked;
      }
    });
    _validateDates();
  }

  void _save() {
    if (!_validateDates()) return;
    widget.onSave(widget.task.copyWith(
      title:     _titleCtrl.text.trim().isEmpty ? null : _titleCtrl.text.trim(),
      noteBody:  _noteBodyCtrl.text,
      status:    _status,
      priority:  _priority,
      startDate: _startDate != null ? _fmtDate(_startDate!) : null,
      endDate:   _endDate   != null ? _fmtDate(_endDate!)   : null,
      clearStartDate: _startDate == null,
      clearEndDate:   _endDate   == null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final priorityColors = {
      'low': const Color(0xFF6BB6FF), 'medium': const Color(0xFFFFCD5E),
      'high': const Color(0xFFF7926A), 'critical': const Color(0xFFE84040),
    };
    final statusColors = {
      'todo': Colors.white38, 'in-progress': const Color(0xFFFFCD5E),
      'blocked': const Color(0xFFE84040), 'done': const Color(0xFF4CAF50),
    };
    final statusLabels = {'todo': '📋 To Do', 'in-progress': '🔄 In Progress', 'blocked': '🚫 Blocked', 'done': '✅ Done'};

    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          // Title bar
          Row(children: [
            Container(width: 4, height: 24, decoration: BoxDecoration(color: widget.task.color, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 10),
            const Text('Edit Task', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.archive_outlined, color: Color(0xFFF7926A)),
              tooltip: 'Archive',
              onPressed: () => showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: const Color(0xFF1E1E2E),
                  title: const Text('Archive task?'),
                  content: Text('Move "${widget.task.title}" to archive?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF7926A)),
                      onPressed: () { Navigator.pop(context); widget.onArchive(); },
                      child: const Text('Archive'),
                    ),
                  ],
                ),
              ),
            ),
          ]),
          const SizedBox(height: 16),

          // Title field
          TextField(
            controller: _titleCtrl,
            style: const TextStyle(fontSize: 15),
            decoration: InputDecoration(
              labelText: 'Title',
              filled: true, fillColor: const Color(0xFF252535),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 14),

          _LinePreviewMarkdownEditor(
            initialText: _noteBodyCtrl.text,
            hintText: 'Add additional details for this note...',
            onChanged: (value) => _noteBodyCtrl.text = value,
          ),
          const SizedBox(height: 14),

          // Status chips
          const Text('Status', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: kStatuses.map((s) => ChoiceChip(
            label: Text(statusLabels[s]!),
            selected: _status == s,
            selectedColor: statusColors[s]!.withAlpha(60),
            labelStyle: TextStyle(color: _status == s ? statusColors[s] : Colors.white54, fontSize: 12),
            onSelected: (_) => setState(() => _status = s),
          )).toList()),
          const SizedBox(height: 14),

          // Priority chips
          const Text('Priority', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: kPriorities.map((p) => ChoiceChip(
            label: Text(p.toUpperCase()),
            selected: _priority == p,
            selectedColor: priorityColors[p]!.withAlpha(60),
            labelStyle: TextStyle(color: _priority == p ? priorityColors[p] : Colors.white54, fontSize: 12),
            onSelected: (_) => setState(() => _priority = p),
          )).toList()),
          const SizedBox(height: 14),

          // Date pickers
          const Text('Dates', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: _DateButton(
              label: 'Start',
              date: _startDate,
              onTap: () => _pickDate(true),
              onClear: () => setState(() { _startDate = null; _validateDates(); }),
            )),
            const SizedBox(width: 10),
            Expanded(child: _DateButton(
              label: 'End / Due',
              date: _endDate,
              onTap: () => _pickDate(false),
              onClear: () => setState(() { _endDate = null; _validateDates(); }),
            )),
          ]),
          if (_dateError != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.error_outline, color: Color(0xFFE84040), size: 14),
              const SizedBox(width: 4),
              Text(_dateError!, style: const TextStyle(color: Color(0xFFE84040), fontSize: 12)),
            ]),
          ],
          const SizedBox(height: 20),

          // Save button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Save changes'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _DateButton extends StatelessWidget {
  final String label;
  final DateTime? date;
  final VoidCallback onTap, onClear;
  const _DateButton({required this.label, required this.date, required this.onTap, required this.onClear});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: const Color(0xFF252535), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        const Icon(Icons.calendar_today, size: 14, color: Color(0xFF7C6AF7)),
        const SizedBox(width: 6),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.white38)),
          Text(date != null ? _fmtDate(date!) : 'Not set',
              style: TextStyle(fontSize: 12, color: date != null ? Colors.white : Colors.white38)),
        ])),
        if (date != null) GestureDetector(
          onTap: onClear,
          child: const Icon(Icons.close, size: 14, color: Colors.white38),
        ),
      ]),
    ),
  );
}

// ─── Shared small widgets ─────────────────────────────────────────────────────
class _DueBadge extends StatelessWidget {
  final Task task;
  const _DueBadge({required this.task});
  @override
  Widget build(BuildContext context) {
    final days = task.daysUntilDue;
    final overdue = task.isOverdue;
    String text; Color color;
    if (overdue)      { text = 'Overdue ${(-days).abs()}d'; color = const Color(0xFFE84040); }
    else if (days==0) { text = 'Due today';                 color = const Color(0xFFFFCD5E); }
    else if (days<=3) { text = 'Due in ${days}d';           color = const Color(0xFFF7926A); }
    else              { text = '🗓 ${task.endDate}';        color = Colors.white38; }
    return Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: overdue || days<=3 ? FontWeight.bold : FontWeight.normal));
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withAlpha(40), borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withAlpha(100)),
    ),
    child: Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
  );
}

// ─── Task card (List view) ────────────────────────────────────────────────────
class _TaskCard extends StatelessWidget {
  final Task task;
  final void Function(Task) onTap;
  const _TaskCard({required this.task, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final priorityColor = {
      'low': const Color(0xFF6BB6FF), 'medium': const Color(0xFFFFCD5E),
      'high': const Color(0xFFF7926A), 'critical': const Color(0xFFE84040),
    }[task.priority] ?? Colors.white38;
    final statusColor = {
      'todo': Colors.white38, 'in-progress': const Color(0xFFFFCD5E),
      'blocked': const Color(0xFFE84040), 'done': const Color(0xFF4CAF50),
    }[task.status] ?? Colors.white38;
    final statusLabel = {'todo': '📋 To Do', 'in-progress': '🔄 In Progress', 'blocked': '🚫 Blocked', 'done': '✅ Done'}[task.status] ?? task.status;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        onTap: () => onTap(task),
        borderRadius: BorderRadius.circular(10),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 4, decoration: BoxDecoration(
              color: task.color,
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(10), bottomLeft: Radius.circular(10)),
            )),
            Expanded(child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(task.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
                  _Badge(label: task.priority.toUpperCase(), color: priorityColor),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Text(statusLabel, style: TextStyle(fontSize: 12, color: statusColor)),
                  const SizedBox(width: 8),
                  if (task.endDate != null) _DueBadge(task: task),
                ]),
              ]),
            )),
            const Padding(padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: Icon(Icons.chevron_right, color: Colors.white24, size: 18)),
          ]),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// ─── NEW TASK SHEET ──────────────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════════

class _NewTaskSheet extends StatefulWidget {
  /// Called with (title, noteBody, status, priority, startDate?, endDate?)
  final void Function(String, String, String, String, String?, String?) onCreate;
  final String defaultNoteBody;
  const _NewTaskSheet({required this.onCreate, required this.defaultNoteBody});
  @override
  State<_NewTaskSheet> createState() => _NewTaskSheetState();
}

class _NewTaskSheetState extends State<_NewTaskSheet> {
  final _titleCtrl = TextEditingController();
  final _noteBodyCtrl = TextEditingController();
  String _status   = 'todo';
  String _priority = 'medium';
  DateTime? _startDate, _endDate;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.defaultNoteBody.trim().isNotEmpty) {
      _noteBodyCtrl.text = widget.defaultNoteBody;
    }
  }

  @override
  void dispose() { _titleCtrl.dispose(); _noteBodyCtrl.dispose(); super.dispose(); }

  Future<void> _pickDate(bool isStart) async {
    final initial = (isStart ? _startDate : _endDate) ?? DateTime.now();
    final first   = isStart ? DateTime(2000) : (_startDate ?? DateTime(2000));
    final picked  = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(colorScheme: const ColorScheme.dark(primary: Color(0xFF7C6AF7))),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
        if (_endDate != null && _endDate!.isBefore(picked)) _endDate = picked;
      } else {
        _endDate = picked;
      }
    });
  }

  void _submit() {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Title is required');
      return;
    }
    if (_startDate != null && _endDate != null && _endDate!.isBefore(_startDate!)) {
      setState(() => _error = 'End date must be after start date');
      return;
    }
    widget.onCreate(
      title, _noteBodyCtrl.text, _status, _priority,
      _startDate != null ? _fmtDate(_startDate!) : null,
      _endDate   != null ? _fmtDate(_endDate!)   : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final priorityColors = {
      'low': const Color(0xFF6BB6FF), 'medium': const Color(0xFFFFCD5E),
      'high': const Color(0xFFF7926A), 'critical': const Color(0xFFE84040),
    };
    final statusColors = {
      'todo': Colors.white38, 'in-progress': const Color(0xFFFFCD5E),
      'blocked': const Color(0xFFE84040), 'done': const Color(0xFF4CAF50),
    };
    final statusLabels = {
      'todo': '📋 To Do', 'in-progress': '🔄 In Progress',
      'blocked': '🚫 Blocked', 'done': '✅ Done',
    };

    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Row(children: [
            const Icon(Icons.add_task, color: Color(0xFF7C6AF7)),
            const SizedBox(width: 10),
            const Text('New Task', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
              visualDensity: VisualDensity.compact,
            ),
          ]),
          const SizedBox(height: 14),

          // Title
          TextField(
            controller: _titleCtrl,
            autofocus: true,
            style: const TextStyle(fontSize: 15),
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Task title *',
              filled: true, fillColor: const Color(0xFF252535),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 14),

          _LinePreviewMarkdownEditor(
            initialText: _noteBodyCtrl.text,
            hintText: 'Add additional details for this note...',
            onChanged: (value) => _noteBodyCtrl.text = value,
          ),
          const SizedBox(height: 14),

          // Status
          const Text('Status', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: kStatuses.map((s) => ChoiceChip(
            label: Text(statusLabels[s]!),
            selected: _status == s,
            selectedColor: (statusColors[s]!).withAlpha(60),
            labelStyle: TextStyle(color: _status == s ? statusColors[s] : Colors.white54, fontSize: 12),
            onSelected: (_) => setState(() => _status = s),
          )).toList()),
          const SizedBox(height: 14),

          // Priority
          const Text('Priority', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: kPriorities.map((p) => ChoiceChip(
            label: Text(p.toUpperCase()),
            selected: _priority == p,
            selectedColor: priorityColors[p]!.withAlpha(60),
            labelStyle: TextStyle(color: _priority == p ? priorityColors[p] : Colors.white54, fontSize: 12),
            onSelected: (_) => setState(() => _priority = p),
          )).toList()),
          const SizedBox(height: 14),

          // Dates
          const Text('Dates', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: _DateButton(
              label: 'Start',
              date: _startDate,
              onTap: () => _pickDate(true),
              onClear: () => setState(() => _startDate = null),
            )),
            const SizedBox(width: 10),
            Expanded(child: _DateButton(
              label: 'End / Due',
              date: _endDate,
              onTap: () => _pickDate(false),
              onClear: () => setState(() => _endDate = null),
            )),
          ]),
          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.add),
              label: const Text('Create task'),
            ),
          ),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// ─── SYNC UI ─────────────────────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════════

enum _SyncStatus { idle, syncing, ok, error }

/// Compact AppBar button showing sync state.
class _SyncButton extends StatelessWidget {
  final _SyncStatus status;
  final String info;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _SyncButton({
    required this.status, required this.info,
    required this.onTap,  required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    Widget icon;
    Color color;
    String tooltip;

    switch (status) {
      case _SyncStatus.syncing:
        icon    = const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF7C6AF7)));
        color   = const Color(0xFF7C6AF7);
        tooltip = 'Syncing…';
      case _SyncStatus.ok:
        icon    = const Icon(Icons.cloud_done, size: 20);
        color   = const Color(0xFF4CAF50);
        tooltip = 'Synced  $info\nLong-press to reconfigure';
      case _SyncStatus.error:
        icon    = const Icon(Icons.cloud_off, size: 20);
        color   = const Color(0xFFE84040);
        tooltip = 'Sync error: $info\nLong-press to reconfigure';
      case _SyncStatus.idle:
        icon    = const Icon(Icons.cloud_upload_outlined, size: 20);
        color   = Colors.white38;
        tooltip = 'Sync to cloud\nLong-press to configure';
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: IconTheme(data: IconThemeData(color: color), child: icon),
        ),
      ),
    );
  }
}

class _SyncSetupSheet extends StatefulWidget {
  final VoidCallback onSaved;
  const _SyncSetupSheet({required this.onSaved});
  @override
  State<_SyncSetupSheet> createState() => _SyncSetupSheetState();
}

class _SyncSetupSheetState extends State<_SyncSetupSheet> {
  bool _busy = false;
  String? _error;
  String _savedEmail = '';

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final creds = await SyncService.savedCredentials();
    if (!mounted) return;
    setState(() {
      _savedEmail = creds.email;
    });
  }

  Future<void> _connectGoogle() async {
    setState(() { _busy = true; _error = null; });
    final err = await SyncService.signInWithGoogle();
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    widget.onSaved();
  }

  Future<void> _switchAccount() async {
    setState(() { _busy = true; _error = null; });
    await SyncService.clearCredentials();
    final err = await SyncService.signInWithGoogle();
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    widget.onSaved();
  }

  Future<void> _debugRestProbe() async {
    setState(() { _busy = true; _error = null; });
    final result = await SyncService.debugProbe();
    if (!mounted) return;
    setState(() { _busy = false; });
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('REST debug'),
        content: Text(result),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.cloud_sync, color: Color(0xFF7C6AF7)),
            const SizedBox(width: 10),
            const Text(
              'Cloud Sync Setup',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
              visualDensity: VisualDensity.compact,
            ),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Use your Google account to connect cloud sync.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 16),

          if (_savedEmail.trim().isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF252535),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Current account: $_savedEmail',
                style: const TextStyle(fontSize: 13),
              ),
            ),

          if (_error != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.error_outline, color: Color(0xFFE84040), size: 14),
              const SizedBox(width: 4),
              Expanded(child: Text(_error!, style: const TextStyle(color: Color(0xFFE84040), fontSize: 12))),
            ]),
          ],
          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _connectGoogle,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.login),
              label: Text(_busy ? 'Please wait…' : 'Continue with Google'),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: TextButton.icon(
              onPressed: _busy ? null : _switchAccount,
              icon: const Icon(Icons.switch_account, size: 16),
              label: const Text('Switch Google account', style: TextStyle(fontSize: 12)),
            ),
          ),

          if (Platform.isLinux)
            Center(
              child: TextButton.icon(
                onPressed: _busy ? null : _debugRestProbe,
                icon: const Icon(Icons.bug_report, size: 16),
                label: const Text('Test Firestore connection', style: TextStyle(fontSize: 12)),
              ),
            ),

          Center(
            child: TextButton(
              onPressed: () async {
                await SyncService.clearCredentials();
                if (mounted) Navigator.pop(context);
              },
              child: const Text('Disconnect / clear credentials',
                  style: TextStyle(fontSize: 12, color: Colors.white38)),
            ),
          ),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// ─── SETTINGS SCREEN ─────────────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════════

class _SettingsScreen extends StatefulWidget {
  final Future<void> Function() onSignOut;
  const _SettingsScreen({required this.onSignOut});
  @override
  State<_SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<_SettingsScreen> {
  final _defaultNoteCtrl = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(kPrefDefaultNoteTemplate)
        ?? '## Description\n\n## Notes';
    if (!mounted) return;
    setState(() {
      _defaultNoteCtrl.text = value;
      _loaded = true;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kPrefDefaultNoteTemplate,
      _defaultNoteCtrl.text,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _defaultNoteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loaded
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('Default note template',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text(
                  'Used when creating a new task. Supports Markdown.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _defaultNoteCtrl,
                  maxLines: 8,
                  minLines: 4,
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Color(0xFF252535),
                    border: OutlineInputBorder(borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _savePrefs,
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.logout),
                  title: const Text('Sign out / switch account'),
                  subtitle: const Text(
                    'Explicitly sign out from cloud sync and connect another Google account.',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: widget.onSignOut,
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
