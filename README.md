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

Rest the pointer on the bar or press ⌃⌥⌘B to open it. ⌃⌥⌘H hides it. Settings are behind the gear in any panel.
Drag the open bar to move it to the left, centre or right of the screen; hold ⌘ and drag a module to move it beside
another, into another row, or onto a row's top or bottom edge (or just below the bar) to start a new row there. Carry it
well away from the bar until the pointer shows ✕ and let go to remove it; Settings › Bar Items brings it back.
User data lives in `~/Library/Application Support/Lintel`; set `LINTEL_HOME` to use another folder.

## Layout of the code

| Path | What it holds |
|---|---|
| `Sources/LintelCore` | The design system and all pure logic: components, theme, design rules, layout, placement, manifests. Unit-tested. |
| `Sources/Lintel/Runtime` | Module helper process, its client and watchdog, host services, module discovery and scheduling. |
| `Sources/Lintel/UI` | The renderer: one SwiftUI view per component, bar, panels, web clip and mini app stages. |
| `Sources/Lintel/Chat` | Assistant engines and the authoring loop (trial run, design rules, repair). |
| `Sources/Lintel/Resources/Modules` | Built-in modules. They double as the examples the assistant learns from. |
| `Sources/Lintel/Resources/Library` | Optional modules, switched on in Settings › Modules or by asking the assistant. |

## Command line

```sh
Lintel guide                         # the module-writing reference the assistant is given
Lintel trial <module.js>...          # run modules against the design rules without installing
Lintel chat [--approve] "<request>"  # one assistant request, headless
Lintel export <id> <file>            # write a shareable .lintelmodule
Lintel import <file> [--approve]     # install one after the same checks
Lintel items                         # list system menu bar items (needs Accessibility)
Lintel stage --out <dir> --shots halo/idle,ink/panel:system [--size 900x620] [--backdrop photo|document|light|dark]
                                     # photograph the bar and a panel on a hidden stand-in desktop
Lintel ctl '{"cmd":"open","slot":"system"}'   # drive a running instance: open, close, assistant, chat, settings, state, quit
```

## Writing a module by hand

Drop a `<id>.js` file into `~/Library/Application Support/Lintel/Modules`; it loads within two seconds and reloads on
save. `Lintel guide` prints the full reference. A module that asks for permissions stays off until allowed from the bar.
