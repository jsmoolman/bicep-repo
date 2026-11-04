#!/usr/bin/env bash
# Concatenate the reviewed environment mapping and the shared safety
# functions into the guest copy script at the inject markers so Managed
# Run Command delivers one file that still uses the same mapping and
# identity/reparse helpers as the control-plane script.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <mapping.ps1> <safety.ps1> <copy.ps1> <output.ps1>" >&2
  exit 2
fi

mapping_file=$1
safety_file=$2
copy_file=$3
output_file=$4
mapping_marker='# <LIMS_APP_MIG_MAPPING_INJECT>'
safety_marker='# <LIMS_APP_MIG_SAFETY_INJECT>'

if [[ ! -f "$mapping_file" ]]; then
  echo "ERROR: mapping file '$mapping_file' was not found." >&2
  exit 2
fi
if [[ ! -f "$safety_file" ]]; then
  echo "ERROR: safety file '$safety_file' was not found." >&2
  exit 2
fi
if [[ ! -f "$copy_file" ]]; then
  echo "ERROR: guest copy script '$copy_file' was not found." >&2
  exit 2
fi

python3 - "$mapping_file" "$safety_file" "$copy_file" "$output_file" "$mapping_marker" "$safety_marker" <<'PY'
import sys
from pathlib import Path

mapping_path, safety_path, copy_path, output_path, mapping_marker, safety_marker = sys.argv[1:7]
mapping = Path(mapping_path).read_text(encoding="utf-8")
safety = Path(safety_path).read_text(encoding="utf-8")
copy = Path(copy_path).read_text(encoding="utf-8")
if mapping_marker not in copy:
    raise SystemExit(f"Guest copy script {copy_path} is missing mapping inject marker {mapping_marker!r}.")
if safety_marker not in copy:
    raise SystemExit(f"Guest copy script {copy_path} is missing safety inject marker {safety_marker!r}.")
combined = copy.replace(mapping_marker, mapping, 1).replace(safety_marker, safety, 1)
Path(output_path).write_text(combined, encoding="utf-8")
PY
