# Flatten Staging Layout + Attachment Publishing

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Publish all notes and attachments flat at the root of `notes-staging/`, strip the `public` tag from published note frontmatter, upload binary attachments via the GitHub Blobs API, and use folder-prefixed filenames on collision.

**Architecture:** Add `staging_path: String` to `PlanEntry` and manifest `FileEntry`. The plan module owns collision detection and flat-name assignment. A `strip_public_tag` transform is applied to every note's content before it reaches staging. Binary attachments are pre-uploaded as blobs and referenced by SHA in the Git tree.

**Tech Stack:** Rust · `sha2`/`hex` (hashing) · `base64` (blob upload, already in Cargo.toml) · `serde_yaml` (frontmatter transform, already in Cargo.toml) · `octocrab` (GitHub API) · `tempfile` (tests)

---

## Task 1: Hash attachment files in the vault scanner

**Files:**
- Modify: `src/vault/mod.rs`

`ScannedFile.attachments` currently stores `Vec<String>` (filenames only). Change it to `Vec<(String, String)>` — `(filename, sha256_hash)` — so the plan module can do real content-based diffing instead of the current filename-as-hash placeholder.

### Step 1: Write the failing tests

Add these two tests inside the `// ── Attachments ───` block in `vault/mod.rs`:

```rust
#[test]
fn attachment_entry_includes_content_hash() {
    let dir = tempdir().unwrap();
    fs::create_dir_all(dir.path().join("5_slipbox")).unwrap();
    fs::create_dir(dir.path().join("attachments")).unwrap();
    let content = b"fake png data";
    fs::write(dir.path().join("attachments/image.png"), content).unwrap();
    fs::write(
        dir.path().join("5_slipbox/note.md"),
        "---\ntags: [public]\n---\n\n![[image.png]]",
    )
    .unwrap();
    let results = scan_vault(dir.path()).unwrap();
    let (filename, hash) = &results[0].attachments[0];
    assert_eq!(filename, "image.png");
    let expected = hex::encode(Sha256::digest(content));
    assert_eq!(*hash, expected);
}

#[test]
fn missing_attachment_produces_no_entry() {
    let (dir, _) = vault_with_note("---\ntags: [public]\n---\n\n![[ghost.png]]");
    let results = scan_vault(dir.path()).unwrap();
    assert!(results[0].attachments.is_empty());
}
```

### Step 2: Run and confirm they fail

```bash
cd notes-site/utils/notes-publish
cargo test attachment_entry_includes_content_hash missing_attachment_produces_no_entry 2>&1 | tail -20
```

Expected: compile error — `attachments[0]` is a `String`, not a tuple.

### Step 3: Implement

**a) Change `ScannedFile.attachments`** (line 23):

```rust
/// Filenames and SHA-256 hashes of attachments referenced in the note body.
pub attachments: Vec<(String, String)>,
```

**b) Replace `extract_attachment_references`** (lines 131–152) to read and hash each file:

```rust
fn extract_attachment_references(content: &str, vault_path: &Path) -> Vec<(String, String)> {
    let attachments_dir = vault_path.join("attachments");

    OBSIDIAN_EMBED
        .captures_iter(content)
        .filter_map(|cap| {
            let filename = cap[1].to_string();
            let is_note = Path::new(&filename)
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e == "md")
                .unwrap_or(true);

            if is_note {
                return None;
            }

            let attachment_path = attachments_dir.join(&filename);
            let bytes = std::fs::read(&attachment_path).ok()?;
            let hash = hex::encode(Sha256::digest(&bytes));
            Some((filename, hash))
        })
        .collect()
}
```

**c) Fix the existing `includes_existing_referenced_attachment` test** — the assertion now destructures a tuple. Replace the `assert_eq!` line:

```rust
assert_eq!(results[0].attachments.len(), 1);
assert_eq!(results[0].attachments[0].0, "image.png");
assert!(!results[0].attachments[0].1.is_empty());
```

The other attachment tests (`excludes_missing_attachment`, `does_not_treat_note_embed_as_attachment`) assert `is_empty()` on the `Vec` — those still compile unchanged.

### Step 4: Run all vault tests

```bash
cargo test vault:: 2>&1 | tail -20
```

Expected: all pass.

### Step 5: Commit

```bash
git add src/vault/mod.rs
git commit -m "feat(vault): hash attachment files during scan"
```

---

## Task 2: Add `staging_path` to `PlanEntry` with collision detection

**Files:**
- Modify: `src/plan/mod.rs`

Add `staging_path: String` to `PlanEntry`. The plan module runs collision detection over all public-note basenames before diffing:
- Unique basename → `staging_path = basename` (e.g. `note.md`)
- Collision → every copy gets prefixed with its immediate parent folder: `5_slipbox--note.md`
- Attachments → always bare filename (`image.png`)

