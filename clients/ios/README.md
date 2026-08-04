# Dayflow for iOS

This SwiftUI package is the first native iOS client foundation. It shares the
event envelope and core boundary with the Mac client while making capture
capability explicit: an iOS capture session is user-started, stoppable, and
subject to ReplayKit availability and app lifecycle. The app remains useful
through in-app activity and journaling when unattended OS-wide capture is not
available. `DayflowMobileSyncSession` adds the complete native local-first
loop: Keychain custody, encrypted SQLite envelopes, outbox retry, signed relay
requests, wrapped-key admission, cursor replay, and local Rust projections.
`DayflowAIProviderStore` keeps route metadata and API keys in Keychain. The
SwiftUI chat surface builds a bounded prompt from the local projection and calls
Ollama, Gemini, or an OpenAI-compatible endpoint directly; the sync relay is not
used for inference. `enqueueCaptureDerived` seals locally derived metadata plus
its source and derivation mode into SQLite without persisting raw frames. Device list, approval, and revocation are exposed through the same
signed relay client as sync.
The ReplayKit session evaluates application/window context through the shared
Rust privacy decision API before counting a sample.

`DayflowMobile.xcodeproj` is the installable SwiftUI application target. It
consumes the local `DayflowMobile` package and keeps signing, TestFlight, and
device capture behavior in the application/release layer rather than hiding
those gates inside package tests.

## Inspect/build

On macOS with Xcode:

```sh
bash scripts/verify_dayflow_setup.sh
bash scripts/build_dayflow_core_ios_xcframework.sh
swift package dump-package --package-path clients/ios
swift build --package-path clients/ios

ios_sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
swift build --package-path clients/ios --sdk "$ios_sdk_path" --triple arm64-apple-ios17.0

simulator_sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build --package-path clients/ios --sdk "$simulator_sdk_path" --triple arm64-apple-ios17.0-simulator

xcodebuild -project clients/ios/DayflowMobile.xcodeproj -scheme DayflowMobileApp \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The first command creates the ignored `shared-core/dist/DayflowCoreiOS.xcframework`
consumed by the package. It intentionally refuses to overwrite an existing
framework; move the generated directory aside before rebuilding it after a Rust
core change.

The explicit SDK and application-target builds above validate the iOS source,
package/link, and installable app seams. The TestFlight target, ReplayKit
broadcast extension, signing, device capture lifecycle, and App Store review
are still release gates. They are not inferred from a package build.

Reference: [Apple ReplayKit](https://developer.apple.com/documentation/replaykit).
