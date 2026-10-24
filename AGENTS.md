# Project working instructions

These instructions apply to every prompt and all development work in this
directory and its descendants. Follow them throughout the project unless the
user explicitly changes them. Higher-priority system and developer instructions
still apply.

## 1. Initialize empty project folders

When starting a project in an empty folder, initialize a Git repository and
connect it to a GitHub repository. Apply this rule to each empty folder in which
the user requests project work; do not scan unrelated directories or create
repositories for empty internal project subdirectories.

Ask the user for any missing GitHub setup decisions, including repository owner,
name, and visibility. Ask for authentication or other user-operated steps when
needed. Never guess these choices or expose credentials. If setup is blocked,
explain what is needed and continue only with work that does not depend on it.

## 2. Develop incrementally and commit as the user

Build the requested work one feature at a time, in small, coherent increments.
Commit each completed feature after it runs successfully and the applicable
validation passes. Do not commit incomplete or failing work as a finished feature.

All commits must use the user's Git identity. Before committing, verify the
effective Git author and committer names and email addresses. Use the user's
configured account; if the identity is missing or ambiguous, ask the user.
Never use Codex, OpenAI, a bot, or an invented identity as author or committer,
and never add an AI co-author attribution. Do not change the user's global Git
configuration without explicit permission.

This identity rule persists for every prompt during project development.

## 3. Keep strictly to the requested scope

Do only what the prompt requests, including the implementation and validation
necessary to complete that request. Do not invent features, perform unsolicited
bug hunts, or make unrelated improvements, refactors, dependency updates, or
cleanup changes.

If an unrelated bug is noticed, do not fix it without approval. Complete the
requested task first, then list any additional work you propose and obtain the
user's explicit approval before starting it. If a discovered issue blocks the
requested task and fixing it would expand the scope, explain the blocker and ask
for approval before proceeding with that fix.

## 4. Artistic discretion

You may independently choose artistic details such as UI layout, colors,
typography, spacing, and visual styling, within the user's stated requirements.
This discretion does not authorize new functionality, changed product behavior,
or unrelated work.

## 5. Keep Git history and branches clean

At the start of every prompt, inspect the repository status and current branch.
Decide whether the requested work belongs on the current branch or requires a
new feature branch or a branch based on the current branch. Keep branch changes
limited to the requested work.

When work does not belong on the current branch, assess whether that branch is
complete and appropriate to merge or should remain as it is. Do not merge
unfinished work. Ask the user when merge intent or the target branch is unclear.
Never discard, overwrite, or include unrelated user changes in a commit.

Use frequent, focused commits with clear messages at successfully validated
feature boundaries. Merge completed branches when appropriate and authorized;
do not rewrite published history or force-push without explicit approval.

## 6. Batch tests at the end of each prompt

For UI tests and any tests that do not run instantaneously, finish development
for the current prompt before running them together in one validation phase.
Do not repeatedly run these tests after each small edit.

Run all checks applicable to the requested changes during that final phase. If
validation fails, make only in-scope corrections and rerun the necessary checks.
Do not claim that unrun tests passed.

When a prompt contains multiple features, develop them incrementally and defer
their final commits until the batched validation passes. Preserve focused feature
commits where practical without including unvalidated or unrelated changes.

## 7. Ask about uncertain decisions

When requirements are unclear or there are materially different ways to build a
requested feature, ask the user which approach they want before implementing the
dependent work. Explain the relevant options and tradeoffs concisely. Never
silently assume the user's preference or treat silence as approval.

Continue clearly authorized, independent work while awaiting an answer. Routine
implementation mechanics that do not change scope, behavior, or user-facing
tradeoffs may follow established project conventions. Artistic decisions are
covered by the discretion in section 4.

## 8. Number final responses and maintain project ledgers

Start every final response with its prompt identifier as the first text, before
any heading or other content. Use the following scheme:

- Major prompts, including new feature additions and feature removals: `X`,
  where `X` is the next unused positive integer in the feature prompt sequence.
- Updates to an existing feature: `X.Y`, where `X` is that feature's original
  prompt number and `Y` is its next update count, starting at 1. Treat this as an
  identifier, not a decimal: `1.10` follows `1.9`.
- Bug fixes: `BX`, such as `B1`, where `X` is the bug's number in `BUGS.md`.
  Reuse the same bug identifier for follow-up work on that bug.
- Revamps of an existing feature: reuse its original `X` without allocating a
  new feature number.

Keep `FEATURES.md` and `BUGS.md` in the project root. Read them at the start of
each prompt, alongside these instructions, to recover identifiers and counters
even after context loss. Never rely on conversation memory alone for numbering.

`FEATURES.md` must contain a table recording each feature's original number,
description, status, latest update count, and prompt history. Record major
removal prompts with their own number and reference the affected feature;
preserve the original feature row and mark its status appropriately. Record
updates and revamps against the original feature. Never reuse allocated numbers
or delete historical entries.

`BUGS.md` must contain a table recording each bug's identifier, description,
related feature when known, and whether it is fixed. Record reported bugs and
bugs incidentally noticed during authorized work; this does not authorize bug
hunting or repairs. Mark a bug fixed only after the fix and applicable validation
are complete. Preserve fixed bugs in the table.

Update the relevant ledger entries before the final response. For a prompt that
spans several tracked items, start the response with their applicable identifiers
and record each item in its ledger. For a clarification or status response, reuse
the identifier of the work being discussed without incrementing its update count.
If the feature association or numbering is unclear, ask the user before making
the dependent changes, following section 7.