Also fix `diff_attachments` to use the real content hashes from `ScannedFile.attachments`, and fix `entries_gone_from_vault` to pull `staging_path` from the manifest for delete entries.

### Step 1: Write the failing tests

Add inside the `#[cfg(test)]` block:

```rust
#[test]
fn unique_public_note_gets_bare_staging_filename() {
    let manifest = Manifest::new();
    let plan = diff(vec![scanned("5_slipbox/note.md", "hash1", true)], &manifest);
    let entry = plan.notes.iter().find(|e| e.path == "5_slipbox/note.md").unwrap();
    assert_eq!(entry.staging_path, "note.md");
}

#[test]
fn colliding_public_notes_get_folder_prefixed_staging_paths() {
    let manifest = Manifest::new();
    let plan = diff(
        vec![
            scanned("1_projects/note.md", "hash1", true),
            scanned("5_slipbox/note.md", "hash2", true),
        ],
        &manifest,
    );
    let staging: std::collections::HashSet<_> =
        plan.notes.iter().map(|e| e.staging_path.as_str()).collect();
    assert!(staging.contains("1_projects--note.md"), "got: {:?}", staging);
    assert!(staging.contains("5_slipbox--note.md"), "got: {:?}", staging);
}

#[test]
fn private_note_does_not_affect_collision_detection() {
    let manifest = Manifest::new();
    let plan = diff(
        vec![
            scanned("1_projects/note.md", "hash1", false), // private — not counted
            scanned("5_slipbox/note.md", "hash2", true),
        ],
        &manifest,
    );
    let entry = plan.notes.iter().find(|e| e.path == "5_slipbox/note.md").unwrap();
    assert_eq!(entry.staging_path, "note.md");
}

#[test]
fn attachment_staging_path_is_bare_filename() {
    let manifest = Manifest::new();
    let plan = diff(
        vec![ScannedFile {
            vault_relative_path: "5_slipbox/note.md".to_string(),
            hash: "hash1".to_string(),
            is_public: true,
            attachments: vec![("image.png".to_string(), "atthhash".to_string())],
        }],
        &manifest,
    );
    assert_eq!(plan.attachments[0].staging_path, "image.png");
}
```

> **Note:** These tests also require `manifest.upsert` to accept a `staging_path` argument (added in Task 3). Write the tests now but do not run them until Task 3 is also done.

### Step 2: Implement

**a) Add `staging_path` to `PlanEntry`** (after the `path` field):

```rust
pub struct PlanEntry {
    /// Vault-relative path (manifest key and display source).
    pub path: String,
    /// Flat filename for staging (e.g. `note.md` or `5_slipbox--note.md`).
    pub staging_path: String,
    pub hash: String,
    pub action: Action,
}
```

**b) Add `compute_staging_paths`** before `diff_notes`:

```rust
/// Returns a map of vault-relative path → flat staging filename for every public note.
///
/// Notes whose basename collides with another public note are prefixed with their
/// immediate parent folder: `5_slipbox--note.md`.
fn compute_staging_paths(scanned: &[ScannedFile]) -> HashMap<String, String> {
    let mut by_basename: HashMap<String, Vec<String>> = HashMap::new();
    for file in scanned {
        if file.is_public {
            let basename = std::path::Path::new(&file.vault_relative_path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(&file.vault_relative_path)
                .to_string();
            by_basename.entry(basename).or_default().push(file.vault_relative_path.clone());
        }
    }

    let mut map = HashMap::new();
    for (basename, paths) in by_basename {
        if paths.len() == 1 {
            map.insert(paths[0].clone(), basename);
        } else {
            for path in paths {
                let folder = std::path::Path::new(&path)
                    .parent()
                    .and_then(|p| p.file_name())
                    .and_then(|n| n.to_str())
                    .unwrap_or("")
                    .to_string();
                map.insert(path, format!("{}--{}", folder, basename));
            }
        }
    }
    map
}
```

**c) Update `diff`** to compute staging paths and pass them to `diff_notes`:

```rust
pub fn diff(scanned: Vec<ScannedFile>, manifest: &Manifest) -> Plan {
    let mut plan = Plan::default();
    let staging_paths = compute_staging_paths(&scanned);

    let notes_result = diff_notes(&scanned, manifest, &staging_paths);
    plan.notes = notes_result.entries;
    plan.attachments = diff_attachments(manifest, &notes_result.referenced_attachments);

    plan.notes.extend(entries_gone_from_vault(
        &notes_result.seen_paths,
        manifest,
        |path| !path.starts_with("attachments/"),
    ));

    plan.attachments.extend(entries_gone_from_vault(
        &notes_result
            .referenced_attachments
            .keys()
            .map(|k| format!("attachments/{}", k))
            .collect(),
        manifest,
        |path| path.starts_with("attachments/"),
    ));

    plan
}
```

