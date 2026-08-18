#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-images.json}"
OUTPUT_DIR="${OUTPUT_DIR:-release-assets}"
NOTIFY_HAP="${NOTIFY_HAP:-false}"
WEBHOOK_URL="${HAP_WEBHOOK_URL:-}"

die() { printf '[image-release] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[image-release] %s\n' "$*"; }
command -v docker >/dev/null || die 'docker is required'
command -v python3 >/dev/null || die 'python3 is required'
command -v sha256sum >/dev/null || die 'sha256sum is required'
[[ "$NOTIFY_HAP" == true || "$NOTIFY_HAP" == false ]] || die 'NOTIFY_HAP must be true or false'

mkdir -p "$OUTPUT_DIR"
mapfile -t entries < <(python3 - "$CONFIG_FILE" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
images = data.get("images")
if not isinstance(images, list) or not images:
    raise SystemExit("images must be a non-empty array")
keys = []
for item in images:
    image = item.get("image")
    architecture = item.get("architecture")
    if not image or architecture not in {"amd64", "arm64"}:
        raise SystemExit("each image needs image and architecture=amd64|arm64")
    ref = image.rsplit("/", 1)[-1]
    name, tag = ref.rsplit(":", 1) if ":" in ref else (ref, "latest")
    keys.append((name, tag))
counts = {key: keys.count(key) for key in set(keys)}
for item, key in zip(images, keys):
    image = item["image"]
    architecture = item["architecture"]
    platform = item.get("platform", f"linux/{architecture}")
    name, tag = key
    base = re.sub(r"[^A-Za-z0-9_.-]+", "_", f"{name}_{tag}")
    needs_architecture = 1 if counts[key] > 1 else 0
    print(f"{image}\t{architecture}\t{platform}\t{base}\t{needs_architecture}")
PY
)

records_file="$(mktemp)"
trap 'rm -f "$records_file"' EXIT
for entry in "${entries[@]}"; do
  IFS=$'\t' read -r image architecture platform archive_base needs_architecture <<< "$entry"
  archive_name="$archive_base"
  [[ "$needs_architecture" == 1 ]] && archive_name+="_$architecture"
  archive_name+=".tar.gz"
  archive="$OUTPUT_DIR/$archive_name"
  log "pulling $image ($platform)"
  docker pull --platform "$platform" "$image" >/dev/null
  log "saving $image -> $archive"
  docker save "$image" | gzip -9 > "$archive"
  digest="$(docker buildx imagetools inspect "$image" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
  sha256="$(sha256sum "$archive" | awk '{print $1}')"
  size="$(wc -c < "$archive" | tr -d ' ')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$image" "$architecture" "$platform" "$archive_name" "$digest" "$size" "$sha256" >> "$records_file"
done

manifest="$OUTPUT_DIR/release-manifest.json"
CONFIG_FILE="$CONFIG_FILE" RECORDS_FILE="$records_file" MANIFEST_FILE="$manifest" python3 - <<'PY'
import json, os
from datetime import datetime, timezone
with open(os.environ["CONFIG_FILE"], encoding="utf-8") as f:
    config = json.load(f)
records = []
with open(os.environ["RECORDS_FILE"], encoding="utf-8") as f:
    for line in f:
        image, architecture, platform, archive, digest, size, sha256 = line.rstrip("\n").split("\t")
        records.append({"image": image, "architecture": architecture, "platform": platform, "archive": archive, "digest": digest, "size_bytes": int(size), "sha256": sha256})
data = {
    "schema_version": 1,
    "release_name": config.get("release_name", "image-release"),
    "release_tag": f"image-{os.environ.get('GITHUB_RUN_NUMBER', 'local')}",
    "repository": os.environ.get("GITHUB_REPOSITORY", ""),
    "commit": os.environ.get("GITHUB_SHA", ""),
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "images": records,
    "summary": {"count": len(records), "architectures": sorted({item["architecture"] for item in records})}
}
with open(os.environ["MANIFEST_FILE"], "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

if [[ "$NOTIFY_HAP" == true && -n "$WEBHOOK_URL" ]]; then
  payload="$OUTPUT_DIR/webhook-payload.json"
  MANIFEST_FILE="$manifest" python3 - "$payload" <<'PY'
import json, os, sys
with open(os.environ["MANIFEST_FILE"], encoding="utf-8") as f:
    manifest = json.load(f)
data = {"event": "image_release_ready", "release": manifest}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  headers=(-H 'Content-Type: application/json')
  [[ -z "${HAP_WEBHOOK_APP_KEY:-}" ]] || headers+=(-H "AppKey: $HAP_WEBHOOK_APP_KEY")
  [[ -z "${HAP_WEBHOOK_SIGN:-}" ]] || headers+=(-H "Sign: $HAP_WEBHOOK_SIGN")
  curl --fail-with-body --retry 2 -sS -X POST "$WEBHOOK_URL" "${headers[@]}" --data-binary "@$payload" >/dev/null
fi
log "done; release assets are in $OUTPUT_DIR"