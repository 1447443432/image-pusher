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
[[ "$NOTIFY_HAP" == true || "$NOTIFY_HAP" == false ]] || die 'NOTIFY_HAP must be true or false'

mkdir -p "$OUTPUT_DIR"
mapfile -t entries < <(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data.get("images"), list) or not data["images"]:
    raise SystemExit("images must be a non-empty array")
for item in data["images"]:
    image = item.get("image")
    architecture = item.get("architecture")
    platform = item.get("platform", f"linux/{architecture}")
    if not image or architecture not in {"amd64", "arm64"}:
        raise SystemExit("each image needs image and architecture=amd64|arm64")
    print(f"{image}\t{architecture}\t{platform}")
PY
)

manifest="$OUTPUT_DIR/release-manifest.json"
printf '{\n  "images": [\n' > "$manifest"
index=0
for entry in "${entries[@]}"; do
  IFS=$'\t' read -r image architecture platform <<< "$entry"
  safe_name="$(echo "$image" | tr '/:' '__')-$architecture.tar.gz"
  archive="$OUTPUT_DIR/$safe_name"
  log "pulling $image ($platform)"
  docker pull --platform "$platform" "$image" >/dev/null
  log "saving $image -> $archive"
  docker save "$image" | gzip -9 > "$archive"
  [[ "$index" -eq 0 ]] || printf ',\n' >> "$manifest"
  python3 - "$manifest" "$image" "$architecture" "$platform" "$safe_name" <<'PY'
import json, sys
path, image, architecture, platform, archive = sys.argv[1:]
with open(path, "a", encoding="utf-8") as f:
    json.dump({"image": image, "architecture": architecture, "platform": platform, "archive": archive}, f, ensure_ascii=False, indent=2)
PY
  index=$((index + 1))
done
printf '\n  ]\n}\n' >> "$manifest"
if [[ "$NOTIFY_HAP" == true && -n "$WEBHOOK_URL" ]]; then
  payload="$OUTPUT_DIR/webhook-payload.json"
  CONFIG_FILE="$CONFIG_FILE" python3 - "$payload" <<'PY'
import json, os, sys
with open(os.environ["CONFIG_FILE"], encoding="utf-8") as f:
    config = json.load(f)
data = {"event": "image_release_ready", "release_name": config.get("release_name", "image-release"), "images": config["images"]}
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
