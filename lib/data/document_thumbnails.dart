import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'document_repository.dart';

/// Small, lazy previews. Office previews are created by the reader after conversion.
class DocumentThumbnails {
  static final revision = ValueNotifier<int>(0);
  static final _memory = <String, Uint8List>{};
  static final _pending = <String, Future<Uint8List?>>{};
  static Future<void> _queue = Future.value();
  static bool _paused = false;
  static int _generation = 0;
  static String keyFor(LocalDocument doc) => sha256
      .convert(utf8.encode('${doc.path}:${doc.size}:${doc.modified}'))
      .toString();
  static Future<File> _file(String key) async =>
      File('${(await getTemporaryDirectory()).path}/thumbnails/$key.png');
  static Future<Uint8List?> load(LocalDocument doc) {
    final key = keyFor(doc);
    if (_pending.length >= 96 && !_pending.containsKey(key)) {
      _pending.remove(_pending.keys.first);
    }
    return _pending.putIfAbsent(key, () {
      final task = _queue
          .then((_) async {
            if (_paused) return null;
            if (_memory[key] case final bytes?) return bytes;
            if (!kIsWeb) {
              final cached = await _file(key);
              if (await cached.exists()) {
                final bytes = await cached.readAsBytes();
                _remember(key, bytes);
                return bytes;
              }
            }
            if (doc.format != DocumentFormat.pdf) return null;
            if (!kIsWeb &&
                doc.bytes == null &&
                !await File(doc.path).exists()) {
              return null;
            }
            await pdfrxFlutterInitialize();
            final pdf = doc.bytes != null
                ? await PdfDocument.openData(doc.bytes!)
                : await PdfDocument.openFile(doc.path);
            try {
              return await capture(key, pdf);
            } finally {
              await pdf.dispose();
            }
          })
          .catchError((Object _) => null);
      _queue = task.then<void>((_) {});
      return task;
    });
  }

  static void _remember(String key, Uint8List bytes) {
    _memory.remove(key);
    _memory[key] = bytes;
    while (_memory.length > 48) {
      _memory.remove(_memory.keys.first);
    }
  }

  static Future<Uint8List?> capture(String key, PdfDocument pdf) async {
    if (_paused || pdf.pages.isEmpty) return null;
    final generation = _generation;
    final page = pdf.pages.first;
    final width = 120;
    final height = (width * page.height / page.width).round().clamp(1, 240);
    final pixels = await page.render(
      width: width,
      height: height,
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
    );
    if (pixels == null) return null;
    try {
      final image = await pixels.createImage();
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null || generation != _generation || _paused) return null;
        final bytes = png.buffer.asUint8List();
        if (!kIsWeb) {
          final file = await _file(key);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes, flush: true);
          final files = await file.parent
              .list()
              .where((f) => f is File)
              .cast<File>()
              .toList();
          if (files.length > 256) {
            final dated = <File, DateTime>{};
            for (final item in files) {
              dated[item] = await item.lastModified();
            }
            files.sort((a, b) => dated[a]!.compareTo(dated[b]!));
            for (final old in files.take(files.length - 192)) {
              if (old.path != file.path) await old.delete();
            }
          }
        }
        _remember(key, bytes);
        _pending.remove(key);
        revision.value++;
        return bytes;
      } finally {
        image.dispose();
      }
    } finally {
      pixels.dispose();
    }
  }

  static Future<Map<String, dynamic>> clearCache() async {
    _paused = true;
    _generation++;
    try {
      final result = StorageBridge.supported
          ? await StorageBridge.channel.invokeMapMethod<String, dynamic>(
                  'clearReaderCache',
                ) ??
                {}
          : <String, dynamic>{
              'freed': _memory.values.fold<int>(0, (n, b) => n + b.length),
            };
      _memory.clear();
      _pending.clear();
      return result;
    } finally {
      _paused = false;
      revision.value++;
    }
  }
}
