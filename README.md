# Lintel

A floating, always-on-top status bar for macOS 26 and later that stands in for the right side of the menu bar.
Everything in it is a module; modules are built, restyled and arranged by chatting with the built-in assistant.

## Run

```sh
Scripts/bundle.sh            # builds build/Lintel.app (release, signed with a code-signing identity from your login keychain)
open build/Lintel.app
```

The bundle is signed with an identity from your login keychain (an Apple Development one if there is one, otherwise the
first valid one), so a rebuilt app keeps its keychain access. Other keychains are skipped because codesign would stop on
their password prompt; set `LINTEL_SIGN_IDENTITY` to pick another identity, or `-` for ad-hoc (macOS then asks for the login password
after every rebuild).

For development, run the binary directly; it then inherits the terminal's Accessibility and Screen Recording grants:

```sh
xcrun --sdk macosx swift build && .build/debug/Lintel
xcrun --sdk macosx swift test
```

Rest the pointer on the bar or press ⌃⌥⌘B to open Lintel's main window with the assistant. ⌃⌥⌘H hides or shows the bar. The bar auto-hides whenever a window enters full screen (press ⌃⌥⌘H or ⌃⌥⌘L to bring it back; Settings › General turns this off). All workspace views (Dashboard, Modules, Bar Layout), module inspectors (configuration, live preview, jobs, logs, code), settings, and the collapsible assistant live together in one main Lintel window, reachable from the gear or sparkle in any panel or via ⌘,.
Clicking Lintel's Dock icon opens the whole bar until you switch to another app; clicking it again while the bar is open
opens Lintel's main window (and clicking it while the main window is already open brings it to the front). Settings › General › Show Lintel in the Dock takes the icon away.
With the menu bar set to hide automatically, the top edge above the bar no longer brings the menu bar in; hold ⌥ there,
or use the rest of the top edge (needs Accessibility; Settings › General turns it off). Beside a notch the opened bar
wraps to the space beside it, so its first line stays at the top of the screen.
With the menu bar always shown, the bar's first row lives in the menu bar beside other apps' icons and the rows after it
hang below; modules that do not fit beside the notch lead the second row. ⌘-dragging a module there moves it within
Lintel, not among other apps' items (needs Accessibility; without it macOS moves the whole row instead).
Drag the open bar to move it to the left, centre or right of the screen; hold ⌘ and drag a module to move it beside
another, into another row, or onto a row's top or bottom edge (or just below the bar) to start a new row there. Carry it
well away from the bar until the pointer shows ✕ and let go to remove it; Bar Layout brings it back.
Hover any module to reveal a curved resize handle on its free bottom corner (bottom-left when right-anchored,
bottom-right when left-anchored), plus invisible side and bottom edge grips. Drag outward or along any edge to morph
a chip into a freeform desktop widget of any width and height—from a slim top ribbon or narrow vertical sidebar to a
spacious multi-column dashboard—or shrink it back into a chip. Double-click the resize handle to snap height tightly
to content; widgets with finite content automatically clamp to their natural height so blank space never appears.
Desktop widgets stay visible while idle, adapt every block natively without scrolling, and reveal a quiet utility pill
(drag grip to reorder/stack vertically into columns or place side by side, Configure in Lintel, Collapse, Open in Lintel, Settings) on
hover; you can also ⌘-drag any widget card to stack or move it. Clicking an always-on desktop widget expands it
temporarily to max size until the pointer leaves and it returns to idle. Clicking a chip opens a transient peek widget
whose resized dimensions are remembered for next time; click its pin icon to keep it on the desktop.
Holding ⌘ over the open bar also shows a slim divider in each of its rows (except one in the menu bar, which shows all
its modules anyway): modules on the anchored side of it stay in the bar while it is closed, the rest only show while it
is open. Drop a module across a divider, or ⌘-drag the divider along its row, to pin or unpin modules.
⌃⌥⌘L opens the bar for the keyboard, with the module you last selected (or the first) ringed; the ring slides as the
selection moves, dims while you are in that module's panel, and nudges when ↑ or ↓ finds no row there. These are
the standard keys; Settings › Keyboard changes any of them except Esc and 1–9, and the three global shortcuts:

