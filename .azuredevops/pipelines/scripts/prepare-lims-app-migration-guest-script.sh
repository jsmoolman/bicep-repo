#!/usr/bin/env bash
# Concatenate the reviewed environment mapping into the guest copy script
# at the mapping-inject marker so Managed Run Command delivers one file
# that still uses the same mapping as the control-plane script.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <mapping.ps1> <copy.ps1> <output.ps1>" >&2
  exit 2
fi

mapping_file=$1
copy_file=$2
output_file=$3
marker='# <LIMS_APP_MIG_MAPPING_INJECT>'

if [[ ! -f "$mapping_file" ]]; then
  echo "ERROR: mapping file '$mapping_file' was not found." >&2
  exit 2
fi
if [[ ! -f "$copy_file" ]]; then
  echo "ERROR: guest copy script '$copy_file' was not found." >&2
  exit 2
fi

python3 - "$mapping_file" "$copy_file" "$output_file" "$marker" <<'PY'
import sys
from pathlib import Path

mapping_path, copy_path, output_path, marker = sys.argv[1:5]
mapping = Path(mapping_path).read_text(encoding="utf-8")
copy = Path(copy_path).read_text(encoding="utf-8")
if marker not in copy:
    raise SystemExit(f"Guest copy script {copy_path} is missing mapping inject marker {marker!r}.")
Path(output_path).write_text(copy.replace(marker, mapping, 1), encoding="utf-8")
PY
