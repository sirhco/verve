# Windows native backend — 4-feature implementation plan

Scope: close the four remaining Windows desktop gaps in `ROADMAP.md`
(rich WinRT Toast, updates-apply, image clipboard, a11y UIA provider).
All four are hand-rolled COM/WinRT against `src/desktop/windows.zig`'s
existing vtable-offset idiom (`vtSlot`, `extern struct { lpVtbl }`,
`callconv(.winapi)`).

**Verification constraint:** this dev machine is macOS. Every change is
cross-compile-only here (`zig build -Dtarget=x86_64-windows -Ddesktop`);
behavior (crashes from wrong vtable offsets / GUIDs) only shows on the
real Windows host now available (v0.1.36). Each bundle ends with a
"verify on host" checklist, not a green local test.

Suggested order: **3 → 4 → 1 → 2** (rising COM complexity; clipboard and
a11y are self-contained, Toast needs shortcut/AUMID registration, updates
needs a detached-helper dance).

---

## Bundle A — Image clipboard (CF_DIB / CF_DIBV5)  [smallest]

**Files:** `src/desktop/windows.zig` (replace stubs at 2991–3001),
`src/desktop/clipboard.zig` (doc-comment update), both `build.zig`
templates, `docs/19-clipboard*`/roadmap notes.

**Problem:** clipboard wire format is raw PNG bytes (macOS parity). Windows
clipboard image format is `CF_DIB` (BITMAPINFOHEADER + BGR rows, bottom-up)
or `CF_DIBV5` (BITMAPV5HEADER, carries alpha). Need PNG↔DIB transcode.
Zig std has no PNG codec → use **WIC** (`windowscodecs`).

**`clipboardWriteImage(window, png)`:**
1. `CoInitializeEx` (already-init tolerated via `S_FALSE`/`RPC_E_CHANGED_MODE`).
2. `IWICImagingFactory` via `CoCreateInstance(CLSID_WICImagingFactory,
   IID_IWICImagingFactory)`.
3. PNG bytes → `IWICStream::InitializeFromMemory` →
   `CreateDecoderFromStream` → frame 0 → `WICConvertBitmapSource` to
   `GUID_WICPixelFormat32bppBGRA`.
4. Read pixels (`CopyPixels`) into a top-down BGRA buffer; build a
   `BITMAPV5HEADER` (32bpp, `BI_BITFIELDS`, BGRA masks, negative height for
   top-down) + pixel array into one `GlobalAlloc(GMEM_MOVEABLE)` block.
5. `OpenClipboard(hwnd)` / `EmptyClipboard` / `SetClipboardData(CF_DIBV5,
   h)` / `CloseClipboard`. Mirror the ownership rule already used at
   `clipboardWriteText` (free handle only on `SetClipboardData == null`).

**`clipboardReadImage(window, allocator)`:**
1. `IsClipboardFormatAvailable(CF_DIBV5 || CF_DIB)` → else `null`.
2. `GetClipboardData`, `GlobalLock`, parse header (handle both V5 and
   classic, top-down vs bottom-up, 24 vs 32 bpp).
3. Wrap pixels in a WIC bitmap → `IWICBitmapEncoder(GUID_ContainerFormatPng)`
   → `IWICStream` over an `IStream` on `GlobalAlloc` (or `SHCreateMemStream`)
   → encode → copy PNG bytes out with `allocator`.

**New externs/GUIDs:** `CoCreateInstance`, `CoInitializeEx`,
`CLSID_WICImagingFactory`, `IID_IWICImagingFactory`, the WIC pixel-format
GUIDs, `CF_DIB=8`/`CF_DIBV5=17`, `BITMAPV5HEADER`. Reuse `IStreamW`
(already declared at 401). Link **`Windowscodecs`** + **`Gdi32`** (BITMAP
structs need nothing to link, but keep Gdi32 in case of `CreateDIBitmap`
fallback) in both templates' `.windows` block.

**Risk:** WIC vtable offsets are long chains. Keep each interface a thin
`extern struct { lpVtbl }` + `vtSlot` with named `SLOT_*` consts, matching
the WebView2 code. Bottom-up/stride math is the classic bug — unit-test the
header builder as a pure fn (`dibHeaderFor(w,h)`), runnable on macOS.

**Verify on host:** copy an image in Paint → app `readImage` returns valid
PNG; app `writeImage` → paste into Paint/Word shows the image with alpha.

---

## Bundle B — a11y UIA provider (role-description + subrole)

**Files:** `src/desktop/windows.zig` (replace the three no-op methods at
1283–1301 + new provider section), both templates' `build.zig`, roadmap +
`docs` a11y note. `options.zig` already has `AccessibilitySubrole`.

