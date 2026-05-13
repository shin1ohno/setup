#!/bin/bash

# Script to download Llama-3-ELYZA-JP-8B-q4_k_m.gguf from Hugging Face
set -euo pipefail

MODEL_FILE="Llama-3-ELYZA-JP-8B-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/elyza/Llama-3-ELYZA-JP-8B-GGUF/resolve/main/Llama-3-ELYZA-JP-8B-q4_k_m.gguf"
DEST_DIR="${1:-$HOME/models}"

# Expected size from Hugging Face Content-Length on
# elyza/Llama-3-ELYZA-JP-8B-GGUF main branch (verified 2026-05-13).
# Update this if upstream re-quantizes the model.
EXPECTED_SIZE=4920733984

file_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

mkdir -p "$DEST_DIR"

# Self-heal partial downloads: if the file exists at the destination but
# its size doesn't match EXPECTED_SIZE, treat it as truncated and remove
# before redownloading. The previous (broken) shape exited 0 on size
# mismatch which silently propagated a corrupt GGUF to `ollama create`.
if [ -f "$DEST_DIR/$MODEL_FILE" ]; then
  FILE_SIZE=$(file_size "$DEST_DIR/$MODEL_FILE")
  if [ "$FILE_SIZE" -eq "$EXPECTED_SIZE" ]; then
    echo "Model file already present at expected size (${EXPECTED_SIZE} bytes); skipping download."
    exit 0
  fi
  echo "Existing file size (${FILE_SIZE}) != expected (${EXPECTED_SIZE}); removing and redownloading."
  rm "$DEST_DIR/$MODEL_FILE"
fi

echo "Downloading ${MODEL_FILE} (~$((EXPECTED_SIZE / 1024 / 1024 / 1024))GB) to ${DEST_DIR}..."

if command -v wget >/dev/null 2>&1; then
  wget -O "$DEST_DIR/$MODEL_FILE" "$MODEL_URL" --progress=bar:force:noscroll
elif command -v curl >/dev/null 2>&1; then
  # -f: fail on 4xx/5xx (don't silently save error body as the model)
  # -L: follow redirects (HF returns 302 to a CDN URL)
  curl -fL "$MODEL_URL" -o "$DEST_DIR/$MODEL_FILE" --progress-bar
else
  echo "Error: Neither wget nor curl is available." >&2
  exit 1
fi

# Verify the post-download size — wget/curl can exit 0 on partial
# transfers (broken connection mid-stream) when content-length isn't
# enforced. Without this re-check, mitamae would mark the resource
# successful and ollama create would fail downstream with a confusing
# tensor offset error.
FINAL_SIZE=$(file_size "$DEST_DIR/$MODEL_FILE")
if [ "$FINAL_SIZE" -ne "$EXPECTED_SIZE" ]; then
  echo "ERROR: post-download size (${FINAL_SIZE}) != expected (${EXPECTED_SIZE}); GGUF is incomplete." >&2
  rm -f "$DEST_DIR/$MODEL_FILE"
  exit 1
fi

chmod 600 "$DEST_DIR/$MODEL_FILE"
echo "Model file saved to ${DEST_DIR}/${MODEL_FILE} (${FINAL_SIZE} bytes)."
