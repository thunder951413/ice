# macOS 27 compatibility

This build was developed on macOS 27.0 (26A428), using Xcode 27.0 (27A266a).

## Research and implementation

macOS 27 renders status items through MenuBarAgent. The former per-item
WindowServer windows and oversized-divider hiding mechanism no longer apply.
Ice now selects the AX discovery / native visibility backend on macOS 27;
macOS 26 and earlier retain physical dividers.

Sources consulted:

- [Thaw's public macOS 27 preview implementation](https://github.com/thaw-app/Thaw/tree/macos-27-preview.1/Thaw/MenuBar/HiddenSectionPatch).
  In particular `AssessmentModeBackend.swift` and `ThawAssessmentModeHiding.m`.
- [Thaw's macOS 27 release limitations](https://github.com/thaw-app/Thaw/releases/tag/3.0.0-alpha.5).
- [Tuck's macOS 27 compatibility description](https://usetuck.com/macos-27-menu-bar-manager).

The Objective-C bridge is adapted from Thaw under GPL-3.0, retaining its
copyright attribution. It dynamically resolves MenuBarClientCore's
`MBAssessmentModeConfiguration` and `MBAssessmentModeAssertion`. These are
private, version-dependent interfaces, not a public Apple hiding API.
Missing classes/selectors or activation failure leave icons visible and report
an error in Menu Bar Layout.

The assertion receives an allowlist of running/discovered app owners, excluding
only owners assigned to concealed sections. All nine known core system-item
identifiers (0...8) and Ice's own bundle identifier are retained. The assertion
is held in memory and released on Show All, normal exit, and native reveal. It
does not change MenuBarAgent's preference file, require Full Disk Access, or
restart other applications. The earlier experimental mask implementation is
not instantiated by this build.

## Usage and boundaries

1. Install and launch `/Applications/Ice.app`, then grant it Accessibility permission in System Settings. A new
   locally signed build can need a new permission grant. Screen Recording is
   optional on macOS 27; layout and Ice Bar previews use app icons because the
   hosted window captures can be blank.
2. In Menu Bar Layout, click (or right-click) an app and choose Hidden or
   Always-Hidden. All status items
   belonging to that app move together, including items discovered later.
3. Click Ice to reveal/collapse the Hidden section. Run the installed application:
   the registered `/Applications/Ice.app` retains its native Ice icon while the
   development copy in DerivedData was suppressed by the same restriction. No
   extra recovery button is displayed. Empty menu-bar space also toggles Ice Bar;
   right-click that space for Settings and Show All. The original
   Show Ice icon and custom-icon preferences remain available. With Ice Bar enabled,
   concealed apps appear in its floating panel. Selecting an item reveals its
   owner, reacquires its live AX element, and activates the original menu.
4. Use General → Show All Hidden Items to clear Ice's assignments and release
   the restriction. Quitting Ice also releases it.

Layout-editor dragging is disabled on macOS 27 after unreliable native drop
callbacks were reproduced. Use its section menu for assignment and native
Command-drag in the menu bar. Some Apple extras (for example Focus or AirDrop)
can be suppressed by the private assertion despite preserving the core controls;
Show All or quitting restores access. Third-party icons from one application
cannot be hidden independently. Previews use the owning application icon, not a live image of a concealed
status item.

Hidden descriptors stay in Ice's cache while their owner is running, because
native hiding can remove them from AX enumeration or leave stale source-app
proxies. Concealed owners are explicitly excluded from coordinate clicks and
image capture so an old rectangle cannot target a neighboring icon. New unassigned apps default to
Visible. Section changes, app launches, wake, and Focus notifications reconcile
the allowlist; self-generated notifications are suppressed to avoid loops.

## Build and verification

```sh
./Scripts/build-local.sh
./Scripts/test-hosted-visibility-policy.sh
./Scripts/test-hosted-visibility.sh  # quit Ice first; briefly hides its own fixture
```

CompactSlider 1.1.6 is vendored at `Packages/CompactSlider`, with a minimal
SwiftUI overload disambiguation for Xcode 27. This preserves the existing API
and makes the fix reproducible without modifying DerivedData.

### Verification recorded on this machine (2026-09-19)

| Check | Result |
| --- | --- |
| Debug and universal arm64 + x86_64 Release, Xcode 27 | Passed |
| Seven owner-visibility policy regressions | Passed |
| Objective-C smoke compiled with warnings as errors | Passed |
| Native fixture hide / completion / restore | Passed, three consecutive cycles; observed rendered MenuBarAgent descendants |
| Assign Visible / Hidden using the layout menu | Passed, including left-click and right-click |
| Enable Always-Hidden, assign an app, disable section | Passed; disabled section restores its items |
| Open Ice Bar after closing Settings | Previous build passed; current build uses the existing empty-menu-bar click entry |
| Open original app menu from Ice Bar | Passed with Qwen TTS; read-only AX observer recorded its real 374 × 414 menu |
| Rehide after the original menu closes | Passed; target disappears from host |
| Show All from General and menu | Passed; assignments clear, original icons return |
| Quit / relaunch and stored assignment migration | Passed; old WeChat assignment migrated; normal exit restores icons |
| Terminated test process releases restriction | Passed during hang recovery |
| Idle responsiveness after menu tracking fix | Passed; previous main-thread event repost loop removed from macOS 27 path |
| Application signature verification | Passed with codesign --verify --deep --strict |

The original acceptance run restored WeChat in Hidden and removed temporary
Qwen assignments. The follow-up optimization preserves the user’s current
WeChat and Thunder assignments, Always-Hidden disabled, and Ice Bar enabled. The earlier failure
of the native smoke was caused by checking stale source-app frames; the test
now verifies the actual MenuBarAgent render tree and fails if its fixture exits.

Not exercised: physical display hot-plug, sleep/wake, full-screen/Spaces across
multiple monitors, an Intel Mac at runtime, macOS 26 or earlier at runtime, and
injected private-API activation failures. These paths have guards/reconciliation
logic, but build success is not a runtime pass. The compatibility implementation
uses a private interface and remains dependent on future macOS updates. This is
a locally development-signed build, not a notarized distribution.

The packaged build is `build/macOS27/Ice.app`, with a matching
`build/macOS27/Ice-macOS27.zip`, compatibility report, and SHA-256 checksum.

## UI and performance follow-up

- Removed the extra Ice recovery panel and its one-second monitoring timer.
- Hosted Ice Bar app icons are now 28 pt inside 44 pt click targets (formerly
  20 pt icons). Hover feedback, tooltips, accessibility labels/default actions,
  a nonzero empty-state message, and current-section menu checkmarks were added.
- Panel positioning uses the rendered Ice icon when available and the pointer
  otherwise, respecting display bounds. It never anchors to a shared host window.
- Menu-bar hit testing shares a 250 ms snapshot of MenuBarAgent's actionable
  leaves, including system controls. A click reacquires its activation target.
  The previous per-icon full-tree traversals were removed.
- Empty-space detection reserves each item's entire menu-bar-height column,
  including a small horizontal margin; icon edges do not toggle Ice Bar.
- Removed the unused three-second image capture loop on macOS 27 and repeated
  global AX hit tests for Ice's icon. Hover transitions have one pending task.
- Legacy captured icon dimensions remain unchanged on macOS 26 and earlier.

Short idle samples on the same machine (15 `ps` samples at one-second intervals):

| Metric | Before | After |
| --- | --- | --- |
| Mean sampled process CPU | 1.92% | 0.22% |
| Resident memory, last sample | 139.5 MiB | 120.5 MiB |

These are short observations with the existing user applications running, not
controlled long-term benchmarks. The follow-up Release and Debug builds and
three-cycle native visibility smoke passed. Visual/entry acceptance is tracked
separately; the current automation service rejects coordinates in menu-bar
blank space as having no owning window, so that exact click requires a manual
check rather than being reported as an automated pass.

## Independent Ice Bar surface and controls

The Bar now has its own rounded background, border and shadow, independent of
menu-bar screenshots and appearance settings. General settings offers Frosted
and Solid styles plus a Show Ice Bar preview. Light/dark appearance is supported;
Reduce Transparency selects an opaque surface. The obsolete color manager is no
longer instantiated, removing its screenshot work and five-second refresh timer.

The Bar includes search and options for arranging items, opening Bar settings,
restoring all items, and closing. Escape closes the Bar. A presentation generation
check prevents an older delayed auto-rehide task from closing a newly opened Bar.
No separate floating Ice launcher has been introduced.

Validation on 2026-09-19:

- Release (arm64 + x86_64) and Debug builds passed; code signature verified.
- Owner-visibility policy regressions and the three-cycle native smoke passed.
- `Scripts/test-icebar-surface.sh` rendered the actual surface in four combinations
  (light/dark × Frosted/Solid); center alpha was 1.0 in all four cases. These are
  offscreen component renders, not desktop screenshots.
- Native search entry, options → Menu Bar Layout, Escape and Solid persistence
  passed. Two hosted items have 44 × 44 pt hit targets and 28 pt app icons.
- With Smart auto-rehide enabled, the final build's settings preview remained
  visible after opening; Escape then removed its AX window. Auto-rehide remains
  enabled and the selected Bar style is Solid.

System Reduce Transparency/Increase Contrast and long overflow lists were not
runtime-tested. See [Bartender comparison](Bartender-comparison.md) for the
official-source feature matrix and remaining gaps.

## Compact Bar sizing follow-up

General → Use Ice Bar now exposes three persistent, live sizing controls:

- Icon size: 16–36 pt, default 28.
- Icon spacing: 0–12 pt between item hit targets, default 2.
- Background padding: 2–12 pt, default 4 vertically and 2 pt extra horizontally.

Reset sizes restores these three values. Invalid stored sizes are clamped on load.
The default visible surface is 40 pt tall (previously 56); item hit targets are
32 × 32 pt. Rounded corners and shadow are smaller. Search/settings/recovery
commands live in the Bar background's context menu, removing the fixed toolbar.
Right-clicking an app icon retains that app's own secondary action.

The native Ice icon continues using General's Show Ice icon and Ice icon choice.
The hosted state update now respects Show Ice icon when the Bar changes state.
The installed app is updated at its registered location, with the previous app
backed up in the build directory. On this machine the installed copy retains its
real SItem in MenuBarAgent while user-assigned applications remain concealed;
a copy launched from DerivedData did not. This path-dependent observation does
not establish a universal guarantee about macOS's private assessment interface.

Compact sizing acceptance (2026-09-19): Release universal and Debug builds
passed. Native settings sliders were exercised at 16/0/2 and 36/12/12; the
observed eight-item panel changed from 184 × 40 to 448 × 80 pt (including the
transparent shadow margin). A relaunch retained 36/12/12; Reset sizes restored
28/2/4 and a 298 × 56 pt panel, whose visible background is 40 pt high. The real
MenuBarAgent SItem remained visible and its AX click opened Ice Bar. The default
native hide/restore smoke and four surface rendering cases passed. The optional
positive allowlist diagnostic for a temporary fixture failed on this OS, with
both SDK 27 and compatibility SDK 26 metadata; it is not reported as a pass.

Final native interaction checks also passed: right-click the Bar's background
and choose Ice Bar settings; turn Show Ice icon off, open the preview without
resurrecting the icon, turn it back on; Escape; close Settings and click the
real menu-bar SItem. The resulting compact Bar was visually inspected through
its actual window screenshot (not only an offscreen surface render).
