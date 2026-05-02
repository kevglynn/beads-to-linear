# JSONL Merge Strategy

## Problem

`.beads/issues.jsonl` stores one JSON object per line — one line per issue.
When multiple devs push to the same repo, Git's default merge treats the
entire file as a text blob. Two devs editing *different* issues can still
produce a merge conflict if their changes are on adjacent lines, because
Git's default 3-way merge is conservative about context.

## Solution: `merge=union` in `.gitattributes`

The repo-root `.gitattributes` declares:

```
.beads/issues.jsonl merge=union
```

Git's built-in **union** merge driver keeps unique lines from both sides.
For a JSONL file where each line is an independent record, this gives the
right behavior:

| Scenario | Result |
|---|---|
| Dev A edits issue X, Dev B edits issue Y (different lines) | Auto-merged — both changes kept |
| Dev A and Dev B both edit issue X (same line changed) | Conflict — both versions appear, dev resolves manually |
| Dev A adds a new issue, Dev B adds a different new issue | Auto-merged — both new lines kept |

## Resolving JSONL conflicts

When a conflict does occur (same issue edited on both sides), Git marks it
with the standard conflict markers:

```
<<<<<<< HEAD
{"id":"btl-abc","title":"Updated by dev A","updated_at":"2026-05-02T10:00:00Z",...}
=======
{"id":"btl-abc","title":"Updated by dev B","updated_at":"2026-05-02T09:55:00Z",...}
>>>>>>> feature-branch
```

To resolve:

1. Each conflicting line is a complete JSON object — you can read both.
2. Pick the version with the **newer `updated_at`** timestamp.
3. If both have the same timestamp or the merge requires combining fields,
   manually construct the merged JSON object.
4. Remove the conflict markers so the file is valid JSONL again (one JSON
   object per line, no blank lines between records).
5. `git add .beads/issues.jsonl && git commit`

## `external_refs.json`

`.beads/external_refs.json` maps local bead IDs to Linear issue IDs. The
CI sync worker is the **sole writer** of this file — devs never modify it
directly.

Because only the CI worker writes this file, merge conflicts are extremely
unlikely. If one does occur (e.g., after a force-push or history rewrite),
resolve by taking the version from `main`, which reflects the CI worker's
authoritative mapping:

```bash
git checkout main -- .beads/external_refs.json
git add .beads/external_refs.json
```

## Upstream context

The `.beads/memory/` directory already uses `merge=union` for
`knowledge.jsonl` and `knowledge.archive.jsonl` (see
`.beads/memory/.gitattributes`). The repo-root `.gitattributes` extends the
same pattern to the issues file.
