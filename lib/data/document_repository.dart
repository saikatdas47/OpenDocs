import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DocumentFormat { pdf, doc, docx, ppt, pptx }

extension DocumentFormatLabel on DocumentFormat {
  String get label => name.toUpperCase();
  bool get isWord => this == DocumentFormat.doc || this == DocumentFormat.docx;
  bool get isSlides =>
      this == DocumentFormat.ppt || this == DocumentFormat.pptx;
}

class LocalDocument {
  const LocalDocument({
    required this.name,
    required this.path,
    required this.format,
    this.bytes,
    this.size = 0,
    this.modified = 0,
    this.lastOpened = 0,
    this.favorite = false,
    this.owned = true,
    this.position = 1,
  });
  final String name, path;
  final DocumentFormat format;
  final Uint8List? bytes;
  final int size, modified, lastOpened, position;
  final bool favorite, owned;
  LocalDocument copyWith({
    String? path,
    bool? favorite,
    int? lastOpened,
    int? position,
  }) => LocalDocument(
    name: name,
    path: path ?? this.path,
    format: format,
    bytes: bytes,
    size: size,
    modified: modified,
    lastOpened: lastOpened ?? this.lastOpened,
    favorite: favorite ?? this.favorite,
    owned: owned,
    position: position ?? this.position,
  );
  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'format': format.name,
    'size': size,
    'modified': modified,
    'lastOpened': lastOpened,
    'favorite': favorite,
    'owned': owned,
  };
  factory LocalDocument.fromJson(Map<String, dynamic> json) => LocalDocument(
    name: json['name'] as String,
    path: json['path'] as String,
    format: DocumentFormat.values.byName(
      (json['format'] as String?) ??
          (json['name'] as String).split('.').last.toLowerCase(),
    ),
    size: (json['size'] as num?)?.toInt() ?? 0,
    modified: (json['modified'] as num?)?.toInt() ?? 0,
    lastOpened: (json['lastOpened'] as num?)?.toInt() ?? 0,
    favorite: json['favorite'] as bool? ?? false,
    owned: json['owned'] as bool? ?? true,
  );
}

class StorageBridge {
  static const channel = MethodChannel('dev.opendocs/storage');
  static final slideProgress = ValueNotifier<Map<String, dynamic>>({});
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static Future<Map<String, dynamic>> status() async => supported
      ? Map<String, dynamic>.from(
          await channel.invokeMapMethod<String, dynamic>('accessStatus') ?? {},
        )
      : {};
  static Future<bool> requestAccess() async =>
      supported && (await channel.invokeMethod<bool>('requestAccess') ?? false);
  static Future<bool> chooseFolder() async =>
      supported && (await channel.invokeMethod<bool>('chooseFolder') ?? false);
  static Future<Map<String, dynamic>> scan() async => Map<String, dynamic>.from(
    await channel.invokeMapMethod<String, dynamic>('scan') ?? {},
  );
  static Future<void> cancelScan() async {
    if (supported) await channel.invokeMethod<void>('cancelScan');
  }

  static Future<void> forgetFolders() async {
    if (supported) await channel.invokeMethod<void>('forgetFolders');
  }

  static Future<List<LocalDocument>> takeIncoming() async {
    if (!supported) return [];
    final items = await channel.invokeListMethod<dynamic>('takeIncoming') ?? [];
    return items
        .map(
          (item) =>
              LocalDocument.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }
}

class DocumentRepository {
  static const _key = 'library.v1';
  static const maxImportBytes = 128 * 1024 * 1024;
  Future<List<LocalDocument>> load() async {
    if (kIsWeb) return [];
    final prefs = await SharedPreferences.getInstance();
    final result = <LocalDocument>[];
    for (final item in prefs.getStringList(_key) ?? <String>[]) {
      try {
        final doc = LocalDocument.fromJson(
          jsonDecode(item) as Map<String, dynamic>,
        );
        result.add(
          doc.copyWith(position: prefs.getInt('page:${doc.path}') ?? 1),
        );
      } on Object {
        /* Recover other records if one metadata entry is damaged. */
      }
    }
    return result;
  }

  Future<void> save(List<LocalDocument> documents) async {
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      documents
          .where((d) => d.bytes == null)
          .map((d) => jsonEncode(d.toJson()))
          .toList(),
    );
  }

  Future<LocalDocument?> importDocument() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: DocumentFormat.values.map((v) => v.name).toList(),
    );
    if (picked.isEmpty) return null;
    final file = picked.single;
    final size = await file.length();
    if (size != null && size > maxImportBytes) {
      throw const FormatException('Choose a file smaller than 128 MB.');
    }
    final format = DocumentFormat.values.byName(
      file.name.split('.').last.toLowerCase(),
    );
    if (kIsWeb) {
      return LocalDocument(
        name: file.name,
        path: 'preview-${DateTime.now().microsecondsSinceEpoch}',
        format: format,
        size: size ?? 0,
        bytes: await file.readAsBytes(),
      );
    }
    if (file.path == null) {
      throw const FormatException(
        'Download the file first, then choose it again.',
      );
    }
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}/documents',
    );
    await directory.create(recursive: true);
    final destination =
        '${directory.path}/${DateTime.now().microsecondsSinceEpoch}.${format.name}';
    await File(file.path!).copy(destination);
    return LocalDocument(
      name: file.name,
      path: destination,
      format: format,
      size: size ?? 0,
      modified: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<LocalDocument> resolve(LocalDocument document) async {
    if (document.bytes != null) return document;
    if (document.path.startsWith('content:')) {
      final item = await StorageBridge.channel.invokeMapMethod<String, dynamic>(
        'materialize',
        {'uri': document.path},
      );
      if (item == null) {
        throw const FormatException('This folder is no longer available.');
      }
      return document.copyWith(path: item['path'] as String);
    }
    if (!await File(document.path).exists()) {
      throw const FormatException(
        'This file was moved or removed. Scan again or choose the file.',
      );
    }
    return document;
  }

  Future<void> savePosition(String id, int page) async {
    if (kIsWeb) return;
    await (await SharedPreferences.getInstance()).setInt('page:$id', page);
  }

  Future<void> remove(
    LocalDocument document,
    List<LocalDocument> remaining,
  ) async {
    // Removing a library entry never deletes the user's original file.
    // Only app-owned imported copies under our own private directory may be removed.
    if (!kIsWeb && document.owned && document.bytes == null) {
      final support = (await getApplicationSupportDirectory()).path;
      final files = await getApplicationDocumentsDirectory();
      final path = File(document.path).absolute.path;
      final privateCopy =
          path.startsWith('$support/documents/') ||
          path.startsWith('${files.parent.path}/files/documents/');
      if (privateCopy && await File(path).exists()) await File(path).delete();
    }
    await save(remaining);
  }

  static List<LocalDocument> mergeScan(
    List<LocalDocument> old,
    List<LocalDocument> scanned, {
    bool complete = true,
  }) {
    final previous = {for (final d in old) d.path: d};
    final result = {
      for (final d in old)
        if (d.owned || !complete) d.path: d,
    };
    for (final d in scanned) {
      final before = previous[d.path];
      result[d.path] = d.copyWith(
        favorite: before?.favorite,
        lastOpened: before?.lastOpened,
        position: before?.position,
      );
    }
    return result.values.toList();
  }
}

String formatBytes(int value) {
  if (value <= 0) return 'Document';
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
}
