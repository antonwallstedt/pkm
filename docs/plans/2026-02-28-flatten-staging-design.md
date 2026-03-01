# Design: Flat staging layout + attachment publishing

**Date:** 2026-02-28
**Scope:** `notes-site/utils/notes-publish`

## Goal

Publish all notes and attachments flat at the root of `notes-staging/` (no subdirectories). The Publish Summary PR body and terminal output still show the vault-relative source path so the origin folder is visible.

## Approach

Add `staging_path: String` to `PlanEntry` — the flat destination filename computed at plan time. Everything downstream uses `staging_path` for the destination; `path` (vault-relative) is preserved for display and manifest keying.

---

## Module-by-module changes

### vault

`ScannedFile.attachments` changes from `Vec<String>` to `Vec<(String, String)>` — `(filename, sha256_hash)`. The vault scanner reads each referenced attachment file and hashes it during the same walk pass that processes notes. This replaces the current filename-as-hash placeholder in the plan module.

### plan

`PlanEntry` gains `staging_path: String`.

Collision detection runs before diffing:
1. Collect basenames of all **public** notes.
2. If a basename is unique → `staging_path = basename` (e.g., `note.md`).
3. If a basename appears more than once → every copy is prefixed with its immediate parent folder: `5_slipbox--note.md`, `1_projects--note.md`.

Attachments are always bare filenames (`image.png`). Notes are always `.md` and attachments are never `.md`, so cross-type collisions cannot occur.

`diff_attachments` is fixed to use real content hashes from `ScannedFile.attachments` instead of the filename-as-hash placeholder.

`PlanEntry.path` is unchanged (vault-relative, manifest key). Only `staging_path` is flat.

### manifest

`FileEntry` gains `staging_path: String` so that deletions know which flat file to remove even when the vault file no longer exists.

Manifest bumps to **version 2**. `load()` migrates v1 manifests by setting `staging_path = basename(key)` for each entry. Users with a v1 manifest and a now-colliding basename should run `--reset-checksums` once for a clean slate.

### main — `apply_plan`

| | Before | After |
|---|---|---|
| Note source | `vault_path / entry.path` | unchanged |
| Attachment source | `vault_path / entry.path` (`attachments/image.png`) | `vault_path / "attachments" / filename` |
| Destination | `staging_path / entry.path` | `staging_path / entry.staging_path` |
| Delete target | `staging_path / entry.path` | `manifest.get(entry.path).staging_path` |

`create_dir_all` is no longer needed for the destination (always a root-level file).

### main — `strip_public_tag`

When copying a note to staging (both local copy in `apply_plan` and GitHub upload in `build_staged_files`), the `public` tag is stripped from the frontmatter. The note on disk in staging should not expose the internal tagging system.

A `strip_public_tag(content: &str) -> String` function is added (in `main.rs` or a small `transform.rs` module). It:
1. Parses the YAML frontmatter using `serde_yaml`.
2. Removes `public` from the `tags` field (handles single-string, inline-list, and block-list formats; strips leading `#` before comparing).
3. Removes the `tags` field entirely if it becomes empty.
4. Re-serializes the modified frontmatter and reconstructs the full note content.
5. Returns the content unchanged if there is no frontmatter or parsing fails.

Applied to `.md` files only — attachments are passed through as-is.

### github — `StagedFile`

`StagedFile.content` changes from `Option<String>` to `Option<FileContent>`:

```rust
pub enum FileContent {
    Text(String),
    Binary(Vec<u8>),
}
// None = deletion
```

`build_staged_files` uses `entry.staging_path` as `StagedFile.path`. Text notes use `read_to_string`; binary attachments use `read` (raw bytes).

The GitHub module pre-creates a blob for each binary file via `POST /repos/{owner}/{repo}/git/blobs` (base64-encoded content) before building the tree. Binary tree entries reference the returned blob SHA; text entries continue using inline content.

### summary + `print_plan`

`summary::render` already uses `entry.path` (vault-relative) — no change needed; the PR body continues to show source paths.

`print_plan` in `main.rs` is updated to show both paths:
```
[+] 5_slipbox/note.md → note.md
[+] attachments/image.png → image.png
```

---

## Migration

Existing `notes-staging/` repositories have files at nested paths (e.g., `5_slipbox/note.md`). After this change, notes-publish will write them flat (`note.md`) but will not remove the old nested files automatically. Recommended migration:

1. Manually delete all nested note/attachment directories from `notes-staging/`.
2. Run `notes-publish --reset-checksums` to republish everything flat.

---

## Out of scope

- Rewriting `![[embed]]` wikilinks inside note content to point to the flat attachment path (Quartz resolves wikilinks by filename regardless of path, so this is not needed).
- Support for notes nested more than one level deep in the vault (e.g., `1_projects/2_sub/note.md`); the collision prefix uses the immediate parent only.
