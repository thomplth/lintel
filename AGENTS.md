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

Quit any running instance first (`build/Lintel.app/Contents/MacOS/Lintel ctl '{"cmd":"quit"}'`). Do not copy the app elsewhere or replace an installed copy unless the user supplies the command.

## Documentation maintenance

- Update this file whenever a change alters project-wide architecture, workflows, conventions or durable gotchas.
- Keep `README.md` and `Lintel guide` (`Sources/LintelCore/DesignGuide.swift`) in sync with the implementation; never leave a known contradiction undocumented.
