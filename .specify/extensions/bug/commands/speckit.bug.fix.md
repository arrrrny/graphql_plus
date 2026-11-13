---
description: "Apply the remediation from a bug assessment and record what was changed"
---

# Fix Bug

Apply the remediation that was proposed by `__SPECKIT_COMMAND_BUG_ASSESS__` and record the changes in a fix report at `.specify/bugs/<slug>/fix.md`. This command is **only** valid after an assessment exists for the given slug.

## User Input

```text
$ARGUMENTS
```

The user input should identify the bug to fix. Accept any of:

- `slug=<bug-slug>` or `--slug <bug-slug>` or just a bare slug-like token.
- A path that contains the slug (e.g. `.specify/bugs/login-timeout/`).
- **Branch isolation** — `--branch` creates and checks out `<branch_prefix>/<slug>` (default `fix/<slug>`) before editing; `--worktree` does the same in a separate `git worktree`. Default (no flag) applies the fix on the current branch.
- **Nothing** — fall back to context (see below).

Parse the flags first and strip them from the slug input: `--branch` and `--worktree` are mutually exclusive (if both are given, stop with an error). They only take effect if the working tree is inside a Git repository — see Execution step 0.

## Slug Resolution

Resolve `BUG_SLUG` in this order, stopping at the first match:

1. **Explicit user input** — a slug passed in `$ARGUMENTS` (any of the forms above).
2. **Conversation context** — if the current session has just run `__SPECKIT_COMMAND_BUG_ASSESS__`, the slug it reported is the working slug. Reuse it without re-prompting. Confirm it by checking that `.specify/bugs/<slug>/assessment.md` exists; if it does not, fall through.
3. **Single candidate on disk** — list `.specify/bugs/*/assessment.md`. If exactly one matching `assessment.md` is found, use the slug from its parent directory.
4. **Disambiguate**:
   - **Interactive mode**: ask the user which bug to fix and list the candidates.
   - **Automated mode**: stop with an error listing the candidates. Do not guess.

Once resolved, set `BUG_SLUG` and `BUG_DIR = .specify/bugs/<BUG_SLUG>`, and briefly state in your reply which resolution path was used (explicit / from context / single candidate / asked).

## Prerequisites

- `BUG_DIR/assessment.md` MUST exist. If it does not, stop and instruct the user to run `__SPECKIT_COMMAND_BUG_ASSESS__` first.
- If `BUG_DIR/fix.md` already exists, ask the user whether to overwrite it before continuing (interactive mode) or refuse (automated mode).
- Read `BUG_DIR/assessment.md` in full. Treat its **Proposed Remediation**, **Files likely to change**, **Tests to add or update**, and **Risks & Considerations** sections as the contract for this command.
- Read `branch_prefix` from `.specify/extensions/bug/bug-config.yml` (default `fix`) when `--branch` / `--worktree` was requested. The branch name is `<branch_prefix>/<slug>`.
- If `--worktree` was requested, the destination path defaults to `../<slug>/` (a sibling of the current checkout). If that directory already exists, stop rather than reusing or deleting it.

## Execution

0. **Isolate the fix (only when `--branch` or `--worktree` was requested)**
   - Confirm a Git repository first: `git rev-parse --is-inside-work-tree 2>/dev/null`. If it is not a repository, or `git` is unavailable, skip this step and say so — the fix is applied to the current branch with a warning.
   - `--branch`:
     ```bash
     git rev-parse --verify --quiet "refs/heads/<branch_prefix>/<slug>"   # already exists?
     git checkout -b "<branch_prefix>/<slug>"                             # create + check out
     ```
     If the branch already exists, do not recreate it — check it out (`git checkout "<branch_prefix>/<slug>"`) only when the user confirms in interactive mode; in automated mode stop and report the collision.
   - `--worktree`:
     ```bash
     git worktree add "../<slug>" -b "<branch_prefix>/<slug>"             # create worktree + branch
     ```
     Then continue the fix **in that worktree**: treat `../<slug>` as the project root for the edits in steps 1–4. The assessment contract is the one already resolved as `BUG_DIR` (the checkout you started in — the worktree has no copy of it), and `BUG_DIR/fix.md` is written back to that same directory, so the report lands beside the assessment it answers. Do not edit source files in the original checkout.
   - Record the branch (and worktree path, when used) in `BUG_DIR/fix.md` under **Branch Isolation**.
   - If the working tree has uncommitted changes when `--branch` is requested, warn the user — `git checkout -b` carries them onto the new branch, which may be what you want, but the user should confirm before continuing in automated mode.

