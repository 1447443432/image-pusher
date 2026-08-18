#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_IMAGE="${SOURCE_IMAGE:?SOURCE_IMAGE is required, e.g. centos:7.9.2009}"
TARGET_IMAGE="${TARGET_IMAGE:-}"
PLATFORMS="${PLATFORMS:-amd64,arm64}"
PUBLISH="${PUBLISH:-true}"
PACKAGE="${PACKAGE:-false}"
NOTIFY_HAP="${NOTIFY_HAP:-true}"
OUTPUT_DIR="${OUTPUT_DIR:-release-assets}"
WEBHOOK_URL="${HAP_WEBHOOK_URL:-}"

log() { printf '[image-pusher] %s\n' "$*"; }
die() { printf '[image-pusher] ERROR: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null || die 'docker is required'
docker buildx version >/dev/null 2>&1 || die 'docker buildx is required'
[[ "$PUBLISH" == true || "$PUBLISH" == false ]] || die 'PUBLISH must be true or false'
[[ "$PACKAGE" == true || "$PACKAGE" == false ]] || die 'PACKAGE must be true or false'
[[ "$NOTIFY_HAP" == true || "$NOTIFY_HAP" == false ]] || die 'NOTIFY_HAP must be true or false'

IFS=',' read -r -a platform_list <<< "$PLATFORMS"
normalized=()
for platform in "${platform_list[@]}"; do
  case "$platform" in
    amd64) normalized+=(linux/amd64) ;;
    arm64) normalized+=(linux/arm64) ;;
    linux/amd64|linux/arm64) normalized+=("$platform") ;;
    '') ;;
    *) die "unsupported platform: $platform (use amd64,arm64)" ;;
  esac
done
[[ "${#normalized[@]}" -gt 0 ]] || die 'PLATFORMS must contain amd64 and/or arm64'
if [[ "$PUBLISH" == true && -z "$TARGET_IMAGE" ]]; then die 'TARGET_IMAGE is required when PUBLISH=true'; fi

if [[ "$PUBLISH" == true ]]; then
  log "copying $SOURCE_IMAGE -> $TARGET_IMAGE ($PLATFORMS)"
  args=()
  for platform in "${normalized[@]}"; do args+=(--platform "$platform"); done
  docker buildx imagetools create "${args[@]}" --tag "$TARGET_IMAGE" "$SOURCE_IMAGE"
fi

digest=''
if [[ "$PUBLISH" == true ]]; then
  digest="$(docker buildx imagetools inspect "$TARGET_IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
