# TermiNai: a way to focus one session from outside

Feature request drafted for TermiNai (bundle `com.zacharyzhang.terminai`, verified on
v0.1.5). Keep this as the source of truth for the issue body — everything below the
"Background" heading is meant to be pasted upstream.

Why it matters here: CodeIsland's click-to-jump (`TerminalActivator.activate`) can reach
TermiNai's window but not the session a card belongs to, because TermiNai exposes no
addressable tab surface — no URL scheme, no AppleScript dictionary, and its only CLI
entry (`terminai hook`) is write-only. See the TermiNai branch in
`Sources/CodeIsland/TerminalActivator.swift` for the CodeIsland side.

---

**Status, 2026-11-13:** shipped in TermiNai 0.1.6 and wired up here. `terminai focus --tty
<path>` (or `--pid`, or `--folder`) shows that session and exits 0 when it did, 1 when no
session holds what it named, 2 when no app answers and 3 when the request is malformed;
`terminai list [--json]` names each open session's tty, folder, shown title and whether the
window shows it. `TerminalActivator`'s TermiNai branch runs `focus` with the session's tty
and pid, and `HookIntake` carries `TERMINAI_TTY` for sessions whose hook daemon lost its
terminal. Everything below stays as the source of truth for the issue body.

---

## Title

`terminai focus --tty <tty>` (or a `terminai://focus` link) so external agents can raise a specific session

## Background

TermiNai is now my daily terminal, and I run coding agents (Claude Code, Codex, a few
custom ones) inside it. Their hooks report back into a menu-bar app, which shows one card
per running agent and lets me click a card to jump back to the tab it lives in. With
Ghostty, iTerm2, WezTerm, kitty and Terminal.app that jump lands on the exact tab, because
those terminals expose some way to address a tab from outside.

## Problem

With TermiNai the jump can only reach the app: no URL scheme, no AppleScript dictionary
(`NSAppleScriptEnabled` is unset and the bundle ships no `.sdef`), and the only CLI entry
point, `terminai hook`, is write-only — it reports agent events into the app, it can't ask
the app for anything. So clicking a card raises the window and leaves me on whichever
session I was last looking at, and I have to hunt for the right one by hand.

## What would fix it

Any one of these is enough; a CLI is probably the least work and the easiest to script:

1. `terminai focus --tty /dev/ttys003` — focus the session that owns that tty. Exit 0 when
   it was found and raised, non-zero otherwise (so callers can fall back instead of
   guessing).
2. Optionally also accept `--folder /path/to/project` and `--pid <pid>`, tried in that
   order of precision.
3. Or `terminai list --json`, so an external tool can resolve which session is which:

   ```json
   [
     { "tty": "/dev/ttys002", "folder": "/Users/me/Project/CodeIsland", "title": "CodeIsland", "focused": true }
   ]
   ```

4. Or a `terminai://focus?tty=/dev/ttys002` URL scheme handed to
   `open -b com.zacharyzhang.terminai` — same effect, no new binary surface.

## Why the tty is the right key

Children already get `TERMINAI_TTY` in their environment (alongside `TERM_PROGRAM=terminai`,
`TERMINAI_HOOK=1`, and a compatibility `KITTY_WINDOW_ID`), so every agent knows which pty it
runs on without any new protocol. The app clearly already tracks the session→folder mapping
(it's in `settings.json` as `sessions[].folder` + `active_session`), and the commands
already model sessions explicitly (`terminai::SelectSession`, `NextSession`,
`LastSession`), so routing tty→session looks like bookkeeping rather than new machinery.

## Acceptance

With three sessions open in one window, `terminai focus --tty /dev/ttys004` brings the
right session forward and exits 0; with a tty that belongs to no session it exits non-zero
and changes nothing. No new windows, no reordering of the session list.

## Fallback ordering I'd assume

exact tty → exact folder → give up (don't guess), the same way `SelectSession` resolves
today.

Thanks — this is the last thing keeping TermiNai from being fully click-to-jump compatible
with the rest of my toolchain.

---

## 中文摘要（不贴进 issue）

TermiNai 目前只能被"提到前台"，没法从外部指定跳到哪个 session。其他终端（Ghostty /
iTerm2 / WezTerm / kitty）都能做到，因为 CodeIsland 这类卡片工具需要点一下就回到对应标签页。
建议加 `terminai focus --tty /dev/ttysNNN`（子进程环境里已经有 `TERMINAI_TTY`，直接可用），
或者给个 `terminai://focus?tty=` 的链接；找不到就返回非零、不要瞎猜。
