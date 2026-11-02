import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/document_repository.dart';
import '../data/document_thumbnails.dart';
import '../data/reader_bookmarks.dart';

class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({
    super.key,
    required this.document,
    this.positionKey,
    this.thumbnailKey,
    this.onPosition,
    this.imageSlides = false,
    this.imageDocument = false,
  });
  final bool imageSlides;
  final bool imageDocument;
  final String? positionKey;
  final String? thumbnailKey;
  final ValueChanged<int>? onPosition;
  final LocalDocument document;
  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  final controller = PdfViewerController();
  late final searcher = PdfTextSearcher(controller)..addListener(_refresh);
  int page = 1, pages = 0;
  bool searching = false, savingBookmark = false;
  List<int> bookmarks = [];
  late final readerKey =
      widget.thumbnailKey ?? DocumentThumbnails.keyFor(widget.document);
  Future<void> _loadBookmarks() async {
    final loaded = await ReaderBookmarks.load(readerKey);
    if (mounted) setState(() => bookmarks = loaded);
  }

  Future<void> _toggleBookmark(int target) async {
    if (savingBookmark) return;
    setState(() => savingBookmark = true);
    final updated = [...bookmarks];
    if (!updated.remove(target)) updated.add(target);
    updated.sort();
    try {
      await ReaderBookmarks.save(readerKey, updated);
      if (mounted) setState(() => bookmarks = updated);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save this bookmark. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => savingBookmark = false);
    }
  }

  Future<void> _showBookmarks() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, refreshSheet) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: Column(
            children: [
              const ListTile(
                title: Text(
                  'Bookmarks',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text('Keep important pages close for revision'),
              ),
              ListTile(
                leading: Icon(
                  bookmarks.contains(page)
                      ? Icons.bookmark_remove_outlined
                      : Icons.bookmark_add_outlined,
                ),
                title: Text(
                  bookmarks.contains(page)
                      ? 'Remove page $page bookmark'
                      : 'Bookmark page $page',
                ),
                onTap: savingBookmark
                    ? null
                    : () async {
                        await _toggleBookmark(page);
                        if (context.mounted) refreshSheet(() {});
                      },
              ),
              const Divider(height: 1),
              Expanded(
                child: bookmarks.where((p) => p <= pages).isEmpty
                    ? const Center(child: Text('No saved pages yet.'))
                    : ListView(
                        children: [
                          for (final target in bookmarks.where(
                            (p) => p <= pages,
                          ))
                            ListTile(
                              leading: const Icon(Icons.bookmark_rounded),
                              title: Text(
                                '${widget.imageSlides ? 'Slide' : 'Page'} $target',
                              ),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                controller.goToPage(pageNumber: target);
                              },
                              trailing: IconButton(
                                tooltip: 'Remove bookmark',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: savingBookmark
                                    ? null
                                    : () async {
                                        await _toggleBookmark(target);
                                        if (context.mounted) {
                                          refreshSheet(() {});
                                        }
                                      },
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    page = widget.document.position;
    searcher;
    unawaited(_loadBookmarks().catchError((Object _) {}));
  }

  @override
  void dispose() {
    widget.onPosition?.call(page);
    unawaited(
      DocumentRepository()
          .savePosition(widget.positionKey ?? widget.document.path, page)
          .catchError((Object _) {}),
    );
    searcher.removeListener(_refresh);
    searcher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.document.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          tooltip: 'Bookmarks',
          onPressed: pages > 0 ? _showBookmarks : null,
          icon: Icon(
            bookmarks.contains(page)
                ? Icons.bookmark_rounded
                : Icons.bookmark_border_rounded,
          ),
        ),
        IconButton(
          tooltip: widget.imageSlides || widget.imageDocument
              ? 'Image pages have no searchable text'
              : 'Search PDF text',
          onPressed: pages == 0 || widget.imageSlides || widget.imageDocument
              ? null
              : () => setState(() => searching = !searching),
          icon: const Icon(Icons.search),
        ),
      ],
    ),
    body: Column(
      children: [
        if (searching)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Find text (scans need OCR)',
                    ),
                    onChanged: searcher.startTextSearch,
                  ),
                ),
                Text(
                  searcher.isSearching
                      ? 'Searching…'
                      : '${searcher.matches.length} matches',
                ),
                IconButton(
                  tooltip: 'Previous match',
                  onPressed: searcher.hasMatches
                      ? searcher.goToPrevMatch
                      : null,
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: 'Next match',
                  onPressed: searcher.hasMatches
                      ? searcher.goToNextMatch
                      : null,
                  icon: const Icon(Icons.arrow_downward),
                ),
              ],
            ),
          ),
        Expanded(
          child: PdfViewer(
            widget.document.bytes != null
                ? PdfDocumentRefData(
                    widget.document.bytes!,
                    sourceName: widget.document.path,
                  )
                : PdfDocumentRefFile(widget.document.path),
            controller: controller,
            initialPageNumber: widget.document.position,
            params: PdfViewerParams(
              onViewerReady: (document, _) {
                if (mounted) setState(() => pages = document.pages.length);
                unawaited(
                  DocumentThumbnails.capture(
                    readerKey,
                    document,
                  ).then<void>((_) {}).catchError((Object _) {}),
                );
              },
              onPageChanged: (value) {
                if (mounted) setState(() => page = value ?? 1);
              },
              errorBannerBuilder: (context, error, stack, ref) => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Could not open this PDF. It may be damaged, unavailable or password protected.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              pagePaintCallbacks: [searcher.pageTextMatchPaintCallback],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Previous page',
                onPressed: page > 1 && pages > 0
                    ? () => controller.goToPage(pageNumber: page - 1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text(
                pages == 0
                    ? 'Loading PDF…'
                    : '${widget.imageSlides ? 'Slide ' : ''}$page / $pages',
              ),
              IconButton(
                tooltip: 'Next page',
                onPressed: page < pages
                    ? () => controller.goToPage(pageNumber: page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
              IconButton(
                tooltip: 'Zoom out',
                onPressed: pages > 0 ? () => controller.zoomDown() : null,
                icon: const Icon(Icons.zoom_out),
              ),
              IconButton(
                tooltip: 'Zoom in',
                onPressed: pages > 0 ? () => controller.zoomUp() : null,
                icon: const Icon(Icons.zoom_in),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
