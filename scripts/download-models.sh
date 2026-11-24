#!/bin/bash
# Downloads the speech model and the voice-activity model HearMe needs (about 2.4 GB)
# from Hugging Face, verifies their SHA-256, and puts them where the app looks.
# Safe to re-run: files already in place are checked and skipped, and an interrupted
# download resumes where it stopped.
#
#   scripts/download-models.sh
#   HEARME_MODELS_DIR=/some/dir scripts/download-models.sh   # different target folder
set -euo pipefail

DEST="${HEARME_MODELS_DIR:-$HOME/Library/Application Support/HearMe/models}"
HF="https://huggingface.co"

# name | repo | sha256
MODELS=(
  "cohere-transcribe-arabic-07-2026-Q8_0.gguf|handy-computer/cohere-transcribe-arabic-07-2026-gguf|910de5c9c57f9fd8a280e1701f9cd96f63768878c1ca9e4ecf23638a5e0fef16"
  "silero-vad-v6.2-F32.gguf|handy-computer/silero-vad-v6.2-gguf|0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6"
)

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p "$DEST"
for entry in "${MODELS[@]}"; do
  IFS='|' read -r name repo expected <<<"$entry"
  target="$DEST/$name"
  partial="$target.part"

  if [[ -f "$target" ]]; then
    if [[ "$(sha "$target")" == "$expected" ]]; then
      echo "✓ $name already in place"
      continue
    fi
    echo "! $name is damaged or a different version; downloading again"
    rm -f "$target"
  fi

  echo "↓ $name (from $repo)"
  curl --fail --location --continue-at - --retry 3 --progress-bar \
    --output "$partial" "$HF/$repo/resolve/main/$name"

  actual="$(sha "$partial")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$partial"
    echo "✗ $name failed the checksum (got $actual). Run the script again." >&2
    exit 1
  fi
  mv "$partial" "$target"
  echo "✓ $name verified"
done

echo "Models are ready in: $DEST"
