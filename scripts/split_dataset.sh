#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  bash scripts/split_dataset.sh [--src-dir DIR] [--out-dir DIR] [--max-mib N]

Description:
  Splits large files (line-safe) into part files and writes a checksum manifest.
  Files at or below --max-mib are copied as-is.

Defaults:
  --src-dir data
  --out-dir data_split
  --max-mib 24
USAGE
}

SRC_DIR="data"
OUT_DIR="data_split"
MAX_MIB=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-dir) SRC_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --max-mib) MAX_MIB="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if ! [[ "$MAX_MIB" =~ ^[1-9][0-9]*$ ]]; then
  echo "--max-mib must be a positive integer" >&2
  exit 1
fi

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Source directory not found: $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
MANIFEST="$OUT_DIR/manifest.tsv"
META="$OUT_DIR/manifest.meta"

# Clean output contents but keep directory itself.
find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

MAX_BYTES=$((MAX_MIB * 1024 * 1024))

printf "kind\trel_path\toriginal_size\toriginal_sha256\tpart_index\tpart_count\tpart_rel_path\tpart_size\tpart_sha256\n" > "$MANIFEST"
cat > "$META" <<META_EOF
split_created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
source_dir=$SRC_DIR
out_dir=$OUT_DIR
max_part_size_bytes=$MAX_BYTES
manifest_file=manifest.tsv
format=tsv
notes=For kind=file, part_rel_path equals rel_path and part_count=1. For kind=sharded, one row per part.
META_EOF

split_line_safe_by_bytes() {
  local src_file="$1"
  local out_prefix="$2"
  local max_bytes="$3"

  awk -v max_bytes="$max_bytes" -v prefix="$out_prefix" '
    BEGIN {
      part = 1
      bytes = 0
      out = ""
    }
    {
      line = $0 ORS
      line_bytes = length(line)
      if (bytes > 0 && bytes + line_bytes > max_bytes) {
        close(out)
        part += 1
        bytes = 0
      }
      if (bytes == 0) {
        out = sprintf("%s.part-%05d", prefix, part)
      }
      printf "%s", line >> out
      bytes += line_bytes
    }
    END {
      if (NR == 0) {
        out = sprintf("%s.part-%05d", prefix, 1)
        close(out)
      }
    }
  ' "$src_file"
}

file_count=0
split_count=0
copy_count=0

while IFS= read -r src_file; do
  rel_path="${src_file#$SRC_DIR/}"
  dest_file="$OUT_DIR/$rel_path"
  mkdir -p "$(dirname "$dest_file")"

  orig_size=$(stat -f %z "$src_file")
  orig_sha=$(shasum -a 256 "$src_file" | awk '{print $1}')

  if (( orig_size > MAX_BYTES )); then
    split_line_safe_by_bytes "$src_file" "$dest_file" "$MAX_BYTES"
    part_total=$(find "$(dirname "$dest_file")" -maxdepth 1 -type f -name "$(basename "$dest_file").part-*" | wc -l | tr -d ' ')
    if (( part_total == 0 )); then
      echo "Failed to create split parts for $rel_path" >&2
      exit 1
    fi

    idx=1
    while IFS= read -r part_file; do
      part_rel="${part_file#$OUT_DIR/}"
      part_size=$(stat -f %z "$part_file")
      part_sha=$(shasum -a 256 "$part_file" | awk '{print $1}')
      printf "sharded\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$rel_path" "$orig_size" "$orig_sha" "$idx" "$part_total" "$part_rel" "$part_size" "$part_sha" >> "$MANIFEST"
      idx=$((idx + 1))
    done < <(find "$(dirname "$dest_file")" -maxdepth 1 -type f -name "$(basename "$dest_file").part-*" | sort)

    split_count=$((split_count + 1))
  else
    cp -p "$src_file" "$dest_file"
    part_size=$(stat -f %z "$dest_file")
    part_sha=$(shasum -a 256 "$dest_file" | awk '{print $1}')
    printf "file\t%s\t%s\t%s\t1\t1\t%s\t%s\t%s\n" \
      "$rel_path" "$orig_size" "$orig_sha" "$rel_path" "$part_size" "$part_sha" >> "$MANIFEST"
    copy_count=$((copy_count + 1))
  fi

  file_count=$((file_count + 1))
done < <(find "$SRC_DIR" -type f ! -path '*/.*' | sort)

echo "Done. Processed files: $file_count"
echo "Copied as-is: $copy_count"
echo "Sharded files: $split_count"
echo "Manifest: $MANIFEST"