**d) Update `diff_notes` signature and body** to accept `staging_paths` and resolve `staging_path` per entry:

```rust
fn diff_notes(
    scanned: &[ScannedFile],
    manifest: &Manifest,
    staging_paths: &HashMap<String, String>,
) -> NotesDiffResult {
    let mut entries = Vec::new();
    let mut seen_paths = HashSet::new();
    let mut referenced_attachments: HashMap<String, String> = HashMap::new();

    for file in scanned {
        seen_paths.insert(file.vault_relative_path.clone());

        let action = match manifest.get(&file.vault_relative_path) {
            None if file.is_public => Action::Add,
            None => Action::Skip,
            Some(entry) if entry.hash == file.hash && file.is_public => Action::Skip,
            Some(entry) if entry.hash == file.hash && !file.is_public => Action::Delete,
            Some(_) if file.is_public => Action::Update,
            Some(_) => Action::Delete,
        };

        // Deletions use the manifest's stored staging_path (the file may not exist in vault).
        // All other actions use the newly computed collision-resolved flat name.
        let staging_path = if action == Action::Delete {
            manifest
                .get(&file.vault_relative_path)
                .map(|e| e.staging_path.clone())
                .unwrap_or_default()
        } else {
            staging_paths
                .get(&file.vault_relative_path)
                .cloned()
                .unwrap_or_default()
        };

        if file.is_public {
            for (filename, hash) in &file.attachments {
                referenced_attachments
                    .entry(filename.clone())
                    .or_insert_with(|| hash.clone());
            }
        }

        entries.push(PlanEntry {
            path: file.vault_relative_path.clone(),
            staging_path,
            hash: file.hash.clone(),
            action,
        });
    }

    NotesDiffResult {
        entries,
        seen_paths,
        referenced_attachments,
    }
}
```

**e) Update `diff_attachments`** — use real hashes and set `staging_path`:

```rust
fn diff_attachments(
    manifest: &Manifest,
    referenced_attachments: &HashMap<String, String>,
) -> Vec<PlanEntry> {
    referenced_attachments
        .iter()
        .map(|(filename, hash)| {
            let attachment_key = format!("attachments/{}", filename);
            let action = match manifest.get(&attachment_key) {
                None => Action::Add,
                Some(entry) if entry.hash == *hash => Action::Skip,
                Some(_) => Action::Update,
            };
            PlanEntry {
                path: attachment_key,
                staging_path: filename.clone(),
                hash: hash.clone(),
                action,
            }
        })
        .collect()
}
```

**f) Update `entries_gone_from_vault`** to iterate `.iter()` instead of `.keys()` so it can read `staging_path` from `FileEntry`:

```rust
fn entries_gone_from_vault(
    seen: &HashSet<String>,
    manifest: &Manifest,
    filter: impl Fn(&str) -> bool,
) -> Vec<PlanEntry> {
    manifest
        .files
        .iter()
        .filter(|(path, _)| filter(path) && !seen.contains(*path))
        .map(|(path, entry)| PlanEntry {
            path: path.clone(),
            staging_path: entry.staging_path.clone(),
            hash: String::new(),
            action: Action::Delete,
        })
        .collect()
}
```

**g) Update the `scanned_with_attachments` test helper** to accept `Vec<(&str, &str)>` tuples:

```rust
fn scanned_with_attachments(path: &str, hash: &str, attachments: Vec<(&str, &str)>) -> ScannedFile {
    ScannedFile {
        vault_relative_path: path.to_string(),
        hash: hash.to_string(),
        is_public: true,
        attachments: attachments
            .into_iter()
            .map(|(n, h)| (n.to_string(), h.to_string()))
            .collect(),
    }
}
```

**h) Update all call sites** of `scanned_with_attachments` in plan tests to pass `(filename, hash)` pairs. Use a consistent sentinel hash `"imghash"`:

```rust
// new_referenced_attachment_is_added
scanned_with_attachments("note.md", "hash1", vec![("image.png", "imghash")])

// changed_referenced_attachment_is_updated
scanned_with_attachments("note.md", "hash1", vec![("image.png", "new_hash")])

// unchanged_referenced_attachment_is_skipped
scanned_with_attachments("note.md", "hash1", vec![("image.png", "imghash")])
// (manifest must also store "imghash" as the hash — fixed in Task 3)

// attachment_referenced_by_multiple_notes_appears_once
scanned_with_attachments("note1.md", "hash1", vec![("image.png", "imghash")])
scanned_with_attachments("note2.md", "hash2", vec![("image.png", "imghash")])
```

**i) Update `attachment_action` test helper** to look up by `staging_path` instead of `path`, since attachment plan entries now have `path = "attachments/image.png"` but tests that previously searched by that string still work — the field is unchanged. No change needed to the helper.

---

## Task 3: Add `staging_path` to manifest `FileEntry` + v2 migration

