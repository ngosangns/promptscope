#!/usr/bin/env bash
# Test, build the darwin-arm64 app zip and CLI, and optionally publish them.
# Usage:
#   ./scripts/release-local.sh           # build only
#   ./scripts/release-local.sh --publish # create/upload the GitHub release for VERSION
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VER="$(tr -d '[:space:]' < VERSION)"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be X.Y.Z, got '${VER}'" >&2; exit 1; }
PLIST_VER="$(plutil -extract CFBundleShortVersionString raw macos/Resources/Info.plist)"
[[ "$PLIST_VER" == "$VER" ]] || { echo "Info.plist short version ${PLIST_VER} != VERSION ${VER}" >&2; exit 1; }
if [[ "${GITHUB_REF_TYPE:-}" == "tag" && -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_NAME}" != "v${VER}" ]]; then
  echo "tag ${GITHUB_REF_NAME} does not match VERSION ${VER}" >&2
  exit 1
fi

TAG="v${VER}"
APP_ASSET="promptscope-v${VER}-darwin-arm64.zip"
CLI_ASSET="promptscope-cli-v${VER}-darwin-arm64"
OUTDIR="${ROOT}/dist"
mkdir -p "$OUTDIR"

echo "Testing (version ${VER})..."
(cd macos && swift test)

echo "Building app..."
(cd macos && make)
APP="${ROOT}/macos/promptscope.app"
APP_VER="$(defaults read "${APP}/Contents/Info" CFBundleShortVersionString)"
[[ "$APP_VER" == "$VER" ]] || { echo "built app version ${APP_VER} != VERSION ${VER}" >&2; exit 1; }
codesign --verify --strict "${APP}"

echo "Building CLI..."
(cd macos && swift build -c release --product promptscope-cli)
CLI_BIN="$(cd macos && swift build -c release --show-bin-path)/promptscope-cli"
cp "$CLI_BIN" "${OUTDIR}/${CLI_ASSET}"
chmod +x "${OUTDIR}/${CLI_ASSET}"
# No command is a usage error (exit 1). A crash or exit 0 means the binary is wrong.
set +e
"${OUTDIR}/${CLI_ASSET}" >/dev/null 2>&1
cli_status=$?
set -e
[[ "$cli_status" -eq 1 ]] || { echo "CLI exit ${cli_status}, expected 1 for a missing command" >&2; exit 1; }

ditto -c -k --keepParent "$APP" "${OUTDIR}/${APP_ASSET}"
(
  cd "$OUTDIR"
  shasum -a 256 "$APP_ASSET" "$CLI_ASSET" > SHA256SUMS
)
echo "Wrote ${OUTDIR}/${APP_ASSET}"
echo "Wrote ${OUTDIR}/${CLI_ASSET}"
cat "${OUTDIR}/SHA256SUMS"

NOTES_FILE="$(mktemp)"
cat > "$NOTES_FILE" <<NOTES
Promptscope ${TAG}

App macOS đo prompt của session Grok, Kiro, OMP, Pi và Devin trên máy này. Không gửi session đi đâu.

## Cài app

Tải \`${APP_ASSET}\`, giải nén, rồi mở \`promptscope.app\`.
Bản này ký ad-hoc, chưa notarize. Lần đầu macOS có thể chặn: System Settings → Privacy & Security → Open Anyway.

## CLI

\`\`\`bash
curl -fsSL -o promptscope "https://github.com/ngosangns/promptscope/releases/download/${TAG}/${CLI_ASSET}"
chmod +x promptscope
mkdir -p ~/.local/bin
mv promptscope ~/.local/bin/promptscope
\`\`\`

## Asset

- App: \`${APP_ASSET}\`
- CLI: \`${CLI_ASSET}\`
- Checksum: \`SHA256SUMS\` (\`shasum -a 256 -c SHA256SUMS\`)
NOTES

if [[ "${1:-}" == "--publish" ]]; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release ${TAG} exists; uploading assets..."
    gh release upload "$TAG" \
      "${OUTDIR}/${APP_ASSET}" \
      "${OUTDIR}/${CLI_ASSET}" \
      "${OUTDIR}/SHA256SUMS" \
      --clobber
    gh release edit "$TAG" --notes-file "$NOTES_FILE" || true
  else
    echo "Creating release ${TAG}..."
    gh release create "$TAG" \
      "${OUTDIR}/${APP_ASSET}" \
      "${OUTDIR}/${CLI_ASSET}" \
      "${OUTDIR}/SHA256SUMS" \
      --target "$(git rev-parse HEAD)" \
      --title "promptscope ${TAG}" \
      --notes-file "$NOTES_FILE"
  fi
  echo "Published: https://github.com/ngosangns/promptscope/releases/tag/${TAG}"
else
  echo "Dry build only. Pass --publish to create GitHub release ${TAG}."
fi
rm -f "$NOTES_FILE"
