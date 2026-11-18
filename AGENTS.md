# Lintel

A floating, always-on-top macOS status bar whose modules are built, restyled and arranged by chatting with a built-in assistant. See `README.md` for layout, run instructions and the command line.

## Work tracking

Linear team `KHA`, project `Lintel` (set as the local default in `.linear`; never commit that file).

- Treat the Linear project as the source of truth for scope, decisions, progress and acceptance criteria. An issue is one outcome a human accepts or rejects; commits carry the mechanism.
- Before starting, find an unblocked issue with `linear issues --unblocked` (or `linear issues --open` for everything in flight), read it fully with `linear issue show <id>`, then run `linear issue start <id>` before implementing.
- Title an issue as the change a user or maintainer would notice, in about eight plain words, without API names, error codes or file names. Good: "Window previews are fresh when the overlay opens". Bad: "Capture with captureScreenshot and fall back to captureSampleBuffer on -3811".
- Put implementation steps in the description as a `- [ ]` checklist and tick them as they land with `linear issue update <id> --check "<item>"`. Steps never become sub-issues. Create sub-issues only for parts reviewed or shipped independently, at most about five per parent.
- Give every issue exactly one `Area` label (`UI`, `Core`, `ML`, `Data`, `Integrations`, `Testing`, `Observability`, `Build & release`, `Docs`, `Site`) and one `Type` label (`Feature`, `Bug`, `Improvement`, `Performance`, `Security`, `Research`). These are workspace labels shared by every project; propose a new one to the human instead of inventing it.
- `linear issue update <id> --label` replaces every label: repeat the labels the issue keeps.
- Do not create issues for dependency, CI, lint or format changes, renames, AGENTS.md or docs sync, test-flake fixes, or refactors with no behaviour change.
- Record material discoveries, changed decisions and blockers with `linear issue comment <id> "<body>"`. Fixes to work already in Review reuse that issue.
- Handle newly discovered work in this order:
  1. Within the current issue's outcome: add a checklist item with `linear issue update <id> --append "- [ ] <step>"`.
  2. Overlaps an open issue: append it to that issue the same way.
  3. Otherwise: `linear issue create --title "<title>" --label <area> --label <type> --status backlog`, and do not start it unprompted.
- One issue may span several PRs; one PR never spans several issues. Title the PR after the issue and attach it with `linear issue update <id> --link <url>`.
- Move an issue to Review once, when its whole outcome is verified, with one summary comment: `linear issue update <id> --status review`. Never move an issue to Done or close it; only a human does that.

## Git workflow

- Make every task change in a clean, isolated worktree, never the primary checkout. One task per worktree.
- Keep commits scoped, with imperative messages prefixed by the issue ID (`KHA-123 Show …`). Commits for work with no issue carry no prefix. Branch names need no issue ID.
- After verification: commit, integrate into `main`, remove the worktree and branch, and push `main` to `origin`.

## Test-driven development

- Add or update tests first (`Tests/LintelCoreTests`; pure logic belongs in `Sources/LintelCore` so it can be tested).
- Run `xcrun --sdk macosx swift test` and confirm the new tests fail for the expected reason.
- Implement, then rerun until everything passes.

## Build, install and launch

Lintel is a desktop app. After every change, build the app bundle and launch it to confirm the change in the real app:

```sh
Scripts/bundle.sh
open build/Lintel.app
```

Quit any running instance first (`build/Lintel.app/Contents/MacOS/Lintel ctl '{"cmd":"quit"}'`). A bundle opened with `open` has
Accessibility only if the user granted it to that build, and without it the top-edge event tap and menu bar scans
stay off; to check those on the desktop, run `build/Lintel.app/Contents/MacOS/Lintel` from the terminal so it inherits
the terminal's grant. Do not copy the app elsewhere or replace an installed copy unless the user supplies the command.

The user keeps using whichever Lintel you launched last, so never leave it running from a worktree. Before removing a
worktree, quit the Lintel launched from it, rebuild in the primary checkout after integrating into `main`, and launch
`build/Lintel.app` from there. A running Lintel whose bundle was deleted keeps its modules only until it restarts, and
then comes back with none. `lsappinfo list | grep -A3 '"Lintel"'` shows which bundle is running.

## Performance

Local and debug builds log metrics once a minute to `Metrics/metrics-<day>.jsonl` in the data folder, tagged with the
build's commit (README, "Performance metrics"). Compare those lines, or `Lintel metrics`, before and after a change that
could cost CPU. Views in the bar must not observe `BarModel` per chip: `ChipView` takes plain values and is compared with
`.equatable()`, and state that changes every frame, like the dragged module's pointer, lives outside the model.

## Testing in the VM

The developer works on the host desktop, so never synthesise input or take over the pointer there. Drags, clicks and
mid-gesture screenshots go to the macOS Tart guest shared with the Debut project (`debut-e2e-27`, needs
`~/Developer/debut`), driven by `Scripts/vm.sh`:

```sh
Scripts/vm.sh session            # run in the background; waits its turn in Debut's Tart queue, prints "VM ready"
Scripts/vm.sh install            # bundle this checkout, install it with a fresh layout, launch, hold the bar open
Scripts/vm.sh lintel '{"cmd":"state"}'                         # rows, chip frames (screen points) and drag state
Scripts/vm.sh input drag 752 720 740 480 --hold 0.5 --command  # ⌘-drag; also `input click X Y`, `input key l --control --option --command`
Scripts/vm.sh shot after-drag    # screenshot with the pointer; prints the PNG's host path
Scripts/vm.sh stop               # always: an idle guest burns host CPU and blocks Debut's runs
```

- Coordinates are AppKit screen points with the origin at the bottom left; the guest screen is 1024×768. Read chip
  frames from `state` again after every drop, since modules resize and reflow.
- Debut's E2E runs share the queue and the VM, so a session can wait. Stop as soon as checks finish.
- Run guest commands only through `Scripts/vm.sh`. Its SSH session holds the guest's Accessibility and Screen Recording
  grants; `osascript` and other new automation raise a consent dialog that blocks the guest.

## Documentation maintenance

- Update this file whenever a change alters project-wide architecture, workflows, conventions or durable gotchas.
- Keep `README.md` and `Lintel guide` (`Sources/LintelCore/DesignGuide.swift`) in sync with the implementation; never leave a known contradiction undocumented.