**Files:**
- Modify: `src/manifest/mod.rs`

`FileEntry` gains `staging_path: String`. Manifest bumps to version 2. `load()` migrates v1 manifests by inferring `staging_path` as the basename of each manifest key. `upsert` gains a `staging_path` parameter.

### Step 1: Write the failing tests

Add inside `#[cfg(test)]`:

```rust
#[test]
fn round_trips_staging_path_to_disk() {
    let dir = tempdir().unwrap();
    let mut manifest = Manifest::new();
    manifest.upsert(
        "5_slipbox/note.md".to_string(),
        "note.md".to_string(),
        "hash1".to_string(),
    );
    manifest.save(dir.path()).unwrap();

    let loaded = Manifest::load(dir.path()).unwrap();
    assert_eq!(
        loaded.get("5_slipbox/note.md").unwrap().staging_path,
        "note.md"
    );
}

#[test]
fn migrates_v1_manifest_by_inferring_staging_path_from_basename() {
    let dir = tempdir().unwrap();
    let v1 = serde_json::json!({
        "version": 1,
        "updated_at": "2025-01-01T00:00:00Z",
        "files": {
            "5_slipbox/note.md": {
                "hash": "abc123",
                "published_at": "2025-01-01T00:00:00Z",
                "updated_at": "2025-01-01T00:00:00Z"
            }
        }
    });
    std::fs::write(
        dir.path().join(".checksums.json"),
        serde_json::to_string(&v1).unwrap(),
    )
    .unwrap();

    let manifest = Manifest::load(dir.path()).unwrap();
    assert_eq!(
        manifest.get("5_slipbox/note.md").unwrap().staging_path,
        "note.md"
    );
}
```

### Step 2: Run and confirm they fail

```bash
cargo test manifest:: 2>&1 | tail -20
```

Expected: compile errors — `upsert` doesn't accept a `staging_path` argument yet.

### Step 3: Implement

**a) Add `staging_path` to `FileEntry`** with `#[serde(default)]` so v1 manifests (which lack the field) still deserialize cleanly:

```rust
#[derive(Debug, Serialize, Deserialize)]
pub struct FileEntry {
    pub hash: String,
    #[serde(default)]
    pub staging_path: String,
    pub published_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}
```

**b) Update `new()`** — initial version is now 2:

```rust
pub fn new() -> Self {
    Manifest {
        version: 2,
        updated_at: Utc::now(),
        files: HashMap::new(),
    }
}
```

**c) Update `load()`** — replace the version-check block with migration logic:

```rust
let mut manifest: Manifest = serde_json::from_str(&raw)
    .with_context(|| format!("Could not parse manifest at {}", manifest_path.display()))?;

if manifest.version == 1 {
    for (path, entry) in &mut manifest.files {
        if entry.staging_path.is_empty() {
            entry.staging_path = std::path::Path::new(path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(path)
                .to_string();
        }
    }
    manifest.version = 2;
}

if manifest.version > 2 {
    bail!(
        "Manifest version {} is not supported\n  → Upgrade notes-publish to support this manifest version",
        manifest.version
    );
}

Ok(manifest)
```

**d) Update `upsert()`** — add `staging_path` as the second parameter:

```rust
pub fn upsert(&mut self, path: String, staging_path: String, hash: String) {
    let now = Utc::now();
    let entry = self.files.entry(path).or_insert(FileEntry {
        hash: hash.clone(),
        staging_path: staging_path.clone(),
        published_at: now,
        updated_at: now,
    });
    entry.hash = hash;
    entry.staging_path = staging_path;
    entry.updated_at = now;
}
```

**e) Fix all existing call sites of `manifest.upsert`** — run `grep -rn "manifest.upsert" src/` to find them all. Each one needs `staging_path` inserted as the second argument:

In manifest tests:
```rust
// round_trips_to_disk
manifest.upsert("note.md".to_string(), "note.md".to_string(), "abc123".to_string());

// upsert_preserves_published_at_on_update (both calls)
manifest.upsert("note.md".to_string(), "note.md".to_string(), "hash1".to_string());
manifest.upsert("note.md".to_string(), "note.md".to_string(), "hash2".to_string());
```

In plan tests (all `manifest.upsert` calls):
```rust
// notes use bare basename as staging_path
manifest.upsert("note.md".to_string(), "note.md".to_string(), "old_hash".to_string());
manifest.upsert("note.md".to_string(), "note.md".to_string(), "hash1".to_string());

// attachments use bare filename
manifest.upsert("attachments/image.png".to_string(), "image.png".to_string(), "old_hash".to_string());
manifest.upsert("attachments/image.png".to_string(), "image.png".to_string(), "imghash".to_string());

// unchanged_referenced_attachment_is_skipped — hash in manifest must match ScannedFile hash
manifest.upsert("attachments/image.png".to_string(), "image.png".to_string(), "imghash".to_string());
```

