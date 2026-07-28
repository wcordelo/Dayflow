# M0 Runbook — Native Surface Validation (developer Mac)

**Contract:** ADHD Companion Implementation Contract **v2.3** §5  
**Audience:** developers on a Mac (Sequoia+ recommended)  
**Timebox:** 1–2 days  
**Output:** Fill `docs/adhd-companion/M0_RESULTS.md` from `M0_RESULTS.template.md`  
**Broader checklist:** [`docs/adhd-companion/BETA_READINESS.md`](../../docs/adhd-companion/BETA_READINESS.md) (full path to private beta)

> **This Linux Cloud Agent environment cannot execute native M0.**  
> There is no ScreenCaptureKit, no Xcode, no macOS window server, and no TCC here.  
> Do **not** treat any Cloud Agent work as an M0 pass. M0 is Mac-only.

**Build policy (v2.3):** Product scaffold already proceeds in `adhd-companion/`. M0 is a **parallel** validation of capture indicator, NSPanel L3, and TCC — prefer running against the **product** binary (`com.adhdcompanion.app`). A throwaway spike is optional.

Prefer **(a) ∧ (b) ∧ (e)** before private beta install. Failures → swap backends; do not freeze M1–M6.

---

## 0. Before you start

- [ ] Apple ID → free **Apple Development** cert in Xcode or Keychain
- [ ] Stable bundle ID `com.adhdcompanion.app` (product) or `.m0` for scratch
- [ ] Prefer product app under `adhd-companion/` (`npm run tauri build` / `tauri dev` on Mac)
- [ ] Copy results template → `docs/adhd-companion/M0_RESULTS.md` (omit personal names / emails)

---

## 1. Signing / TCC — criterion (e)

On Sequoia+, ad-hoc / unsigned debug binaries often **fail** Screen Recording TCC. Do this **before** measuring capture indicator (a).

| Step | Action |
|---|---|
| 1 | Create/select Apple Development identity (Team ID present) |
| 2 | Set stable bundle ID on the `.app` |
| 3 | `Info.plist`: `NSScreenCaptureUsageDescription` (+ notification usage if testing UN) |
| 4 | Codesign the `.app` with that development identity |
| 5 | Grant **Screen Recording** to **that** app in System Settings |
| 6 | Relaunch; confirm `CGPreflightScreenCaptureAccess()` is true |
| 7 | If bundle ID changes: `tccutil reset ScreenCapture` and re-grant |

**Checklist**

- [ ] (e) Screen Recording survives relaunch with TCC toggle on

---

## 2. Capture candidates — criterion (a)

Run **C then A**; B only as orange-pill control.

| Candidate | How |
|---|---|
| **C** Event-driven stills | Product default — app_switch / window_focus / idle_fallback |
| **A** Timer stills | ~10s periodic control |
| **B** Stream ≤1 FPS | Expect persistent indicator |

**Checklist**

- [ ] (a) ≥30 min interactive with chosen API — no persistent orange pill

---

## 3. L2 / L3 panels — criterion (b)

- [ ] (b) L3 visible/clickable over YouTube/Netflix fullscreen on **another Space**
- [ ] (b) L2 floats on all Spaces (`CanJoinAllSpaces | FullScreenAuxiliary | Stationary`)

---

## 4. Notifications — criterion (c)

- [ ] (c) Notification click → opens L2 or bus event (non-fatal if fail; L1 click→L2 fallback OK)

---

## 5. Event bus — criterion (d)

- [ ] (d) app-switch events within ~1s
- [ ] (d) idle-return events within ~1s

---

## 6. Sleep / lock — criterion (f)

- [ ] (f) Capture pauses on lock/sleep; resumes on unlock; no black-frame spam

---

## 7. Record go/no-go

Fill `M0_RESULTS.md`. Private beta readiness prefers **(a) ∧ (b) ∧ (e)**. Product development continues regardless.
