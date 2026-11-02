import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native PDF engine opens, extracts text and renders pixels offline',
    () async {
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
      // Flutter test does not expose the native-assets manifest to this loader.
      // Use the actual binary downloaded by the dependency build hook.
      if (Platform.isMacOS) {
        final binary = Directory('.dart_tool/hooks_runner/shared/pdfium_dart')
            .listSync(recursive: true)
            .whereType<File>()
            .firstWhere((file) => file.path.endsWith('/libpdfium.dylib'));
        Pdfrx.pdfiumModulePath = binary.absolute.path;
      }
      await pdfrxFlutterInitialize();
      final doc = await PdfDocument.openData(
        await File('test/fixtures/sample.pdf').readAsBytes(),
      );
      try {
        expect(doc.pages.length, 1);
        final text = await doc.pages.first.loadText();
        expect(text?.fullText, contains('OpenDocs offline PDF'));
        final image = await doc.pages.first.render(
          width: 150,
          height: 150,
          fullWidth: 150,
          fullHeight: 150,
        );
        expect(image, isNotNull);
        expect(image!.pixels.length, 150 * 150 * 4);
        expect(image.pixels.any((pixel) => pixel < 128), isTrue);
        image.dispose();
      } finally {
        await doc.dispose();
      }
    },
  );
}
