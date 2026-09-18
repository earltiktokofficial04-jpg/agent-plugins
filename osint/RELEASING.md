# Releasing

CI builds **unsigned** release APKs on every push and uploads them as the
`osint-app-release-apks` artifact. No signing key exists in this repository or
in GitHub Actions, so nothing secret has to be stored anywhere — you sign the
artifact yourself, with a key only you hold.

## What CI produces

Three per-ABI APKs, from `build/app/outputs/apk/release/`:

| File | Size | For |
|---|---|---|
| `app-arm64-v8a-release-unsigned.apk` | ~37MB | Almost every phone since 2017 |
| `app-armeabi-v7a-release-unsigned.apk` | ~29MB | Older 32-bit ARM devices |
| `app-x86_64-release-unsigned.apk` | ~40MB | Emulators, x86 tablets |

A universal APK is ~96MB, because the ML Kit OCR and barcode models ship for
each architecture. Splitting is why the download is a third of that.

**Do not use the copies in `build/app/outputs/flutter-apk/`.** Flutter copies
the artifacts there while dropping the `-unsigned` suffix, so files named
`app-arm64-v8a-release.apk` are in fact unsigned. Verified: `apksigner verify`
reports `DOES NOT VERIFY — Missing META-INF/MANIFEST.MF` on both.

## Signing one

Once only, make a keystore and keep it somewhere you will not lose it. Losing
it means never being able to update an installed app again — Android refuses an
update signed by a different key.

```bash
keytool -genkeypair -v \
  -keystore ~/osint-release.keystore \
  -alias osint -keyalg RSA -keysize 2048 -validity 10000
```

Then, per build:

```bash
apksigner sign \
  --ks ~/osint-release.keystore \
  --ks-key-alias osint \
  --out app-arm64-v8a-release.apk \
  app-arm64-v8a-release-unsigned.apk

apksigner verify --verbose app-arm64-v8a-release.apk
```

`apksigner` lives in `$ANDROID_HOME/build-tools/<version>/`.

No `zipalign` step is needed. Gradle already aligns the output — confirmed with
`zipalign -c -v 4`, which reports `Verification successful` — and `apksigner`
requires alignment to happen *before* signing, not after. Running zipalign on
an already-signed APK breaks the signature.

A correct result reports:

```
Verifies
Verified using v2 scheme (APK Signature Scheme v2): true
Verified using v3 scheme (APK Signature Scheme v3): true
```

## Signing in the build instead

If you would rather Gradle sign during the build, put `key.properties` next to
`android/app/` — that is, at `osint/osint_app/android/key.properties`:

```properties
storeFile=/absolute/path/to/osint-release.keystore
storePassword=…
keyAlias=osint
keyPassword=…
```

The build picks it up automatically and emits signed APKs under the same
names, minus the `-unsigned`. The file is gitignored, along with `*.keystore`
and `*.jks`, so it cannot be committed by accident.

Do not add it to CI. It would mean a keystore and its passwords living in
GitHub secrets, which is a larger thing to protect than an unsigned artifact
is to sign.

## Play Store

Play wants an app bundle rather than APKs, and will re-sign it with its own
upload key:

```bash
flutter build appbundle --release
```

Read `../SOURCES.md` first. Several data sources this app queries restrict
their free tier to non-commercial use, which is a licensing question that
distribution makes real.
