import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../data/document_repository.dart';
import 'pdf_reader_screen.dart';

/// Slide geometry is rendered by the embedded Android office engine, then read as an image-only PDF.
class SlidePdfReaderScreen extends StatefulWidget {
  const SlidePdfReaderScreen({super.key, required this.document});
  final LocalDocument document;
  @override
  State<SlidePdfReaderScreen> createState() => _SlidePdfReaderScreenState();
}

class _SlidePdfReaderScreenState extends State<SlidePdfReaderScreen> {
  late Future<LocalDocument> converted = _convert();
  bool finished = false;
  Future<LocalDocument> _convert() async {
    finished = false;
    StorageBridge.slideProgress.value = {
      'completed': 0,
      'total': 0,
      'stage': 'Preparing your document',
    };
    if (kIsWeb) {
      final bytes = widget.document.bytes;
      if (bytes == null) {
        throw const FormatException('Choose the document again.');
      }
      final id = sha256.convert(bytes).toString();
      // Only known, locally generated Android test previews are served here.
      // Browser preview never uploads documents or pretends to contain the phone renderer.
      final response = await http
          .get(Uri.base.resolve('/slide-preview/$id.pdf'))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw const FormatException(
          'Document conversion runs fully offline in the Android app. Install OpenDocs on your phone to prepare this file.',
        );
      }
      finished = true;
      return LocalDocument(
        name: widget.document.name,
        path: 'slides-$id.pdf',
        format: DocumentFormat.pdf,
        bytes: response.bodyBytes,
      );
    }
    if (!StorageBridge.supported) {
      throw const FormatException(
        'On-device document conversion is available on Android.',
      );
    }
    var path = widget.document.path;
    if (widget.document.bytes != null) {
      final dir = await getTemporaryDirectory();
      final id = sha256.convert(widget.document.bytes!).toString();
      path = '${dir.path}/$id.${widget.document.format.name}';
      await File(path).writeAsBytes(widget.document.bytes!, flush: true);
    }
    final result = await StorageBridge.channel.invokeMapMethod<String, dynamic>(
      'convertSlides',
      {'path': path},
    );
    if (result == null) {
      throw const FormatException(
        'The document engine returned no output. Try again.',
      );
    }
    finished = true;
    return LocalDocument(
      name: widget.document.name,
      path: result['path'] as String,
      format: DocumentFormat.pdf,
      position: widget.document.position,
    );
  }

  @override
  void dispose() {
    if (!finished && StorageBridge.supported) {
      StorageBridge.channel
          .invokeMethod<void>('cancelSlides')
          .catchError((Object _) {});
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<LocalDocument>(
    future: converted,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return PdfReaderScreen(
          document: snapshot.data!,
          positionKey: widget.document.path,
          imageSlides: widget.document.format.isSlides,
          imageDocument: true,
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.document.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: snapshot.hasError
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.slideshow_rounded, size: 56),
                      const SizedBox(height: 20),
                      Text(
                        snapshot.error is FormatException
                            ? (snapshot.error as FormatException).message
                            : snapshot.error is PlatformException
                            ? ((snapshot.error as PlatformException).message ??
                                  'Could not prepare this document.')
                            : 'Could not prepare this document. Try a smaller or unlocked copy.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () => setState(() => converted = _convert()),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try again'),
                      ),
                    ],
                  )
                : ValueListenableBuilder<Map<String, dynamic>>(
                    valueListenable: StorageBridge.slideProgress,
                    builder: (context, status, _) {
                      final total = (status['total'] as num?)?.toInt() ?? 0;
                      final done = (status['completed'] as num?)?.toInt() ?? 0;
                      return ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 380),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.auto_stories_rounded,
                              size: 60,
                              color: Color(0xff6559cc),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              status['stage'] as String? ??
                                  'Preparing your document',
                              style: Theme.of(context).textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            LinearProgressIndicator(
                              value: total > 0 ? done / total : null,
                            ),
                            const SizedBox(height: 20),
                            const Text(
                              'Rendering each page as an image, then preparing your PDF. Everything stays on this device.',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'The first document can take longer while the offline engine is prepared.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      );
    },
  );
}
