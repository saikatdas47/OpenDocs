# OpenDocs privacy

Documents are read locally on your device. The app has no account, analytics, advertising or document-upload service. The release APK requests no internet permission.

Storage access is optional. Broad access is used only to locate supported documents in shared storage. You can instead choose folders or individual files. OpenDocs stores a local index containing file names/locations, sizes, timestamps, favorites, page bookmarks, recent history and reading positions. Imported and externally shared files are copied into private app storage so temporary grants do not interrupt reading. A temporary render cache is stored locally.

Original files are not modified or deleted by library removal. You can remove library entries in the app, disconnect selected folders in Settings, revoke broad storage access in Android Settings, or clear the app data/uninstall to remove its private metadata and copies. The original documents remain in their original locations. Android backups are disabled for this app.

DOC/DOCX and PPT/PPTX conversion runs inside an isolated local Android process using the bundled LibreOffice engine. It works from a private input snapshot, creates an image-based PDF in local cache, and does not require any network, Mac computer or external Office app. Cancelling or removing a library entry does not delete its original source.

First-page thumbnail images and converted PDFs are regenerated cache. Settings → Clear reader cache removes these outputs without removing original files, imported documents, bookmarks or library metadata. Office previews are generated after opening a document, not uploaded for remote processing.