fi
mkdir -p "$OUTPUT_DIR"
package_records_file="$(mktemp)"
trap 'rm -f "$package_records_file"' EXIT
platform_json='['
for platform in "${platform_list[@]}"; do
  [[ -z "$platform" ]] && continue
  [[ "$platform" == linux/* ]] && platform="${platform#linux/}"
  [[ "$platform" == amd64 || "$platform" == arm64 ]] || continue
  [[ "$platform_json" == '[' ]] || platform_json+=','
  platform_json+="\"$platform\":true"
done
platform_json+=']'

manifest="$OUTPUT_DIR/image-manifest.json"
IMAGE_DIGEST="$digest" PLATFORM_JSON="$platform_json" python3 - "$manifest" <<'PY'
import json, os, sys
data = {"source_image": os.environ["SOURCE_IMAGE"], "target_image": os.environ.get("TARGET_IMAGE", ""), "digest": os.environ.get("IMAGE_DIGEST", ""), "platforms": json.loads(os.environ["PLATFORM_JSON"]), "published": os.environ["PUBLISH"] == "true"}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

if [[ "$PACKAGE" == true ]]; then
  [[ "$PUBLISH" == true ]] || die 'PACKAGE=true requires PUBLISH=true'
  package_base="$(python3 - "$TARGET_IMAGE" <<'PY'
import re, sys
ref = sys.argv[1].rsplit("/", 1)[-1]
name, tag = ref.rsplit(":", 1) if ":" in ref else (ref, "latest")
name = re.sub(r"^linux_(?:amd64|arm64)_", "", name)
print(re.sub(r"[^A-Za-z0-9_.-]+", "_", f"{name}_{tag}"))
PY
)"
  for platform in "${normalized[@]}"; do
    arch="${platform#linux/}"
    archive_name="$package_base"
    [[ "${#normalized[@]}" -gt 1 ]] && archive_name+="_$arch"
    archive_name+=".tar.gz"
    archive="$OUTPUT_DIR/$archive_name"
    log "packaging $TARGET_IMAGE ($platform) -> $archive"
    docker pull --platform "$platform" "$TARGET_IMAGE" >/dev/null
    docker save "$TARGET_IMAGE" | gzip -9 > "$archive"
    sha256="$(sha256sum "$archive" | awk '{print $1}')"
    size="$(wc -c < "$archive" | tr -d ' ')"
    printf '%s\t%s\t%s\t%s\n' "$arch" "$archive_name" "$size" "$sha256" >> "$package_records_file"
  done
fi

IMAGE_DIGEST="$digest" PLATFORM_JSON="$platform_json" PACKAGE_RECORDS_FILE="$package_records_file" MANIFEST_FILE="$manifest" python3 - <<'PY'
import json, os
from datetime import datetime, timezone
records = []
if os.path.exists(os.environ["PACKAGE_RECORDS_FILE"]):
    with open(os.environ["PACKAGE_RECORDS_FILE"], encoding="utf-8") as f:
        for line in f:
            architecture, archive, size, sha256 = line.rstrip("\n").split("\t")
            records.append({"architecture": architecture, "archive": archive, "size_bytes": int(size), "sha256": sha256})
data = {
    "schema_version": 1,
    "source_image": os.environ["SOURCE_IMAGE"],
    "target_image": os.environ.get("TARGET_IMAGE", ""),
    "digest": os.environ.get("IMAGE_DIGEST", ""),
    "platforms": json.loads(os.environ["PLATFORM_JSON"]),
    "published": os.environ["PUBLISH"] == "true",
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "repository": os.environ.get("GITHUB_REPOSITORY", ""),
    "commit": os.environ.get("GITHUB_SHA", ""),
    "release_tag": os.environ.get("RELEASE_TAG", f"image-{os.environ.get('GITHUB_RUN_NUMBER', 'local')}"),
    "packages": records
}
with open(os.environ["MANIFEST_FILE"], "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  MANIFEST_FILE="$manifest" python3 - <<'PY' >> "$GITHUB_STEP_SUMMARY"
import json, os
with open(os.environ["MANIFEST_FILE"], encoding="utf-8") as f:
    data = json.load(f)
print("# Push image summary")
print()
print(f"- Source image: `{data['source_image']}`")
print(f"- Target image: `{data['target_image'] or '(not published)'}`")
print(f"- Published: `{str(data['published']).lower()}`")
print(f"- Platforms: `{', '.join(k for k, v in data['platforms'].items() if v)}`")
if data["digest"]:
    print(f"- Digest: `{data['digest']}`")
print(f"- Release tag: `{data['release_tag']}`")
if data["packages"]:
    print("\n## Packages")
    print("\n| Architecture | Archive | SHA256 |\n| --- | --- | --- |")
    for item in data["packages"]:
        print(f"| {item['architecture']} | `{item['archive']}` | `{item['sha256']}` |")
else:
    print("\nNo release packages were created.")
PY
fi

if [[ "$NOTIFY_HAP" == true && -n "$WEBHOOK_URL" ]]; then
  payload="$OUTPUT_DIR/webhook-payload.json"
  IMAGE_DIGEST="$digest" PLATFORM_JSON="$platform_json" python3 - "$payload" <<'PY'
import json, os, sys
data = {"event": "image_pushed", "source_image": os.environ["SOURCE_IMAGE"], "target_image": os.environ.get("TARGET_IMAGE", ""), "digest": os.environ.get("IMAGE_DIGEST", ""), "platforms": json.loads(os.environ["PLATFORM_JSON"]), "release_package": os.environ.get("PACKAGE") == "true"}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  log 'posting result to HAP webhook'
  headers=(-H 'Content-Type: application/json')
  [[ -z "${HAP_WEBHOOK_APP_KEY:-}" ]] || headers+=(-H "AppKey: $HAP_WEBHOOK_APP_KEY")
  [[ -z "${HAP_WEBHOOK_SIGN:-}" ]] || headers+=(-H "Sign: $HAP_WEBHOOK_SIGN")
  curl --fail-with-body --retry 2 -sS -X POST "$WEBHOOK_URL" "${headers[@]}" --data-binary "@$payload" >/dev/null
fi
log "done; manifest: $manifest"