In summary tests and main.rs — same pattern; staging_path = basename of the vault path.

In `main.rs` `apply_plan` (line 172):
```rust
manifest.upsert(entry.path.clone(), entry.staging_path.clone(), entry.hash.clone());
```
(Fix this compiler error now; the full `apply_plan` rewrite comes in Task 4.)

**f) Update `rejects_future_manifest_version`** test — change the version in the JSON from 99 to 99 (still triggers), but the error threshold is now `> 2`. The test body is unchanged; it will pass once `load()` is updated.

### Step 4: Run all tests

```bash
cargo test 2>&1 | tail -30
```

Expected: all pass.

### Step 5: Commit

```bash
git add src/manifest/mod.rs src/plan/mod.rs src/summary.rs
git commit -m "feat(manifest,plan): add staging_path, v2 migration, real attachment hashing"
```

---

## Task 4: Strip the `public` tag when writing notes to staging

**Files:**
- Create: `src/transform.rs`
- Modify: `src/main.rs` (add `mod transform;`)

Notes copied to staging should not expose the vault's internal `public` tagging. A `strip_public_tag(content: &str) -> String` function strips it from frontmatter before the content reaches staging — in both the local copy path (`apply_plan`) and the GitHub upload path (`build_staged_files`).

### Step 1: Write the failing tests

Create `src/transform.rs` with just the tests first:

```rust
pub fn strip_public_tag(content: &str) -> String {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_public_from_inline_list() {
        let input = "---\ntags: [public, zettelkasten]\n---\n\n# Hello";
        let output = strip_public_tag(input);
        assert!(!output.contains("public"), "got: {}", output);
        assert!(output.contains("zettelkasten"), "got: {}", output);
    }

    #[test]
    fn strips_public_from_block_list() {
        let input = "---\ntags:\n  - public\n  - zettelkasten\n---\n\n# Hello";
        let output = strip_public_tag(input);
        assert!(!output.contains("public"), "got: {}", output);
        assert!(output.contains("zettelkasten"), "got: {}", output);
    }

    #[test]
    fn removes_tags_field_when_only_public_remains_inline() {
        let input = "---\ntags: [public]\n---\n\n# Hello";
        let output = strip_public_tag(input);
        assert!(!output.contains("tags"), "got: {}", output);
    }

    #[test]
    fn removes_tags_field_when_only_public_remains_block() {
        let input = "---\ntags:\n  - public\n---\n\n# Hello";
        let output = strip_public_tag(input);
        assert!(!output.contains("tags"), "got: {}", output);
    }

    #[test]
    fn removes_tags_field_when_single_string_public() {
        let input = "---\ntags: public\n---\n\n# Hello";
        let output = strip_public_tag(input);
        assert!(!output.contains("tags"), "got: {}", output);
    }

    #[test]
    fn handles_hash_prefixed_public_tag() {
        let input = "---\ntags: [\"#public\", idea]\n---\n\n# Hello";
        let output = strip_public_tag(input);
        assert!(!output.contains("public"), "got: {}", output);
        assert!(output.contains("idea"), "got: {}", output);
    }

    #[test]
    fn preserves_content_without_frontmatter() {
        let input = "# No frontmatter here\n\nJust content.";
        assert_eq!(strip_public_tag(input), input);
    }

    #[test]
    fn preserves_body_content_after_stripping() {
        let input = "---\ntags: [public]\n---\n\nBody text here.";
        let output = strip_public_tag(input);
        assert!(output.contains("Body text here."), "got: {}", output);
    }

    #[test]
    fn preserves_other_frontmatter_fields() {
        let input = "---\ntitle: My Note\ntags: [public]\ndate: 2026-01-01\n---\n\n# Hello";
        let output = strip_public_tag(input);
        assert!(output.contains("title: My Note"), "got: {}", output);
        assert!(output.contains("date: 2026-01-01") || output.contains("date:"), "got: {}", output);
        assert!(!output.contains("public"), "got: {}", output);
    }
}
```

Add `mod transform;` to `main.rs`.

### Step 2: Run and confirm they fail

```bash
cargo test transform:: 2>&1 | tail -20
```

Expected: all fail with `not yet implemented`.

### Step 3: Implement `strip_public_tag`

Replace the `todo!()` with:

```rust
pub fn strip_public_tag(content: &str) -> String {
    let content_trimmed = content.trim_start_matches('\u{FEFF}');

    // Find the opening "---"
    let Some(rest) = content_trimmed.strip_prefix("---") else {
        return content.to_string();
    };
    let Some(rest) = rest.strip_prefix('\n').or_else(|| rest.strip_prefix("\r\n")) else {
        return content.to_string();
    };

    // Find the closing "---"
    let (end_offset, newline_len) = if let Some(pos) = rest.find("\r\n---") {
        (pos, 2)
    } else if let Some(pos) = rest.find("\n---") {
        (pos, 1)
    } else {
        return content.to_string();
    };

    let frontmatter_str = &rest[..end_offset];
    let after_delimiter = &rest[end_offset + newline_len..]; // starts with "---..."

    // Parse as a generic YAML mapping so all fields are preserved.
    let Ok(mut value) = serde_yaml::from_str::<serde_yaml::Value>(frontmatter_str) else {
        return content.to_string();
    };

    let Some(mapping) = value.as_mapping_mut() else {
        return content.to_string();
    };

    let tags_key = serde_yaml::Value::String("tags".to_string());

    if let Some(tags) = mapping.get_mut(&tags_key) {
        match tags {
            serde_yaml::Value::String(s) if s.trim_start_matches('#') == "public" => {
                mapping.remove(&tags_key);
            }
            serde_yaml::Value::Sequence(seq) => {
                seq.retain(|t| {
                    t.as_str()
                        .map(|s| s.trim_start_matches('#') != "public")
                        .unwrap_or(true)
                });
                if seq.is_empty() {
                    mapping.remove(&tags_key);
                }
            }
            _ => {}
        }
    }

    let Ok(new_frontmatter) = serde_yaml::to_string(&value) else {
        return content.to_string();
    };

    // serde_yaml::to_string emits a trailing newline; reconstruct the full document.
    format!("---\n{}---{}", new_frontmatter, after_delimiter)
}
```

### Step 4: Run transform tests

```bash
cargo test transform:: 2>&1 | tail -20
```

Expected: all pass.

### Step 5: Commit

```bash
git add src/transform.rs src/main.rs
git commit -m "feat(transform): strip public tag from note frontmatter before staging"
```

---

## Task 5: Update `apply_plan`, `build_staged_files`, and `print_plan` in `main.rs`

**Files:**
- Modify: `src/main.rs`
- Modify: `src/github/mod.rs` (adds `FileContent` so `build_staged_files` can compile — do both in one step)

Three changes in `main.rs`:
1. `apply_plan` — write to flat `staging_path`, remove `create_dir_all`, strip public tag before writing `.md` files.
2. `build_staged_files` — use `entry.staging_path` as path; `FileContent::Text` for notes (with tag stripped), `FileContent::Binary` for attachments.
3. `print_plan` — show `[action] vault_path → staging_path`.

And in `github/mod.rs`:
4. Replace `StagedFile.content: Option<String>` with `Option<FileContent>`.

### Step 1: Write integration tests

Add a `#[cfg(test)] mod tests` at the bottom of `main.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;
    use tempfile::tempdir;

    fn add_entry(path: &str, staging_path: &str) -> plan::PlanEntry {
        plan::PlanEntry {
            path: path.to_string(),
            staging_path: staging_path.to_string(),
            hash: "h".to_string(),
            action: plan::Action::Add,
        }
    }

    fn delete_entry(path: &str, staging_path: &str) -> plan::PlanEntry {
        plan::PlanEntry {
            path: path.to_string(),
            staging_path: staging_path.to_string(),
            hash: String::new(),
            action: plan::Action::Delete,
        }
    }

    #[test]
    fn apply_plan_copies_note_flat_to_staging() {
        let vault = tempdir().unwrap();
        let staging = tempdir().unwrap();
        std::fs::create_dir(vault.path().join("5_slipbox")).unwrap();
        std::fs::write(
            vault.path().join("5_slipbox/note.md"),
            "---\ntags: [public]\n---\n\n# Hello",
        )
        .unwrap();

        let p = plan::Plan {
            notes: vec![add_entry("5_slipbox/note.md", "note.md")],
            attachments: vec![],
        };
        let mut manifest = Manifest::new();
        apply_plan(&p, vault.path(), staging.path(), &mut manifest).unwrap();

        assert!(staging.path().join("note.md").exists());
        assert!(!staging.path().join("5_slipbox").exists());
    }

    #[test]
    fn apply_plan_strips_public_tag_from_staged_note() {
        let vault = tempdir().unwrap();
        let staging = tempdir().unwrap();
        std::fs::create_dir(vault.path().join("5_slipbox")).unwrap();
        std::fs::write(
            vault.path().join("5_slipbox/note.md"),
            "---\ntags: [public, zettelkasten]\n---\n\n# Hello",
        )
        .unwrap();

        let p = plan::Plan {
            notes: vec![add_entry("5_slipbox/note.md", "note.md")],
            attachments: vec![],
        };
        let mut manifest = Manifest::new();
        apply_plan(&p, vault.path(), staging.path(), &mut manifest).unwrap();

        let staged = std::fs::read_to_string(staging.path().join("note.md")).unwrap();
        assert!(!staged.contains("public"), "public tag should be stripped: {}", staged);
        assert!(staged.contains("zettelkasten"), "other tags preserved: {}", staged);
    }

    #[test]
    fn apply_plan_copies_attachment_flat_to_staging() {
        let vault = tempdir().unwrap();
        let staging = tempdir().unwrap();
        std::fs::create_dir(vault.path().join("attachments")).unwrap();
        std::fs::write(vault.path().join("attachments/image.png"), b"\x89PNG").unwrap();

        let p = plan::Plan {
            notes: vec![],
            attachments: vec![add_entry("attachments/image.png", "image.png")],
        };
        let mut manifest = Manifest::new();
        apply_plan(&p, vault.path(), staging.path(), &mut manifest).unwrap();

        assert!(staging.path().join("image.png").exists());
        assert!(!staging.path().join("attachments").exists());
    }

    #[test]
    fn apply_plan_deletes_flat_staging_file() {
        let vault = tempdir().unwrap();
        let staging = tempdir().unwrap();
        std::fs::write(staging.path().join("note.md"), "old").unwrap();

        let p = plan::Plan {
            notes: vec![delete_entry("5_slipbox/note.md", "note.md")],
            attachments: vec![],
        };
        let mut manifest = Manifest::new();
        apply_plan(&p, vault.path(), staging.path(), &mut manifest).unwrap();

        assert!(!staging.path().join("note.md").exists());
    }
}
```

