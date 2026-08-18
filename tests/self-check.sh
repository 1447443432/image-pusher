#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
grep -q 'docker buildx imagetools create' "$root/scripts/push-images.sh"
grep -q 'HAP_WEBHOOK_URL' "$root/scripts/push-images.sh"
grep -q 'amd64' "$root/scripts/push-images.sh"
grep -q 'arm64' "$root/scripts/push-images.sh"
grep -q 'softprops/action-gh-release' "$root/.github/workflows/image-make.yml"
grep -q 'linux_arm64_kafka-ui:main' "$root/images.json"
grep -q 'docker save' "$root/scripts/create-release.sh"
grep -q "operation == 'push-and-release'" "$root/.github/workflows/image-make.yml"
grep -q 'branches:' "$root/.github/workflows/image-make.yml"
grep -q "github.event_name == 'push'" "$root/.github/workflows/image-make.yml"
echo 'self-check passed'
