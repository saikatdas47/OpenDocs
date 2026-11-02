# Release signing and local handoff

Current version: 1.0.2+5. The ARM64 split APK versionCode is 2005.

The current signed APK is stored beside this repository in the parent OpenDocs folder. APK files and generated engine binaries are deliberately ignored by Git. Upload the APK as a GitHub Release attachment when you choose to publish it.

## This Mac

The existing release key is retained in the private, ignored `.signing/` folder. Its ignored settings are in `android/key.properties`. Preserve both to produce compatible future updates. Do not add either to Git or share the passwords.

## Another computer or contributor

Restore the original signing credentials securely if you are maintaining this app's update identity. Otherwise create your own keystore. Place the following properties in `android/key.properties` using your real local values:

```properties
storeFile=../.signing/your-release-key.p12
storePassword=YOUR_LOCAL_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_LOCAL_KEY_PASSWORD
```

Paths are relative to the Android project directory. The release build intentionally fails when signing configuration is missing. Debug builds do not need release credentials.

```bash
python3 scripts/prepare_engine.py
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

## Push this repository

The existing Git repository and remote are preserved. The handoff is committed locally; no remote push or GitHub release upload is performed. Use GitHub Desktop's Push origin or run `git push` from this folder.