### Step 2: Run and confirm they fail

```bash
cargo test tests:: 2>&1 | tail -20
```

Expected: compile errors (missing `FileContent` in github, wrong `apply_plan` logic).

### Step 3: Add `FileContent` to `github/mod.rs`

At the top of `github/mod.rs`, replace the `StagedFile` struct:

```rust
/// Content of a staged file.
pub enum FileContent {
    /// UTF-8 text (markdown notes, JSON manifests).
    Text(String),
    /// Raw bytes (images, PDFs, etc.).
    Binary(Vec<u8>),
}

/// A file to be committed to the staging repo.
pub struct StagedFile {
    /// Flat path relative to the repo root.
    pub path: String,
    /// File content, or `None` for deletions.
    pub content: Option<FileContent>,
}
```

### Step 4: Implement `apply_plan`

Replace the function body:

```rust
fn apply_plan(
    plan: &plan::Plan,
    vault_path: &std::path::Path,
    staging_path: &std::path::Path,
    manifest: &mut manifest::Manifest,
) -> Result<()> {
    for entry in plan.notes.iter().chain(plan.attachments.iter()) {
        match entry.action {
            plan::Action::Add | plan::Action::Update => {
                let src = vault_path.join(&entry.path);
                let dst = staging_path.join(&entry.staging_path);

                if entry.staging_path.ends_with(".md") {
                    let content = std::fs::read_to_string(&src)
                        .with_context(|| format!("Failed to read {}", src.display()))?;
                    let content = transform::strip_public_tag(&content);
                    std::fs::write(&dst, content)
                        .with_context(|| format!("Failed to write {}", dst.display()))?;
                } else {
                    std::fs::copy(&src, &dst).with_context(|| {
                        format!("Failed to copy {} → {}", src.display(), dst.display())
                    })?;
                }

                manifest.upsert(
                    entry.path.clone(),
                    entry.staging_path.clone(),
                    entry.hash.clone(),
                );
            }
            plan::Action::Delete => {
                let dst = staging_path.join(&entry.staging_path);
                if let Err(e) = std::fs::remove_file(&dst) {
                    if e.kind() != std::io::ErrorKind::NotFound {
                        return Err(e)
                            .with_context(|| format!("Failed to delete {}", dst.display()));
                    }
                }
                manifest.remove(&entry.path);
            }
            plan::Action::Skip => {}
        }
    }

    manifest.save(staging_path).context("Failed to save manifest")?;
    Ok(())
}
```

### Step 5: Implement `build_staged_files`

Replace the function body:

```rust
fn build_staged_files(
    plan: &plan::Plan,
    vault_path: &std::path::Path,
    staging_path: &std::path::Path,
) -> Result<Vec<github::StagedFile>> {
    let mut files = Vec::new();

    for entry in plan.notes.iter().chain(plan.attachments.iter()) {
        match entry.action {
            plan::Action::Add | plan::Action::Update => {
                let src = vault_path.join(&entry.path);
                let content = if entry.staging_path.ends_with(".md") {
                    let text = std::fs::read_to_string(&src)
                        .with_context(|| format!("Failed to read {}", src.display()))?;
                    github::FileContent::Text(transform::strip_public_tag(&text))
                } else {
                    let bytes = std::fs::read(&src)
                        .with_context(|| format!("Failed to read {}", src.display()))?;
                    github::FileContent::Binary(bytes)
                };
                files.push(github::StagedFile {
                    path: entry.staging_path.clone(),
                    content: Some(content),
                });
            }
            plan::Action::Delete => {
                files.push(github::StagedFile {
                    path: entry.staging_path.clone(),
                    content: None,
                });
            }
            plan::Action::Skip => {}
        }
    }

    let checksums_path = staging_path.join(".checksums.json");
    let checksums = std::fs::read_to_string(&checksums_path)
        .with_context(|| format!("Failed to read {}", checksums_path.display()))?;
    files.push(github::StagedFile {
        path: ".checksums.json".to_string(),
        content: Some(github::FileContent::Text(checksums)),
    });

    Ok(files)
}
```

