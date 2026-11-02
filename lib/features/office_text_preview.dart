import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/document_repository.dart';
import '../readers/office_text_reader.dart';

class OfficeTextPreview extends StatefulWidget {
  const OfficeTextPreview({super.key, required this.document});
  final LocalDocument document;
  @override
  State<OfficeTextPreview> createState() => _OfficeTextPreviewState();
}

class _OfficeTextPreviewState extends State<OfficeTextPreview> {
  late final Future<List<String>> content = _read();
  Future<List<String>> _read() async {
    final inMemory = widget.document.bytes;
    if (inMemory != null) {
      return compute(_parse, (
        inMemory,
        widget.document.format == DocumentFormat.pptx,
      ));
    }
    final file = File(widget.document.path);
    if (await file.length() > 32 * 1024 * 1024) {
      throw const FormatException('File exceeds the 32 MB preview limit.');
    }
    final bytes = await file.readAsBytes();
    final slides = widget.document.format == DocumentFormat.pptx;
    return compute(_parse, (bytes, slides));
  }

  static List<String> _parse((Uint8List, bool) input) =>
      readOfficeText(input.$1, input.$2);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.document.name)),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Basic text preview • Images, tables, charts and original layout are not rendered.',
          ),
        ),
        Expanded(
          child: FutureBuilder<List<String>>(
            future: content,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Cannot preview this document. It may be damaged, encrypted, unsupported or too large.',
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return ListView.builder(
                padding: const EdgeInsets.all(20),
                itemCount: snapshot.data!.length,
                itemBuilder: (context, index) => Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.document.format == DocumentFormat.pptx)
                              Text(
                                'Slide ${index + 1}',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            const SizedBox(height: 16),
                            SelectableText(
                              snapshot.data![index].isEmpty
                                  ? 'No text in this section.'
                                  : snapshot.data![index],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
