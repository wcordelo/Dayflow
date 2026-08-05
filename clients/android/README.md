# Dayflow for Android and ChromeOS

The Android client is the primary Chromebook client. It is one Compose codebase
with adaptive layout and an explicit MediaProjection capture session. ChromeOS
does not get a separate browser companion product.

## Build

On a machine with Android Studio/SDK and a JDK supported by the pinned Android
Gradle Plugin, open `clients/android` in Android Studio and run the Gradle
tasks below, or use an installed `gradle` executable. Gradle needs the SDK
location in the current shell; this resolves the common Homebrew and per-user
locations without writing a machine-specific `local.properties` file:

```sh
android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "${android_sdk}" ]]; then
  for android_sdk_candidate in \
    /opt/homebrew/share/android-commandlinetools \
    /usr/local/share/android-commandlinetools \
    "${HOME}/Library/Android/sdk"; do
    if [[ -d "${android_sdk_candidate}/platforms" && -d "${android_sdk_candidate}/build-tools" ]]; then
      android_sdk="${android_sdk_candidate}"
      break
    fi
  done
fi
if [[ -z "${android_sdk}" ]]; then
  printf '%s\n' "Set ANDROID_HOME or ANDROID_SDK_ROOT to a valid Android SDK." >&2
  exit 1
fi
export ANDROID_HOME="${android_sdk}"
export ANDROID_SDK_ROOT="${android_sdk}"
```

Then run:

```sh
gradle :app:assembleDebug
gradle :app:bundleRelease
gradle :app:testDebugUnitTest
gradle :app:connectedDebugAndroidTest
```

Build the Rust shared library before assembling a package:

```sh
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
ANDROID_NDK_HOME="$ANDROID_NDK_HOME" bash scripts/build_dayflow_core_android.sh
gradle :app:assembleDebug
gradle :app:bundleRelease
```

The script copies the Rust `cdylib` into the Android ABI-specific `jniLibs`
directories and the generated UniFFI Kotlin binding is compiled by the app.
The Gradle `preBuild` task verifies all three packaged ABIs and checks a
required generated-UniFFI export, failing with a rebuild message if a library
is missing or stale instead of producing an APK that can only fail when the
Rust bridge is first called.
The local SQLite outbox stores opaque encrypted envelopes and sync metadata;
timeline, journal, and chat projections are rebuilt from that event log rather
than persisted as plaintext cache rows.
The repository includes a pinned `gradlew` bootstrap so CI and release
operators do not depend on a globally installed Gradle. Android Studio can
still supply the same pinned tooling.
`bundleRelease` produces the unsigned Play-upload bundle at
`app/build/outputs/bundle/release/app-release.aab`; upload signing, Play
Console validation, and a physical-device/Chromebook install remain release
gates.

For a release build, provide the keystore properties without committing them:

```sh
./gradlew :app:bundleRelease \
  -PdayflowRequireReleaseSigning=true \
  -PdayflowReleaseKeystore=/secure/dayflow-upload.jks \
  -PdayflowReleaseKeystorePassword="$DAYFLOW_ANDROID_KEYSTORE_PASSWORD" \
  -PdayflowReleaseKeyAlias="$DAYFLOW_ANDROID_KEY_ALIAS" \
  -PdayflowReleaseKeyPassword="$DAYFLOW_ANDROID_KEY_PASSWORD" \
  -PdayflowVersionCode=2 \
  -PdayflowVersionName=0.1.0-alpha02
```

The local validation environment used JDK 21, Gradle 9.6.1, Android SDK
Platform 36, Build Tools 36.0.0, and NDK 27.2.12479018. The manifest points at a network
security configuration that denies cleartext by default and names only
loopback hosts as exceptions for local model development; account, relay, and
provider validation reject non-loopback HTTP as a second guard.

Capture behavior follows Android's platform contract: the user consents before
each session, the app requires a visible notification before starting the
media-projection foreground service, the session stops on
`MediaProjection.Callback.onStop()`, and frames are closed after local
derivation. Display/configuration changes and
`MediaProjection.Callback.onCapturedContentResize()` replace the ImageReader
surface and resize the virtual display on the capture thread so Chromebook
window resizing does not leave a stale capture buffer. `DayflowAndroidSyncSession` now owns the corresponding
local SQLite outbox, Android Keystore custody, signed relay requests, wrapped
account-key admission, cursor replay, and Rust projection handoff. ChromeOS
uses the same client and adds adaptive keyboard/mouse, resize, multi-window,
and offline-storage behavior. The main surface is scrollable and
width-constrained so the same flow remains usable on a phone, a resizable
tablet window, and a Chromebook. `DayflowAIProviderStore` keeps provider routing
and API keys behind the Keystore. The Compose chat surface builds a bounded
prompt from the local projection and calls Ollama, Gemini, or an
OpenAI-compatible endpoint directly; the sync relay is not involved in
inference. `enqueueCaptureDerived` seals locally derived cards plus their
source and derivation mode into the outbox without persisting raw frames. The
current MediaProjection adapter uses `privacy_gated_local_visual_v1`: it
samples a bounded visual profile in memory and emits only the semantic card. A
richer on-device model can replace that worker without changing the envelope
shape.
Each MediaProjection frame is closed after a shared Rust privacy decision that
includes the current application/window context and block policy.

`DayflowAndroidPushWakeAdapter` is the provider boundary for FCM: a messaging
service may hand its data map to `intentForData`, and only the exact
`{"kind":"sync_available"}` shape reaches the existing receiver and bounded
`JobService` sync. Provider credentials and the physical background-delivery
test remain release-host work.

`app/src/androidTest` contains the executable UniFFI smoke test. It seals and
projects a journal event through the packaged Rust library, checks the shared
privacy decision, exercises recovery-key versions, and asserts the canonical
request vector. All 7 tests passed locally on an API 36 arm64 emulator after
the ABI libraries were rebuilt; run `connectedDebugAndroidTest` on an emulator
or Android/ChromeOS device for subsequent changes.

References: [MediaProjection](https://developer.android.com/media/grow/media-projection),
[Network security configuration](https://developer.android.com/privacy-and-security/security-config),
and [Build for ChromeOS](https://developer.android.com/develop/devices/chromeos/learn).