### Step 6: Update `print_plan`

Replace the two `println!` lines:

```rust
for entry in &notes_to_act {
    println!("  [{}] {} → {}", entry.action, entry.path, entry.staging_path);
}
for entry in &atts_to_act {
    println!("  [{}] {} → {}", entry.action, entry.path, entry.staging_path);
}
```

### Step 7: Run all tests

```bash
cargo test 2>&1 | tail -30
```

Expected: all pass.

---

## Task 6: Binary blob upload in the GitHub module

**Files:**
- Modify: `src/github/mod.rs`

Update `create_tree` to pre-upload binary files via `POST /git/blobs` and reference the returned SHA in the tree entry. Text files continue to use inline content.

### Step 1: No unit tests (requires live API)

The GitHub module is tested end-to-end via `make deploy`. Verify after deploying: push a public note that embeds an image and confirm the image appears in the staging PR.

### Step 2: Add `upload_blob`

Add this async helper after `create_branch`:

```rust
/// Uploads raw bytes as a base64-encoded blob and returns the blob SHA.
async fn upload_blob(github: &Octocrab, owner: &str, repo: &str, content: &[u8]) -> Result<String> {
    use base64::{engine::general_purpose::STANDARD, Engine};

    let response: serde_json::Value = github
        .post(
            format!("/repos/{}/{}/git/blobs", owner, repo),
            Some(&serde_json::json!({
                "content": STANDARD.encode(content),
                "encoding": "base64",
            })),
        )
        .await
        .context("Failed to upload blob")?;

    response["sha"]
        .as_str()
        .map(|s| s.to_string())
        .context("Blob response missing SHA")
}
```

### Step 3: Update `create_tree`

Replace the `.map(|f| ...)` iterator with a `for` loop that handles the `FileContent` enum:

```rust
async fn create_tree(
    github: &Octocrab,
    owner: &str,
    repo: &str,
    base_sha: &str,
    files: Vec<StagedFile>,
) -> Result<String> {
    let mut tree: Vec<serde_json::Value> = Vec::new();

    for f in files {
        let entry = match f.content {
            Some(FileContent::Text(text)) => serde_json::json!({
                "path": f.path,
                "mode": "100644",
                "type": "blob",
                "content": text,
            }),
            Some(FileContent::Binary(bytes)) => {
                let blob_sha = upload_blob(github, owner, repo, &bytes).await?;
                serde_json::json!({
                    "path": f.path,
                    "mode": "100644",
                    "type": "blob",
                    "sha": blob_sha,
                })
            }
            None => serde_json::json!({
                "path": f.path,
                "mode": "100644",
                "type": "blob",
                "sha": serde_json::Value::Null,
            }),
        };
        tree.push(entry);
    }

    let response: serde_json::Value = github
        .post(
            format!("/repos/{}/{}/git/trees", owner, repo),
            Some(&serde_json::json!({
                "base_tree": base_sha,
                "tree": tree,
            })),
        )
        .await
        .context("Failed to create tree")?;

    response["sha"]
        .as_str()
        .map(|s| s.to_string())
        .context("Tree response missing SHA")
}
```

### Step 4: Run all tests

```bash
cargo test 2>&1 | tail -30
```

Expected: all pass.

### Step 5: Commit Tasks 5 and 6 together

```bash
git add src/main.rs src/github/mod.rs
git commit -m "feat: flatten staging layout, strip public tag, upload binary attachments"
```

---

## Post-implementation: manual migration of existing staging repo

After deploying the new binary, `notes-staging/` still has files at nested paths. Clean up:

1. In `notes-staging/`, delete all subdirectories (e.g. `5_slipbox/`, `attachments/`).
2. Commit: `git add -A && git commit -m "chore: clear nested layout before flat republish"`.
3. Run: `make preview` — everything should show as Added (flat paths).
4. Run: `make deploy` with `--reset-checksums` flag to republish everything clean.

---

## Known limitations

- If a previously-published note later gains a filename collision (a new note with the same basename is published), the old note's staging path is not automatically updated. Use `--reset-checksums` to re-publish everything with correct flat paths.
- Attachments referenced by multiple notes are deduplicated by filename; only the first-seen hash is used. This is correct since all vault attachments live in a single flat `attachments/` directory.
