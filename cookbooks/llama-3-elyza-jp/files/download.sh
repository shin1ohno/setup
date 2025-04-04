#!/bin/bash

# Script to download Llama-3-ELYZA-JP-8B-q4_k_m.gguf from Hugging Face
set -e

MODEL_FILE="Llama-3-ELYZA-JP-8B-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/elyza/Llama-3-ELYZA-JP-8B-GGUF/resolve/main/Llama-3-ELYZA-JP-8B-q4_k_m.gguf"
DEST_DIR="${1:-$HOME/models}"

# Create destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

# Check if file already exists
if [ -f "$DEST_DIR/$MODEL_FILE" ]; then
  echo "Model file already exists at $DEST_DIR/$MODEL_FILE"
  echo "Checking file size..."
  
  # Get file size in bytes
  FILE_SIZE=$(stat -f%z "$DEST_DIR/$MODEL_FILE" 2>/dev/null || stat -c%s "$DEST_DIR/$MODEL_FILE")
  EXPECTED_SIZE=5284823328  # Expected size in bytes (approximately 4.92GB)
  
  if [ "$FILE_SIZE" -eq "$EXPECTED_SIZE" ]; then
    echo "File size matches expected size. File appears to be complete."
    exit 0
  else
    echo "File size ($FILE_SIZE bytes) does not match expected size ($EXPECTED_SIZE bytes)."
    echo "File may be corrupted or incomplete. Redownloading..."
    rm "$DEST_DIR/$MODEL_FILE"
  fi
fi

echo "Downloading $MODEL_FILE to $DEST_DIR..."
echo "This is a large file (approx. 4.92GB) and may take a while to download."

# Check if wget is available, if not use curl
if command -v wget &> /dev/null; then
  wget -O "$DEST_DIR/$MODEL_FILE" "$MODEL_URL" --progress=bar:force:noscroll
elif command -v curl &> /dev/null; then
  curl -L "$MODEL_URL" -o "$DEST_DIR/$MODEL_FILE" --progress-bar
else
  echo "Error: Neither wget nor curl is available. Please install one of them and try again."
  exit 1
fi

if [ $? -eq 0 ]; then
  echo "Download completed successfully!"
  echo "Model file saved to: $DEST_DIR/$MODEL_FILE"
else
  echo "Download failed. Please try again."
  exit 1
fi

# Make the file readable by the user only
chmod 600 "$DEST_DIR/$MODEL_FILE"

echo "Done!"