**Approach:** minimal server-side UIA provider on the host HWND.
1. Store on `Window`: `a11y_role_desc: ?[]u8`, `a11y_subrole:
   AccessibilitySubrole`, `a11y_help: ?[]u8` (dupe into the window's
   allocator; free on destroy).
2. Handle `WM_GETOBJECT` in the window proc: if `lParam == UiaRootObjectId
   (-25)`, return `UiaReturnRawElementProvider(hwnd, wParam, lParam,
   provider)` where `provider` is our `IRawElementProviderSimple`.
3. Implement `IRawElementProviderSimple` (vtbl: QI/AddRef/Release +
   `get_ProviderOptions`, `GetPatternProvider`→null, `GetPropertyValue`,
   `get_HostRawElementProvider`→`UiaHostProviderFromHwnd`).
   - `GetPropertyValue(UIA_LocalizedControlTypePropertyId=30004)` → role
     description string (VARIANT BSTR via `SysAllocString` on UTF-16).
   - `GetPropertyValue(UIA_ControlTypePropertyId=30003)` → map subrole →
     control type (`dialog`/`system_dialog` → `UIA_WindowControlTypeId
     50032` / pane, `floating` → window, `standard` → window).
   - `get_ProviderOptions` → `ProviderOptions_ServerSideProvider (1)`.
4. `setAccessibilityRoleDescription` / `setAccessibilitySubrole` /
   `setAccessibilityHelp`: store the value, then
   `UiaRaiseAutomationPropertyChangedEvent` if a client is listening
   (`UiaClientsAreListening`). `setAccessibilityLabel` keeps delegating to
   `setTitle` (the UIA Name still flows from window text).

**New externs:** `UiaReturnRawElementProvider`, `UiaHostProviderFromHwnd`,
`UiaRaiseAutomationPropertyChangedEvent`, `UiaClientsAreListening`,
`SysAllocString`/`SysFreeString` (OleAut32 — already linked),
`VARIANT`/`SAFEARRAY` minimal structs. Link **`Uiautomationcore`**.
`UiaRootObjectId = -25`.

**Risk:** provider lifetime — return a single process-static provider
struct (no per-call alloc) with no-op AddRef/Release (pattern already at
`comAddRef1`/`comRelease1`). VARIANT layout must be exact; unit-test the
subrole→control-type mapping as a pure fn on macOS.

**Verify on host:** Accessibility Insights / Narrator focus on the window
announces the custom role description; subrole reflected in the control
type. Confirm no crash when no AT client is attached.

---

## Bundle C — Rich WinRT Toast (ToastNotificationManager + AUMID + shortcut)

**Files:** new `src/desktop/windows.zig` toast section, `notifications.zig`
(`showWindows` prefers Toast, falls back to `showWindowsBalloon`), both
templates' `build.zig`, roadmap.

**Two halves:**

**C1 — AUMID + Start-menu shortcut (prereq; Toast silently no-ops without
it).**
- `SetCurrentProcessExplicitAppUserModelID(L"Verve.<App>")` (Shell32) at
  startup / lazily before first Toast.
- Ensure a `.lnk` in `%APPDATA%\Microsoft\Windows\Start Menu\Programs`
  carrying `System.AppUserModel.ID` matching the AUMID: `IShellLinkW`
  (`CoCreateInstance CLSID_ShellLink`) → `SetPath(selfExe)` →
  `IPersistFile::Save`; before save, `QueryInterface(IID_IPropertyStore)`
  → `SetValue(PKEY_AppUserModel_ID, AUMID)` → `Commit`. Create once
  (skip if present).

**C2 — Toast emission.**
- `RoInitialize(RO_INIT_MULTITHREADED)` (tolerate `S_FALSE`).
- `WindowsCreateStringReference`/`WindowsCreateString` for class IDs.
- `RoGetActivationFactory(HSTRING
  "Windows.UI.Notifications.ToastNotificationManager",
  IID_IToastNotificationManagerStatics)`.
- `RoActivateInstance("Windows.Data.Xml.Dom.XmlDocument")` →
  `IXmlDocument::LoadXml(toastXml)` with a `ToastGeneric` template string
  built from title+body (escape XML).
- `IToastNotificationManagerStatics::CreateToastNotifier(AUMID)` →
  `RoActivateInstance` an `IToastNotification` from the XML
  (`IToastNotificationFactory::CreateToastNotification`) →
  `IToastNotifier::Show(toast)`.

