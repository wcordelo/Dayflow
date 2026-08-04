# Platform capability matrix

The product promise is one shared Dayflow record, not identical OS behavior.
Every client reports `capture_permission`, `capture_session`, `capture_paused`,
and `derived_sync` state in its settings/status UI. Capture adapters pass the
full context through the shared Rust privacy decision ABI; application/window
block rules are evaluated before a sample can reach a local derivation sink.
On Mac, the adapter supplies frontmost or selected-source application and
window-title signals so private browsing, meeting, protected-playback, and
sensitive-code contexts can be paused before persistence. The Mac source
selection is persisted locally and rebuilt against each fresh
ScreenCaptureKit snapshot, so a closed window or display cannot be silently
replaced by another surface.

| Capability | Mac | Windows | Android | ChromeOS | iOS |
| --- | --- | --- | --- | --- | --- |
| OS-wide display capture | ScreenCaptureKit display/app/window selection | Windows.Graphics.Capture display/window selection with one guarded picker/session at a time | MediaProjection with user-approved session and foreground-service handshake | Android MediaProjection where supported by the Chromebook | Platform-dependent explicit session; feasibility gate |
| App/window capture | Yes | Yes | Single-app projection may be used | Android app path; browser context is not assumed | App/session-specific only where permitted |
| Background capture | Desktop resident process | Desktop resident process | Foreground service/session rules | Android/ARC lifecycle and battery rules | Not assumed; explicit session and in-app fallback |
| Foreground metadata | App/window APIs | Foreground window APIs | App/task metadata where permitted | Android task/window metadata | App-owned activity metadata |
| Raw media sync | No by default | No by default | No by default | No by default | No by default |
| Derived event sync | Yes, encrypted | Yes, encrypted | Yes, encrypted | Yes, encrypted | Yes, encrypted |
| Offline operation | Full | Full | Full | Full where local storage permits | Full for journaling; capture tier may degrade |
| User pause / privacy gates | Required | Required | Required | Required | Required |

## Non-negotiable behavior

This is the target product contract. The current repository implements the Mac
path and source-level local-first sync, secure provider storage, device
administration, canonical account/auth surfaces, local projection/chat context,
journal event writes, recovery-kit surfaces, full privacy-decision evaluation,
privacy-gated capture seams, and direct on-device provider execution for the
other clients. Target-OS packaging, native capture/device testing, provider
network policy validation, and production auth/deployment gates remain release
work as recorded in `DELIVERY_GATES.md`.

1. A denied permission produces an explicit inactive state; it is never treated as
   “probably capturing.”
   A privacy pause also reports an inactive permission/session state because
   clearing the pause never resurrects the previous platform capture token.
2. Repeated start actions cannot create overlapping capture sessions, and a
   stop/lifecycle transition cannot allow a late picker or service callback to
   resurrect capture.
3. Lock, sleep, private/incognito context, DRM, explicit pause, and permission
   revocation stop capture before a frame is persisted.
4. Each client can track activity and journal edits locally even when capture is
   unavailable or the network is offline.
5. The user sees whether a record is local-only, pending encrypted sync, synced,
   or unavailable on this device.

## Native references

- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Windows Graphics Capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)
- [Android MediaProjection](https://developer.android.com/media/grow/media-projection)
- [ChromeOS Android app guidance](https://developer.android.com/topic/arc)
- [Chrome desktopCapture](https://developer.chrome.com/docs/extensions/reference/api/desktopCapture)
- [Apple ReplayKit](https://developer.apple.com/documentation/replaykit)
