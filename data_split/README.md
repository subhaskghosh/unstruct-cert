# SSRB Split Dataset (`data_split`)

This directory stores a GitHub-friendly split version of the original `data/` dataset.

## Why split
Some original `.jsonl` files are larger than GitHub's practical per-file thresholds.
This split layout keeps large files as `*.part-00001`, `*.part-00002`, etc.

## Contents
- `manifest.tsv`: canonical manifest with per-file and per-part checksums.
- `manifest.meta`: metadata about how the split was produced.
- Data files:
  - unchanged files copied as-is
  - sharded files split into `*.part-xxxxx`

## Reconstruct original dataset
From repository root:

```bash
bash scripts/merge_dataset.sh --split-dir data_split --out-dir data_merged
```

This restores original file paths under `data_merged/` and verifies each reconstructed file by:
- byte size
- SHA-256 checksum

If verification fails, the script exits with a non-zero code.

## Regenerate split dataset
From repository root:

```bash
bash scripts/split_dataset.sh --src-dir data --out-dir data_split --max-mib 24
```

Notes:
- `--max-mib 24` keeps parts <= 24 MiB (safe for GitHub browser upload constraints around 25 MiB).
- Splitting is line-safe for JSONL: lines are never broken across part files.

## Manifest schema (`manifest.tsv`)
Tab-separated columns:

1. `kind` (`file` or `sharded`)
2. `rel_path` (original relative path)
3. `original_size` (bytes)
4. `original_sha256`
5. `part_index` (1-based)
6. `part_count`
7. `part_rel_path` (path inside `data_split`)
8. `part_size` (bytes)
9. `part_sha256`

For `kind=file`, `part_count=1` and `part_rel_path == rel_path`.
