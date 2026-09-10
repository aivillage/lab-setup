#!/usr/bin/env bash

PATCHES_DIR="${1:?Usage: generate-config <patches-dir> [secrets-file]}"
SECRETS_FILE="${2:-}"

if [ ! -d "$PATCHES_DIR" ]; then
  echo "Error: patches dir $PATCHES_DIR not found. Run generate-patches first." >&2
  exit 1
fi

# Expand to absolute path and change into target output directory
if [ -n "$SECRETS_FILE" ]; then
  SECRETS_DIR="$(cd "$(dirname "$SECRETS_FILE")" 2>/dev/null && pwd || echo "")"
  if [ -n "$SECRETS_DIR" ]; then
    SECRETS_FILE="$SECRETS_DIR/$(basename "$SECRETS_FILE")"
  fi
fi
PATCHES_DIR="$(cd "$PATCHES_DIR" && pwd)"
cd "$PATCHES_DIR" || exit 1

SECRETS_FLAG=()
if [ -n "$SECRETS_FILE" ] && [ -f "$SECRETS_FILE" ]; then
  SECRETS_FLAG=("--with-secrets" "$SECRETS_FILE")
elif [ -f "$PATCHES_DIR/secrets.yaml" ]; then
  SECRETS_FLAG=("--with-secrets" "$PATCHES_DIR/secrets.yaml")
elif [ -f "secrets.yaml" ]; then
  SECRETS_FLAG=("--with-secrets" "secrets.yaml")
else
  echo "Error: no secrets file provided and secrets.yaml not found in $PATCHES_DIR" >&2
  exit 1
fi

PATCH_FLAGS=()
if [ -d "$PATCHES_DIR/base-patches" ]; then
  for f in "$PATCHES_DIR/base-patches"/*.yaml; do
    [ -f "$f" ] || continue
    PATCH_FLAGS+=("--config-patch" "@$f")
  done
fi

if [ -n "${EXTRA_PATCHES:-}" ]; then
  for p in ${EXTRA_PATCHES}; do
    [ -f "$p" ] && PATCH_FLAGS+=("--config-patch" "@$p")
  done
fi

EFFECTIVE_PATCH_FILE="${MACHINE_PATCH_FILE}"
if [ -n "${SCHEMATIC_FILE:-}" ] && [ -f "${SCHEMATIC_FILE}" ]; then
  SCHEMATIC_ID="$(tr -d '[:space:]' < "${SCHEMATIC_FILE}")"
  export SCHEMATIC_ID
  if [ -n "${SCHEMATIC_ID}" ]; then
    TMP_PATCH="$(mktemp "${TMPDIR:-/tmp}/talos-patch-XXXXXX.json")"
    sed "s|__SCHEMATIC_ID__|${SCHEMATIC_ID}|g" "${MACHINE_PATCH_FILE}" > "${TMP_PATCH}"
    EFFECTIVE_PATCH_FILE="${TMP_PATCH}"
  fi
fi

if [[ "${OUTPUT_TYPE}" == *","* ]]; then
  TMP_OUT="$(mktemp -d "${TMPDIR:-/tmp}/talos-out-XXXXXX")"
  trap 'rm -rf "${TMP_OUT}" "${TMP_PATCH:-}"' EXIT
  TARGET_OUT="${TMP_OUT}"
else
  TARGET_OUT="${MACHINE_NAME}.yaml"
fi

talosctl gen config \
  --force \
  --talos-version "${TALOS_VERSION}" \
  --output-types "${OUTPUT_TYPE}" \
  --with-docs=false \
  --with-examples=false \
  "${SECRETS_FLAG[@]}" \
  "${PATCH_FLAGS[@]}" \
  --config-patch "@${EFFECTIVE_PATCH_FILE}" \
  --output "${TARGET_OUT}" \
  "${CLUSTER_NAME}" \
  "${CLUSTER_ENDPOINT}"

if [ -n "${TMP_OUT:-}" ]; then
  if [ -f "${TMP_OUT}/controlplane.yaml" ]; then
    mv "${TMP_OUT}/controlplane.yaml" "${MACHINE_NAME}.yaml"
  elif [ -f "${TMP_OUT}/worker.yaml" ]; then
    mv "${TMP_OUT}/worker.yaml" "${MACHINE_NAME}.yaml"
  fi

  if [ -f "${TMP_OUT}/talosconfig" ]; then
    mv "${TMP_OUT}/talosconfig" ./talosconfig
    if [ -n "${CLUSTER_ENDPOINT:-}" ]; then
      ENDPOINT_IP="$(echo "${CLUSTER_ENDPOINT}" | sed -E 's|https?://(.*):6443|\1|')"
      talosctl --talosconfig talosconfig config endpoint "$ENDPOINT_IP" 2>/dev/null || true
      chmod 644 talosconfig || true
    fi
  fi
fi

# Strip conflicting HostnameConfig document and base disk line if diskSelector is present
python3 -c '
import os, re
name = os.environ["MACHINE_NAME"]
filename = f"{name}.yaml"
with open(filename, "r") as f:
    content = f.read()
docs = re.split(r"\n---\n?", content)
filtered = [d for d in docs if "HostnameConfig" not in d]
text = "\n---\n".join(filtered).strip() + "\n"
if "diskSelector:" in text:
    lines = [l for l in text.splitlines() if not re.match(r"^\s*disk:\s*", l)]
    text = "\n".join(lines) + "\n"
schematic_id = os.environ.get("SCHEMATIC_ID", "")
if schematic_id:
    text = text.replace("__SCHEMATIC_ID__", schematic_id)
with open(filename, "w") as f:
    f.write(text)
'

if ! talosctl validate --config "${MACHINE_NAME}.yaml" --mode container >/dev/null 2>&1; then
  VAL_ERR=$(talosctl validate --config "${MACHINE_NAME}.yaml" --mode container 2>&1 || true)
  CLEAN_ERR=$(echo "$VAL_ERR" | grep -v "issuing CA key" | grep -v "1 error occurred:" || true)
  if [ -n "$CLEAN_ERR" ]; then
    echo "Talos config validation error: $CLEAN_ERR" >&2
    exit 1
  fi
fi

echo "Generated ${MACHINE_NAME}.yaml (${OUTPUT_TYPE})"
