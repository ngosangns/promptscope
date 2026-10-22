#!/usr/bin/env bash
# Test, build the darwin-arm64 CLI, and optionally publish it.
# Usage:
#   ./scripts/release-local.sh           # build only
#   ./scripts/release-local.sh --publish # create/upload the GitHub release for VERSION
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VER="$(tr -d '[:space:]' < VERSION)"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be X.Y.Z, got '${VER}'" >&2; exit 1; }
if [[ "${GITHUB_REF_TYPE:-}" == "tag" && -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_NAME}" != "v${VER}" ]]; then
  echo "tag ${GITHUB_REF_NAME} does not match VERSION ${VER}" >&2
  exit 1
fi

TAG="v${VER}"
CLI_ASSET="promptscope-v${VER}-darwin-arm64"
OUTDIR="${ROOT}/dist"
mkdir -p "$OUTDIR"

echo "Testing updater (version ${VER})..."
(cd go && go vet ./... && go test ./...)

echo "Testing analyzer..."
(cd macos && swift test)

echo "Building CLI..."
MAIN="macos/Sources/promptscope-cli/main.swift"
original_main="$(mktemp)"
cp "$MAIN" "$original_main"
restore_main() { cp "$original_main" "$MAIN"; rm -f "$original_main"; }
trap restore_main EXIT
perl -i -pe 's/^let releaseVersion = ".*"$/let releaseVersion = "'"$VER"'"/' "$MAIN"
(cd macos && swift build -c release --product promptscope-cli)
restore_main
trap - EXIT
CLI_BIN="$(cd macos && swift build -c release --show-bin-path)/promptscope-cli"
cp "$CLI_BIN" "${OUTDIR}/${CLI_ASSET}"
chmod +x "${OUTDIR}/${CLI_ASSET}"

printed="$("${OUTDIR}/${CLI_ASSET}" --version)"
[[ "$printed" == "promptscope ${VER}" ]] || { echo "CLI printed '${printed}', expected 'promptscope ${VER}'" >&2; exit 1; }
set +e
"${OUTDIR}/${CLI_ASSET}" >/dev/null 2>&1
cli_status=$?
set -e
[[ "$cli_status" -eq 2 ]] || { echo "CLI exit ${cli_status}, expected 2 (usage) for a missing command" >&2; exit 1; }

echo "Building updater..."
UPDATER_ASSET="promptscope-update-v${VER}-darwin-arm64"
(cd go && go build -trimpath -ldflags "-s -w -X main.version=${VER}" -o "${OUTDIR}/${UPDATER_ASSET}" ./cmd/promptscope)
chmod +x "${OUTDIR}/${UPDATER_ASSET}"
printed_updater="$("${OUTDIR}/${UPDATER_ASSET}" --version)"
[[ "$printed_updater" == "promptscope ${VER}" ]] || { echo "updater printed '${printed_updater}'" >&2; exit 1; }

(
  cd "$OUTDIR"
  shasum -a 256 "$CLI_ASSET" "$UPDATER_ASSET" > SHA256SUMS
)
echo "Wrote ${OUTDIR}/${CLI_ASSET}"
cat "${OUTDIR}/SHA256SUMS"

NOTES_FILE="$(mktemp)"
cat > "$NOTES_FILE" <<NOTES
Promptscope ${TAG}

CLI that measures the prompt of Grok, Kiro, OMP, Pi, Devin and DSH sessions on this machine. It never sends a session anywhere.

## CLI

\`\`\`bash
mkdir -p ~/.local/share/promptscope/bin ~/.local/bin
curl -fsSL -o ~/.local/share/promptscope/bin/promptscope-${VER} \\
  "https://github.com/ngosangns/promptscope/releases/download/${TAG}/${CLI_ASSET}"
curl -fsSL -o ~/.local/share/promptscope/bin/promptscope-update-${VER} \\
  "https://github.com/ngosangns/promptscope/releases/download/${TAG}/promptscope-update-v${VER}-darwin-arm64"
chmod 755 ~/.local/share/promptscope/bin/promptscope-${VER} ~/.local/share/promptscope/bin/promptscope-update-${VER}
ln -sfn ../share/promptscope/bin/promptscope-${VER} ~/.local/bin/promptscope
\`\`\`

After the first install, \`promptscope update\` downloads both assets, checks the GitHub digest, then swaps the symlink. A running copy keeps its old inode until the command is launched again.

## Asset

- CLI: \`${CLI_ASSET}\`
- Updater: \`promptscope-update-v${VER}-darwin-arm64\`
- Checksum: \`SHA256SUMS\` (\`shasum -a 256 -c SHA256SUMS\`)
NOTES

if [[ "${1:-}" == "--publish" ]]; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release ${TAG} exists; uploading assets..."
    gh release upload "$TAG" \
      "${OUTDIR}/${CLI_ASSET}" \
      "${OUTDIR}/promptscope-update-v${VER}-darwin-arm64" \
      "${OUTDIR}/SHA256SUMS" \
      --clobber
    gh release edit "$TAG" --notes-file "$NOTES_FILE" || true
  else
    echo "Creating release ${TAG}..."
    gh release create "$TAG" \
      "${OUTDIR}/${CLI_ASSET}" \
      "${OUTDIR}/promptscope-update-v${VER}-darwin-arm64" \
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