1. **Confirm the plan**
   - Restate, in 3–6 bullets, what you are about to change and where, based on the assessment.
   - If the assessment's verdict is `invalid`, stop — there is nothing to fix. Tell the user and exit.
   - If the verdict is `likely valid, needs reproduction` and there are unresolved `[NEEDS CLARIFICATION]` items, flag them and ask the user whether to proceed in interactive mode, or stop in automated mode.

2. **Apply the remediation**
   - Make the code changes described by the preferred remediation. Stay within the files listed by the assessment unless newly discovered evidence requires expanding scope (in which case, log the expansion explicitly in the report).
   - Add or update the tests called out in the assessment so the bug cannot regress silently.
   - Keep the change minimal — do not refactor unrelated code, do not introduce dependencies that the assessment did not call for.
   - If you discover the assessment was wrong (the proposed fix does not work, the root cause is elsewhere), STOP modifying code, document the new finding in the fix report under **Deviations from Assessment**, and recommend re-running `__SPECKIT_COMMAND_BUG_ASSESS__`.

3. **Run local checks**
   - If the project has obvious test commands (e.g., `pytest`, `npm test`, `cargo test`), run the tests that exercise the changed paths. Capture pass/fail and key output.
   - Do not run destructive or network-dependent suites without the user's consent.

4. **Write the fix report**

   Write to `BUG_DIR/fix.md` using this structure:

   ```markdown
   # Bug Fix: <short title>

   - **Slug**: <BUG_SLUG>
   - **Fixed**: <ISO 8601 date>
   - **Assessment**: ./assessment.md
   - **Status**: applied | partial | not-applied

   ## Summary

   <One or two sentences describing what was changed and why.>

   ## Branch Isolation

   <One of: `current branch` / `branch <branch_prefix>/<slug>` / `worktree <path>`. Omit the section when the fix was applied to the current branch and no isolation flag was passed.>

   ## Changes

   | File | Change | Notes |
   |------|--------|-------|
   | `path/to/file.py` | <added / modified / removed> | <short note> |
   | `path/to/test_file.py` | added test | <short note> |

   ## Diff Highlights (optional)

   <Short, illustrative snippets of the most important hunks — not a full diff dump.>

   ## Tests Added or Updated

   - `path/to/test_file.py::test_name` — <what it pins down>

   ## Local Verification

   - Commands run: `<command>` → <result, brief>
   - Manual checks: <what was verified by hand, if anything>

   ## Deviations from Assessment

   <Empty if none. Otherwise, list any places where the actual fix departed from the proposed remediation and why.>

   ## Follow-ups

   - <suggested cleanup, monitoring, doc update, etc.>
   ```

5. **Report back** with:
   - The slug and `BUG_DIR/fix.md` path.
   - The status (`applied`, `partial`, `not-applied`).
   - The branch the fix landed on (`<branch_prefix>/<slug>`), or the current branch when no isolation flag was passed.
   - The next suggested step: `__SPECKIT_COMMAND_BUG_TEST__ slug=<BUG_SLUG>`.

## Guardrails

- Never modify files outside the project workspace (or the worktree created for `--worktree`).
- Never edit `assessment.md` — it is the contract you are working against. Record disagreements in `fix.md` under **Deviations from Assessment**.
- Never delete files unless the assessment explicitly required it.
- Never overwrite an existing `fix.md` without confirmation.
- Never force-push, reset or otherwise rewrite history on the fix branch; never switch the user off a branch they were working on without asking.
