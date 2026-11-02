import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opendocs/data/reader_bookmarks.dart';
import 'package:opendocs/data/document_repository.dart';
import 'package:opendocs/data/document_thumbnails.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'bookmarks survive reload, stay per document, and can be removed',
    () async {
      await ReaderBookmarks.save('exam', [8, 2, 8, 0, -1]);
      expect(await ReaderBookmarks.load('exam'), [2, 8]);
      expect(await ReaderBookmarks.load('other'), isEmpty);
      await ReaderBookmarks.save('exam', [8]);
      expect(await ReaderBookmarks.load('exam'), [8]);
    },
  );
  test(
    'reader cache clear leaves bookmark and library metadata intact',
    () async {
      await ReaderBookmarks.save('exam', [3]);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('library.v1', ['keep this metadata']);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(StorageBridge.channel, (call) async {
            expect(call.method, 'clearReaderCache');
            return {'freed': 1024};
          });
      final result = await DocumentThumbnails.clearCache();
      expect(result['freed'], 1024);
      expect(await ReaderBookmarks.load('exam'), [3]);
      expect(prefs.getStringList('library.v1'), ['keep this metadata']);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(StorageBridge.channel, null);
    },
  );
}
