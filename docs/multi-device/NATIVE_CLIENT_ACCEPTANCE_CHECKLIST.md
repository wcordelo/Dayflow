# Native client acceptance checklist

This checklist is for the controlled technical alpha. A source build, emulator
run, or unsigned package is not evidence that a target-device gate passed.
Attach the command output, package identifier/version, device model/OS, and a
short screen recording or log for each completed section.

## Windows 11

### Build and package

- [ ] Restore `clients/windows/Dayflow.Windows/Dayflow.Windows.csproj` on
  Windows 11 with .NET 8, Windows App SDK, Rust/MSVC, and Visual Studio.
- [ ] Build x64 Rust and WinUI artifacts; repeat ARM64 when that package is
  offered to testers.
- [ ] Run `Dayflow.Windows.Tests` on the target host.
- [ ] Build an MSIX with a real package publisher, version, and signing
  certificate. The `CN=Dayflow` identity is a development placeholder only.
- [ ] Install, launch, upgrade, uninstall, and reinstall the signed MSIX.

### Capture and privacy

- [ ] Select a display and a window through the system picker.
- [ ] Confirm the visible Windows capture border is present.
- [ ] Confirm a second start cannot open a second picker/session.
- [ ] Cancel the picker, stop while the picker is open, and verify a late picker
  result cannot restart capture.
- [ ] Resize the selected window and move it across monitors.
- [ ] Close the selected source and verify the status becomes inactive.
- [ ] Lock, suspend, unlock, and resume Windows. Capture must remain stopped
  until the user makes a new picker choice.
- [ ] Revoke capture permission and verify the status is `revoked`.
- [ ] Exercise private/incognito, password, meeting, DRM, blocked application,
  and blocked title-fragment exclusions. No excluded frame may become a card.
- [ ] Verify the timeline card contains only the approved semantic
  classification, provenance, and derivation mode; it must not contain a
  window title or raw pixels.

### Local-first and wake behavior

- [ ] Create a journal entry and capture-derived card while offline.
- [ ] Restart the app and confirm local projection and queued-event state.
- [ ] Restore a recovery kit on a second Windows account/device.
- [ ] Verify WNS delivers exactly `{"kind":"sync_available"}` and that the
  background path performs the same bounded cursor sync as foreground activation.

## Chromebook / Android

### Build and distribution

- [ ] Build all required Rust ABIs with `scripts/build_dayflow_core_android.sh`.
- [ ] Use `./gradlew :app:assembleDebug :app:bundleRelease
  :app:testDebugUnitTest`; require release signing in the release job.
- [ ] Upload the signed AAB to a Play internal track and install it on each
  representative Chromebook.
- [ ] Verify versioned install and upgrade behavior with keyboard/mouse-only
  hardware.

### ChromeOS layout and capture

- [ ] Install on representative ARC devices covering at least one ARM64 and one
  x86_64 Chromebook where supported.
- [ ] Navigate every product route with keyboard and mouse; verify focus order,
  resize behavior, and no horizontal clipping.
- [ ] Run the app in a resized window and beside another app in multi-window
  mode.
- [ ] Grant MediaProjection consent and verify the foreground notification.
- [ ] Stop capture, revoke permission, lock, sleep, shut down, and kill the
  process. Capture must not silently resume.
- [ ] Resize the captured window and move it between displays.
- [ ] Restart offline and verify local timeline, journal, and queued-event
  state.
- [ ] Measure battery, CPU, storage growth, and thermal behavior during a
  representative capture session.
- [ ] Verify each card uses `privacy_gated_local_visual_v1`, contains semantic
  visual/context output only, and never persists or syncs raw frames.

### Background sync

- [ ] Register a real FCM/provider token after account admission.
- [ ] Deliver the exact content-free wake signal.
- [ ] Verify physical `JobService` execution, retry behavior, and no wake payload
  content is interpreted as a Dayflow record.

## Shared release evidence

- [ ] Run two-device offline/online replay, approval, revocation, and key
  rotation on the target clients.
- [ ] Inspect production network traffic and prove raw media never leaves the
  source device.
- [ ] Validate native secure-store recovery and wrong-passphrase rejection.
- [ ] Record results in `docs/multi-device/VALIDATION_LOG.md`; keep unchecked
  items open rather than promoting source-only checks to verified.
