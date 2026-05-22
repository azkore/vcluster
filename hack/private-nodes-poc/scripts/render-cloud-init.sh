#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Render cloud-init from scripts/cloud-init.example.yaml with an operator SSH public key.

Required config:
  PUBLIC_KEY_FILE   path to the SSH public key to inject

Optional config:
  TEMPLATE          cloud-init template path; default scripts/cloud-init.example.yaml
  OUT               rendered output path; default /tmp/private-nodes-cloud-init.yaml

The rendered file is written with mode 0600. The script fails if the template
placeholder remains in the output.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${TEMPLATE:-${SCRIPT_DIR}/cloud-init.example.yaml}"
OUT="${OUT:-/tmp/private-nodes-cloud-init.yaml}"

: "${PUBLIC_KEY_FILE:?set PUBLIC_KEY_FILE}"

if [[ ! -f "$PUBLIC_KEY_FILE" ]]; then
  echo "public key file not found: $PUBLIC_KEY_FILE" >&2
  exit 1
fi
if [[ ! -f "$TEMPLATE" ]]; then
  echo "template not found: $TEMPLATE" >&2
  exit 1
fi

public_key="$(tr -d '\n' <"$PUBLIC_KEY_FILE")"
if [[ -z "$public_key" || "$public_key" != ssh-* ]]; then
  echo "PUBLIC_KEY_FILE does not look like an SSH public key" >&2
  exit 1
fi

umask 077
python3 - "$TEMPLATE" "$OUT" "$public_key" <<'PY'
import pathlib
import sys

template, output, public_key = sys.argv[1:]
placeholder = "ssh-ed25519 REPLACE_WITH_OPERATOR_PUBLIC_KEY vcluster-private-nodes-repro"
data = pathlib.Path(template).read_text()
if placeholder not in data:
    raise SystemExit(f"placeholder not found in template: {placeholder}")
data = data.replace(placeholder, public_key)
if "REPLACE_WITH_OPERATOR_PUBLIC_KEY" in data:
    raise SystemExit("placeholder remained in rendered cloud-init")
pathlib.Path(output).write_text(data)
PY
chmod 0600 "$OUT"
echo "Rendered cloud-init to $OUT"
