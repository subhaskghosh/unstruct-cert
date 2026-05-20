#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  bash scripts/merge_dataset.sh [--split-dir DIR] [--out-dir DIR]

Description:
  Reconstructs original files from data_split/manifest.tsv and verifies SHA-256.

Defaults:
  --split-dir data_split
  --out-dir data_merged
USAGE
}

SPLIT_DIR="data_split"
OUT_DIR="data_merged"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --split-dir) SPLIT_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

MANIFEST="$SPLIT_DIR/manifest.tsv"
if [[ ! -f "$MANIFEST" ]]; then
  echo "Manifest not found: $MANIFEST" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

tmp_targets=$(mktemp)
trap 'rm -f "$tmp_targets"' EXIT

# Build one unique target row per original file.
awk -F '\t' 'NR==1 {next} {k=$1"\t"$2; if (!seen[k]++) print $0}' "$MANIFEST" > "$tmp_targets"

restored=0

while IFS=$'\t' read -r kind rel_path orig_size orig_sha part_index part_count part_rel part_size part_sha; do
  target="$OUT_DIR/$rel_path"
  mkdir -p "$(dirname "$target")"

  if [[ "$kind" == "file" ]]; then
    cp -p "$SPLIT_DIR/$part_rel" "$target"
  elif [[ "$kind" == "sharded" ]]; then
    : > "$target"
    i=1
    while (( i <= part_count )); do
      part_path=$(awk -F '\t' -v rel="$rel_path" -v idx="$i" 'NR>1 && $1=="sharded" && $2==rel && $5==idx {print $7; exit}' "$MANIFEST")
      if [[ -z "$part_path" ]]; then
        echo "Missing manifest part for $rel_path part $i/$part_count" >&2
        exit 1
      fi
      cat "$SPLIT_DIR/$part_path" >> "$target"
      i=$((i + 1))
    done
  else
    echo "Unknown kind in manifest: $kind" >&2
    exit 1
  fi

  got_size=$(stat -f %z "$target")
  got_sha=$(shasum -a 256 "$target" | awk '{print $1}')

  if [[ "$got_size" != "$orig_size" || "$got_sha" != "$orig_sha" ]]; then
    echo "Verification failed for $rel_path" >&2
    echo "Expected size/sha: $orig_size / $orig_sha" >&2
    echo "Actual size/sha:   $got_size / $got_sha" >&2
    exit 1
  fi

  restored=$((restored + 1))
done < "$tmp_targets"

echo "Done. Restored and verified files: $restored"
echo "Output directory: $OUT_DIR"
