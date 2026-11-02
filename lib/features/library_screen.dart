import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/document_repository.dart';
import 'pdf_reader_screen.dart';
import 'office_reader_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.repository,
    required this.toggleTheme,
  });
  final DocumentRepository repository;
  final VoidCallback toggleTheme;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  List<LocalDocument> documents = [];
  bool busy = true, scanning = false, grid = false, allAccess = false;
  int folders = 0, section = 0;
  String filter = 'All', query = '', sort = 'Recent';
  final search = TextEditingController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    if (StorageBridge.supported) {
      StorageBridge.channel.setMethodCallHandler((call) async {
        if (call.method == 'incomingAvailable') await _receive();
        if (call.method == 'slideProgress') {
          StorageBridge.slideProgress.value = Map<String, dynamic>.from(
            call.arguments as Map,
          );
        }
        if (call.method == 'incomingError') _message(call.arguments as String);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    search.dispose();
    if (StorageBridge.supported) {
      StorageBridge.channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _accessStatus();
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.repository.load();
      if (!mounted) return;
      setState(() => documents = loaded);
      await _accessStatus();
    } catch (_) {
      _message('Your library could not be loaded. You can still open a file.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await _receive();
    if (!mounted || !StorageBridge.supported) return;
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('storageIntroSeen') ?? false)) {
      await prefs.setBool('storageIntroSeen', true);
      if (mounted) await _permissionSheet();
    }
  }

  Future<void> _accessStatus() async {
    try {
      final status = await StorageBridge.status();
      if (mounted) {
        setState(() {
          allAccess = status['allFiles'] == true;
          folders = (status['folders'] as num?)?.toInt() ?? 0;
        });
      }
    } catch (_) {}
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _receive() async {
    try {
      final incoming = await StorageBridge.takeIncoming();
      if (incoming.isEmpty || !mounted) return;
      final merged = {
        for (final d in documents) d.path: d,
        for (final d in incoming) d.path: d,
      }.values.toList();
      await widget.repository.save(merged);
      if (!mounted) return;
      setState(() => documents = merged);
      await _open(incoming.last);
    } catch (_) {
      _message('Could not receive that document. Try Open file.');
    }
  }

  Future<void> _import({
    bool demo = false,
    DocumentFormat sampleFormat = DocumentFormat.pdf,
  }) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final doc = demo
          ? LocalDocument(
              name: 'OpenDocs sample.${sampleFormat.name}',
              path: 'sample.${sampleFormat.name}',
              format: sampleFormat,
              bytes: (await rootBundle.load(
                'assets/sample.${sampleFormat.name}',
              )).buffer.asUint8List(),
            )
          : await widget.repository.importDocument();
      if (doc == null) return;
      final updated = [doc, ...documents.where((d) => d.path != doc.path)];
      await widget.repository.save(updated);
      if (!mounted) return;
      setState(() => documents = updated);
      await _open(doc);
    } on FormatException catch (e) {
      _message(e.message);
    } catch (_) {
      _message(
        'Could not open this file. Choose a local PDF, Word or PowerPoint document.',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _open(LocalDocument doc) async {
    try {
      final resolved = await widget.repository.resolve(doc);
      final updated = documents
          .map(
            (d) => d.path == doc.path
                ? d.copyWith(lastOpened: DateTime.now().millisecondsSinceEpoch)
                : d,
          )
          .toList();
      await widget.repository.save(updated);
      if (!mounted) return;
      setState(() => documents = updated);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => doc.format == DocumentFormat.pdf
              ? PdfReaderScreen(
                  document: resolved,
                  positionKey: doc.path,
                  onPosition: (page) {
                    final i = documents.indexWhere((d) => d.path == doc.path);
                    if (i >= 0) {
                      documents[i] = documents[i].copyWith(position: page);
                    }
                  },
                )
              : OfficeReaderScreen(document: resolved),
        ),
      );
    } on FormatException catch (e) {
      _message(e.message);
    } catch (_) {
      _message(
        'This file is unavailable. Scan again or use Open file to choose it.',
      );
    }
  }

  Future<void> _favorite(LocalDocument doc) async {
    final updated = documents
        .map((d) => d.path == doc.path ? d.copyWith(favorite: !d.favorite) : d)
        .toList();
    try {
      await widget.repository.save(updated);
      if (mounted) setState(() => documents = updated);
    } catch (_) {
      _message('Could not save this favorite.');
    }
  }

  Future<void> _remove(LocalDocument doc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from library?'),
        content: Text(
          doc.owned
              ? 'The imported copy will be removed from OpenDocs. Your original file stays in its folder.'
              : 'This removes the library entry. Your original file stays in its folder and can reappear after a scan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final updated = documents.where((d) => d.path != doc.path).toList();
    try {
      await widget.repository.remove(doc, updated);
      if (mounted) setState(() => documents = updated);
    } catch (_) {
      _message('Could not remove this entry.');
    }
  }

  Future<void> _permissionSheet() async {
    if (!StorageBridge.supported) {
      _message(
        'Device scanning is available in the Android app. Use Open file in this preview.',
      );
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.folder_copy_outlined,
                size: 40,
                color: Color(0xff6366f1),
              ),
              const SizedBox(height: 18),
              Text(
                'Bring your documents together',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text(
                'Allow storage access to find PDFs, Word files and presentations. OpenDocs reads files on your device. It does not upload them or change your originals.',
              ),
              const SizedBox(height: 12),
              const Text(
                'You can scan shared storage, or allow access only to folders you choose. Android’s private app folders remain protected.',
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, 'all'),
                  icon: const Icon(Icons.manage_search_rounded),
                  label: const Text('Allow storage access & scan'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, 'folder'),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Choose a folder instead'),
                ),
              ),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Not now — open individual files'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    try {
      if (choice == 'all') {
        final allowed = await StorageBridge.requestAccess();
        await _accessStatus();
        if (allowed) {
          await _scan();
        } else {
          _message(
            'Storage access was not granted. You can choose a folder or open individual files.',
          );
        }
      } else if (choice == 'folder') {
        if (await StorageBridge.chooseFolder()) {
          await _accessStatus();
          await _scan();
        }
      }
    } catch (_) {
      _message(
        'Storage access is unavailable here. Try Choose folder from Settings.',
      );
    }
  }

  Future<void> _scan() async {
    if (busy || scanning) return;
    await _accessStatus();
    if (!StorageBridge.supported || (!allAccess && folders == 0)) {
      await _permissionSheet();
      return;
    }
    setState(() => scanning = true);
    try {
      final result = await StorageBridge.scan();
      final found = ((result['documents'] as List?) ?? [])
          .map(
            (item) =>
                LocalDocument.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();
      final partial =
          result['cancelled'] == true ||
          result['truncated'] == true ||
          (result['skipped'] as num? ?? 0) > 0;
      final merged = DocumentRepository.mergeScan(
        documents,
        found,
        complete: !partial,
      );
      await widget.repository.save(merged);
      if (!mounted) return;
      setState(() => documents = merged);
      _message(
        '${found.length} documents found${partial ? ' • Some folders were skipped or the scan stopped early' : ''}.',
      );
    } catch (_) {
      _message(
        'Could not scan storage. Check permissions or choose the folder again.',
      );
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  List<LocalDocument> get visible {
    final result = documents.where((d) {
      if (section == 1 && d.lastOpened == 0) return false;
      if (section == 2 && !d.favorite) return false;
      if (filter == 'PDF' && d.format != DocumentFormat.pdf) return false;
      if (filter == 'Word' && !d.format.isWord) return false;
      if (filter == 'Slides' && !d.format.isSlides) return false;
      return d.name.toLowerCase().contains(query.toLowerCase());
    }).toList();
    result.sort(
      (a, b) => switch (sort) {
        'Name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        'Size' => b.size.compareTo(a.size),
        _ =>
          b.lastOpened != a.lastOpened
              ? b.lastOpened.compareTo(a.lastOpened)
              : b.modified.compareTo(a.modified),
      },
    );
    return result;
  }

  Color colorFor(DocumentFormat format) => format == DocumentFormat.pdf
      ? const Color(0xffe75b68)
      : format.isWord
      ? const Color(0xff4b85e7)
      : const Color(0xffef9a45);
  IconData iconFor(DocumentFormat format) => format == DocumentFormat.pdf
      ? Icons.picture_as_pdf_rounded
      : format.isWord
      ? Icons.article_rounded
      : Icons.slideshow_rounded;
  Widget _badge(LocalDocument d, {double size = 48}) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: colorFor(d.format).withValues(alpha: .12),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Icon(iconFor(d.format), color: colorFor(d.format), size: size * .52),
  );
  Widget _tile(LocalDocument d, {bool card = false}) {
    final theme = Theme.of(context);
    final menu = PopupMenuButton<String>(
      tooltip: 'Document actions',
      onSelected: (value) {
        if (value == 'remove') _remove(d);
        if (value == 'favorite') _favorite(d);
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'favorite',
          child: Text(d.favorite ? 'Remove favorite' : 'Add to favorites'),
        ),
        const PopupMenuItem(
          value: 'remove',
          child: Text('Remove from library'),
        ),
      ],
    );
    if (card) {
      return Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _open(d),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _badge(d),
                    const Spacer(),
                    IconButton(
                      tooltip: d.favorite
                          ? 'Remove favorite'
                          : 'Add to favorites',
                      onPressed: () => _favorite(d),
                      icon: Icon(
                        d.favorite
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        color: d.favorite ? const Color(0xffedb24a) : null,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  d.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${d.format.label} · ${formatBytes(d.size)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    SizedBox(width: 32, height: 32, child: menu),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: _badge(d),
        title: Text(
          d.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '${d.format.label}  ·  ${formatBytes(d.size)}  ·  ${d.owned ? 'Imported' : 'On device'}',
          ),
        ),
        onTap: () => _open(d),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: d.favorite ? 'Remove favorite' : 'Add to favorites',
              onPressed: () => _favorite(d),
              icon: Icon(
                d.favorite ? Icons.star_rounded : Icons.star_border_rounded,
                color: d.favorite ? const Color(0xffedb24a) : null,
              ),
            ),
            menu,
          ],
        ),
      ),
    );
  }

  Widget _hero(bool compact) {
    final title = section == 1
        ? 'Pick up where you left off.'
        : section == 2
        ? 'Your favorites, close at hand.'
        : 'All your documents.\nOne calm space.';
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 22 : 32),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xff242449), Color(0xff4c46a0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'YOUR OFFLINE READING SPACE',
                    style: TextStyle(
                      color: Color(0xffd3d1ff),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 25 : 34,
                    fontWeight: FontWeight.w700,
                    height: 1.17,
                    letterSpacing: -.8,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${documents.length} documents · PDF, Word & PowerPoint',
                  style: const TextStyle(
                    color: Color(0xffd3d1ee),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xff433d90),
                      ),
                      onPressed: busy ? null : () => _import(),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Open file'),
                    ),
                    if (StorageBridge.supported)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xff8983bc)),
                        ),
                        onPressed: scanning ? null : _scan,
                        icon: const Icon(Icons.radar_rounded),
                        label: const Text('Scan storage'),
                      ),
                    if (kIsWeb)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xff8983bc)),
                        ),
                        onPressed: busy ? null : () => _import(demo: true),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Try sample PDF'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (!compact)
            Container(
              margin: const EdgeInsets.only(left: 24),
              width: 122,
              height: 144,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: .15)),
              ),
              child: const Icon(
                Icons.auto_stories_rounded,
                color: Color(0xffcfcbff),
                size: 68,
              ),
            ),
        ],
      ),
    );
  }

  Widget _library(bool compact) {
    final items = visible;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            compact ? 18 : 32,
            12,
            compact ? 18 : 32,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _hero(compact),
                const SizedBox(height: 22),
                if (kIsWeb)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Browser preview · Files stay in this tab; reload clears the list. Full Office layout and storage scanning are available in the Android app.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                TextField(
                  controller: search,
                  onChanged: (v) => setState(() => query = v),
                  decoration: InputDecoration(
                    hintText: 'Search your documents',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              search.clear();
                              setState(() => query = '');
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                  ),
                ),
                const SizedBox(height: 18),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: ['All', 'PDF', 'Word', 'Slides']
                        .map(
                          (label) => Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: ChoiceChip(
                              label: Text(label),
                              selected: filter == label,
                              onSelected: (_) => setState(() => filter = label),
                              showCheckmark: false,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${section == 1
                            ? 'Recently opened'
                            : section == 2
                            ? 'Favorites'
                            : 'Your library'} (${items.length})',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Sort documents',
                      initialValue: sort,
                      onSelected: (v) => setState(() => sort = v),
                      itemBuilder: (_) => ['Recent', 'Name', 'Size']
                          .map((v) => PopupMenuItem(value: v, child: Text(v)))
                          .toList(),
                      icon: const Icon(Icons.sort_rounded),
                    ),
                    IconButton(
                      tooltip: grid ? 'List view' : 'Grid view',
                      onPressed: () => setState(() => grid = !grid),
                      icon: Icon(
                        grid
                            ? Icons.view_list_rounded
                            : Icons.grid_view_rounded,
                      ),
                    ),
                  ],
                ),
                if (busy || scanning)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      children: [
                        const LinearProgressIndicator(),
                        if (scanning)
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Finding documents on your device…',
                                ),
                              ),
                              TextButton(
                                onPressed: StorageBridge.cancelScan,
                                child: const Text('Stop'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        if (items.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary
                          .withValues(alpha: .08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      section == 2
                          ? Icons.star_outline_rounded
                          : Icons.folder_open_rounded,
                      size: 48,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    query.isNotEmpty
                        ? 'No matching documents'
                        : section == 1
                        ? 'Your next chapter starts here'
                        : section == 2
                        ? 'Keep your favorites here'
                        : 'A quiet place for your documents',
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    query.isNotEmpty
                        ? 'Try another file name.'
                        : section == 2
                        ? 'Tap the star beside any document.'
                        : 'Open a file or scan storage to begin reading.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 22),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              compact ? 18 : 32,
              0,
              compact ? 18 : 32,
              100,
            ),
            sliver: grid
                ? SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: compact ? 2 : 3,
                      mainAxisExtent: 190,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _tile(items[i], card: true),
                  )
                : SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) => _tile(items[i]),
                  ),
          ),
      ],
    );
  }

  Widget _settings() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        'Make yourself at home',
        style: Theme.of(context).textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 24),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined),
              title: const Text('Appearance'),
              subtitle: const Text('Switch between light and dark'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.toggleTheme,
            ),
            if (StorageBridge.supported) ...[
              ListTile(
                leading: const Icon(Icons.security_outlined),
                title: const Text('Storage access'),
                subtitle: Text(
                  allAccess
                      ? 'Shared storage access enabled'
                      : '$folders folders connected',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _permissionSheet,
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('Connect another folder'),
                onTap: () async {
                  try {
                    if (await StorageBridge.chooseFolder()) {
                      await _accessStatus();
                      await _scan();
                    }
                  } catch (_) {
                    _message('Could not connect this folder.');
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_off_outlined),
                title: const Text('Disconnect selected folders'),
                subtitle: const Text('Does not delete any files'),
                onTap: () async {
                  await StorageBridge.forgetFolders();
                  await _accessStatus();
                  _message(
                    'Selected folder permissions removed. All-files access can be changed in Android Settings.',
                  );
                },
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 20),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.lock_outline_rounded),
              title: const Text('Private by design'),
              subtitle: const Text(
                'Your documents are read on this device. No account, upload or document server.',
              ),
            ),
            const ListTile(
              leading: Icon(Icons.info_outline_rounded),
              title: Text('Reading formats'),
              subtitle: Text(
                'PDF and DOCX reading. PPT/PPTX slides are rendered offline as images into a PDF. Legacy DOC uses text reading. Missing fonts and complex Office effects can still differ.',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.auto_stories_outlined),
              title: const Text('Try sample documents'),
              subtitle: const Text('PDF, Word, legacy DOC and PowerPoint'),
              onTap: () async {
                final format = await showModalBottomSheet<DocumentFormat>(
                  context: context,
                  showDragHandle: true,
                  builder: (context) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final format in [
                          DocumentFormat.pdf,
                          DocumentFormat.docx,
                          DocumentFormat.doc,
                          DocumentFormat.pptx,
                        ])
                          ListTile(
                            leading: Icon(iconFor(format)),
                            title: Text('Sample ${format.label}'),
                            onTap: () => Navigator.pop(context, format),
                          ),
                      ],
                    ),
                  ),
                );
                if (format != null) {
                  await _import(demo: true, sampleFormat: format);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('OpenDocs 1.0'),
              subtitle: const Text('Open-source software notices'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'OpenDocs',
                applicationVersion: '1.0.0',
              ),
            ),
          ],
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 880;
      return Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.auto_stories_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'OpenDocs',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                ),
              ),
            ],
          ),
          actions: [
            if (StorageBridge.supported && section != 3)
              IconButton(
                tooltip: 'Scan storage',
                onPressed: scanning ? null : _scan,
                icon: const Icon(Icons.refresh_rounded),
              ),
            IconButton(
              tooltip: 'Toggle theme',
              onPressed: widget.toggleTheme,
              icon: const Icon(Icons.brightness_6_outlined),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Row(
          children: [
            if (wide) ...[
              NavigationRail(
                selectedIndex: section,
                onDestinationSelected: (v) => setState(() => section = v),
                labelType: NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder_rounded),
                    label: Text('Library'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.history_rounded),
                    label: Text('Recent'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.star_outline_rounded),
                    selectedIcon: Icon(Icons.star_rounded),
                    label: Text('Favorites'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings_rounded),
                    label: Text('Settings'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
            ],
            Expanded(child: section == 3 ? _settings() : _library(!wide)),
          ],
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: section,
                onDestinationSelected: (v) => setState(() => section = v),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder_rounded),
                    label: 'Library',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.history_rounded),
                    label: 'Recent',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.star_outline_rounded),
                    selectedIcon: Icon(Icons.star_rounded),
                    label: 'Favorites',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings_rounded),
                    label: 'Settings',
                  ),
                ],
              ),
      );
    },
  );
}
