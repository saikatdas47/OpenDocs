import 'package:flutter/material.dart';

import '../data/document_repository.dart';
import '../data/document_thumbnails.dart';

class DocumentThumbnail extends StatelessWidget {
  const DocumentThumbnail({
    super.key,
    required this.document,
    required this.fallback,
    this.size = 44,
  });
  final LocalDocument document;
  final Widget fallback;
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size + 8,
    child: ValueListenableBuilder<int>(
      valueListenable: DocumentThumbnails.revision,
      builder: (context, _, _) => FutureBuilder(
        future: DocumentThumbnails.load(document),
        builder: (context, snapshot) => snapshot.hasData
            ? Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0xffdce3df)),
                  borderRadius: BorderRadius.circular(5),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.memory(
                  snapshot.data!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              )
            : Tooltip(
                message: document.format == DocumentFormat.pdf
                    ? 'Preparing first-page preview'
                    : 'Open once to create a first-page preview',
                child: fallback,
              ),
      ),
    ),
  );
}