| Key | Does |
|---|---|
| ← → ↑ ↓, Tab, ⇧Tab, Home, End | Select a module; ↑ and ↓ go to the nearest module in the row above or below |
| Return or Space | Open the selected module, as a click would |
| 1–9 | Open the module at that position |
| ⌘← ⌘→ ⌘↑ ⌘↓ | Move the selected module along its row or to the row above or below |
| ⌘= / ⌘- (or ] / [) | Resize the selected module larger or smaller across its supported widget tiers |
| P | Pin it, so it shows while the bar is closed, or unpin it |
| Delete | Hide it from the bar (Bar Layout brings it back) |
| A | Ask the assistant to change it; / opens the assistant |
| ⌘, | Open Settings in the main window |
| Esc | Close the bar; in a panel opened from the keyboard, go back to the bar |

In a panel, Tab moves through its controls, Space or Return uses one, and ← → step a slider or segmented choice. A panel
opened from the keyboard focuses the control you last used in it, or its first one. Clicking a module while using the
keyboard moves the selection there. The focus ring shows only while the keyboard moves focus; a click focuses a control
without it, and the next Tab brings it back.

When a macOS notification banner covers the bar's rows or widgets, they slide down just below it and return once it
goes. With Accessibility, Lintel measures the real banners, so a stack of them moves it further; without, it assumes
one banner in the top-right corner.
User data lives in `~/Library/Application Support/Lintel`; set `LINTEL_HOME` to use another folder.

## Layout of the code

| Path | What it holds |
|---|---|
| `Sources/LintelCore` | The design system and all pure logic: components, theme, design rules, layout, placement, manifests. Unit-tested. |
| `Sources/Lintel/Runtime` | Module helper process, its client and watchdog, host services, module discovery and scheduling. |
| `Sources/Lintel/UI` | The renderer: one SwiftUI view per component, bar, panels, web clip and mini app stages. |
| `Sources/Lintel/Window` | Unified main Lintel window: Dashboard, Modules catalog, Bar Layout, module inspector (live idle & expanded preview with in-window placement/size controls, native macOS module configuration cards, jobs, logs, code editor), all Settings panes, and the collapsible Assistant inspector. |
| `Sources/Lintel/Chat` | Assistant engines and the authoring loop (trial run, design rules, repair). |
| `Sources/Lintel/Resources/Modules` | Built-in modules. They double as the examples the assistant learns from. Includes PR Reviews and My PRs. |
| `Sources/Lintel/Resources/Library` | Optional modules, switched on in Modules or by asking the assistant. |

## Command line

```sh
Lintel guide                         # the module-writing reference the assistant is given
Lintel trial <module.js>...          # run modules against the design rules without installing
Lintel chat [--approve] "<request>"  # one assistant request, headless
Lintel export <id> <file>            # write a shareable .lintelmodule
Lintel import <file> [--approve]     # install one after the same checks
Lintel items [--pictures <dir>]      # list system menu bar items (needs Accessibility), and save their pictures
Lintel metrics                       # live performance numbers from the running instance (debug and local builds)
Lintel stage --out <dir> --shots halo/idle,ink/panel:system [--size 900x620] [--backdrop photo|document|light|dark]
                                     # photograph the bar and a panel on a hidden stand-in desktop
Lintel ctl '{"cmd":"open","slot":"system"}'   # drive a running instance: open, close, assistant, window, studio, chat, jobs, job-run, settings, dock, state, quit
```

## Performance metrics

Debug builds and bundles from `Scripts/bundle.sh` (unless run with `LINTEL_METRICS=0`) record how much work the bar
does: view updates (`view.bar`, `view.chip`, `view.node`), model changes, module updates, main-thread stalls of 100 ms
or more, and timings of drags, menu bar scans and captures, module renders and system samples. Once a minute a JSON line
with those numbers, the app's and module runtime's CPU, memory, and the build's commit goes to
`~/Library/Application Support/Lintel/Metrics/metrics-<day>.jsonl`; fourteen days are kept. `Lintel metrics` prints the
current minute so far. The same work is marked with signposts (subsystem `app.lintel`), so Instruments' Points of
Interest track lines it up with a trace.

## Writing a module by hand

Drop a `<id>.js` file into `~/Library/Application Support/Lintel/Modules`; it loads within two seconds and reloads on
save. `Lintel guide` prints the full reference. A module that asks for permissions stays off until allowed from the bar.
