#!/usr/bin/env bash
# Downloads the offline TTS/G2P/translation model binaries this app bundles
# from GCS into WebnovelReader/Resources/ before building — keeps them out
# of git (see tts-pipeline-infra's fetch-model.sh for the equivalent
# server-side pattern; bucket is public-read, plain HTTPS, no gcloud auth
# needed to build). Skips files already present, so a normal incremental
# build does one stat per file, not 13 network round-trips.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE_URL="https://storage.googleapis.com/tts-pipeline-yl-ios-assets/models"
RESOURCES="WebnovelReader/Resources"

FILES=(
  "VieNeuOfflineV2/vieneu-tts-v2-turbo.gguf"
  "VieNeuOfflineV2/vieneu_decoder_int8.onnx"
  "VieNeuOfflineV3/vieneu_backbone_shared.data"
  "VieNeuOfflineV3/vieneu_v3_heads.npz"
  "VieNeuOfflineV3/moss_audio_tokenizer_decode_shared.data"
  "VieNeuOfflineV3/vieneu_acoustic_cached.onnx"
  "VieNeuOfflineV3/vieneu_prefill.onnx"
  "VieNeuOfflineV3/vieneu_decode_step.onnx"
  "VieNeuOfflineV3/moss_audio_tokenizer_decode_full.onnx"
  "PiperOffline/vi_VN-vais1000-medium.onnx"
  "sea_g2p.bin"
  "BundledTranslation/en-vi/decoder_merged.onnx"
  "BundledTranslation/en-vi/encoder.onnx"
)

for f in "${FILES[@]}"; do
  dest="$RESOURCES/$f"
  if [ -f "$dest" ]; then
    continue
  fi
  echo "fetch-models.sh: downloading $f"
  mkdir -p "$(dirname "$dest")"
  curl -fsSL "$BASE_URL/$f" -o "$dest.part"
  mv "$dest.part" "$dest"
done