**New externs:** `runtimeobject` (`RoInitialize`, `RoGetActivationFactory`,
`RoActivateInstance`, `WindowsCreateString*`, `WindowsDeleteString`),
`Propsys` (`PSGetPropertyKeyFromName` or hard-code `PKEY_AppUserModel_ID`),
Shell32 `SetCurrentProcessExplicitAppUserModelID`. Need the WinRT IIDs for
`IToastNotificationManagerStatics`, `IToastNotificationFactory`,
`IToastNotifier`, `IXmlDocument`, `IXmlDocumentIO`. Link
**`RuntimeObject`** + **`Propsys`**.

**`notifications.zig` wiring:** `showWindows` → try `windows.showToast(...)`;
on `error.Unsupported`/`error.Backend` fall back to the existing balloon so
behavior never regresses. Drop the "needs tray.init" coupling for the Toast
path (Toast doesn't need a tray icon).

**Risk:** biggest bundle (~450 LOC), most IIDs to get exactly right, and
the shortcut step is the classic "Toast silently does nothing" trap.
HSTRING lifetime: delete every created string. Keep the XML builder a pure
fn (`buildToastXml(buf, title, body)`) — unit-testable on macOS.

**Verify on host:** first call creates the Start-menu shortcut; Toast
appears in the top-right and lands in Action Center with the app name.
Confirm balloon fallback when run unpackaged/headless.

---

## Bundle D — Updates apply (Windows)

**Files:** `src/desktop/updates.zig` (Windows branch in `applyUpdate` +
helpers), roadmap.

**Constraint:** a running `.exe` is file-locked → can't be overwritten in
place. Squirrel/MSIX both need external tooling + code-signing infra we
can't exercise here. Plan the **pure-Zig detached-helper swap** (same
no-third-party-dep philosophy as the macOS path), leaving a documented
Squirrel hook for apps that want it.

**Algorithm (`applyUpdateWindows`):**
1. `GetModuleFileNameW` → current exe path; resolve install dir.
   `error.NotBundled` if running from `zig-out\bin` dev layout (match the
   macOS bare-binary guard heuristically, e.g. path contains `\zig-out\`).
2. Download `info.download_url` (reuse `downloadAndVerify` — it's already
   platform-neutral) into a staging dir under `%LOCALAPPDATA%` or next to
   the install (same volume).
3. Extract the `.zip` with **`std.zip`** (in-process, no PowerShell dep) to
   `staging\new\`.
4. Write a tiny self-deleting helper `.cmd` to staging that: waits for the
   parent PID to exit (`:loop tasklist /FI "PID eq <pid>" ... timeout`),
   `robocopy`/`xcopy /e /y` the new tree over the install dir, relaunches
   the exe, deletes itself.
5. `CreateProcessW`/`std.process.spawn` the helper detached
   (`CREATE_NO_WINDOW`/`DETACHED_PROCESS`), then `std.process.exit(0)` so
   the parent releases its lock.

**New bits:** `GetModuleFileNameW`, `GetCurrentProcessId`, helper-script
writer, `std.zip` extraction (verify the std API shape for 0.16). Reuse
`downloadAndVerify`, `bytesToHexLower`, the `ApplyError` set (add nothing
or add `HelperSpawnFailed`).

**Risk:** the helper dance is fiddly and only fully testable on host. Keep
the `.cmd` generation a pure fn (`buildSwapScript(buf, pid, src, dst,
exe)`) → unit-test the emitted script text on macOS. Document clearly that
this is unsigned side-by-side replacement, not Squirrel delta/MSIX.

**Verify on host:** stand up a feed + zipped newer build; app applies,
relaunches into the new version, no leftover staging/helper files.

---

## Cross-cutting

- **build.zig (both templates):** add `Windowscodecs`, `Uiautomationcore`,
  `RuntimeObject`, `Propsys` (+ `Gdi32` if needed) to the `.windows`
  `linkSystemLibrary` block. `verve-cli` embeds the template tree, so the
  scaffold inherits the links automatically — no separate scaffold edit.
- **Pure-fn carve-outs** (header builder, subrole map, toast XML, swap
  script) are the only things unit-testable on this macOS machine; wire
  each into the desktop test suite so `zig build test` covers the logic
  even though the COM calls can't run here.
- **Doc sync:** flip the four `⏳` lines in `ROADMAP.md` + the matching
  rows in `docs/11-desktop-roadmap.md` to ✅/🟡 with the bundle note, per
  the repo's "keep this file in sync" rule.
- **No `src/verve.zig` edits** — these are desktop-internal; the public
  surface (`Clipboard`, `notifications.show`, `Window.setAccessibility*`,
  `updates.applyUpdate`) is unchanged.

## Estimate
A ≈ ~200 LOC · B ≈ ~300 LOC · C ≈ ~450 LOC · D ≈ ~180 LOC. Each shippable
independently; recommend landing one bundle per PR with its host-verify
checklist.
