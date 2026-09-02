# Offline model binaries

These files are not committed to git — `Scripts/fetch-models.sh` downloads
them from a public-read GCS bucket into this directory before every build
(see `project.yml`'s `prebuildScripts`). A fresh clone just needs to build
once; the script fills this folder in automatically.

Primary source (authoritative — always matches what the app was last built
and tested against):

```
https://storage.googleapis.com/tts-pipeline-yl-ios-assets/models/<path>
```

If that bucket is ever gone, each file's best-known public origin is listed
below, along with the sha256 of the exact copy this app uses — use the
checksum to confirm a re-downloaded file is really the same one, since
several of these have same-named variants at different quantization levels.

| File | sha256 | Likely public origin | Confidence |
|---|---|---|---|
| `PiperOffline/vi_VN-vais1000-medium.onnx` | `df1512ef...b809f` | [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices) (HF), `vi/vi_VN/vais1000/medium/` | High — same path used server-side, see `tts-reader-addon/server.py` |
| `sea_g2p.bin` | `4346e690...f4096` | [pnnbao97/sea-g2p](https://github.com/pnnbao97/sea-g2p) (source), PyPI package `sea-g2p` bundles the dictionary as package data | Medium — not byte-verified |
| `VieNeuOfflineV2/vieneu-tts-v2-turbo.gguf` | `b405b506...afb65a` | [pnnbao-ump/VieNeu-TTS-v2](https://huggingface.co/pnnbao-ump/VieNeu-TTS-v2) (HF) ships a gguf, but at a different quantization/size than this file | Low — not confirmed, size mismatch |
| `VieNeuOfflineV2/vieneu_decoder_int8.onnx` | `0e99548f...178889` | Same VieNeu-TTS-v2 family | Low — not confirmed |
| `VieNeuOfflineV3/*` (backbone_shared.data, v3_heads.npz, moss_audio_tokenizer_*, acoustic_cached, prefill, decode_step) | see `git log` / ask author | [pnnbao-ump/VieNeu-TTS-v3-Turbo](https://huggingface.co/pnnbao-ump/VieNeu-TTS-v3-Turbo) (HF) — repo exists, exact file-for-file mapping not confirmed | Low — not confirmed |
| `BundledTranslation/en-vi/encoder.onnx`, `decoder_merged.onnx` | see below | Likely [Xenova/opus-mt-en-vi](https://huggingface.co/Xenova/opus-mt-en-vi) (ONNX export of Helsinki-NLP/opus-mt-en-vi), quantized variant — sizes are close but not exact | Medium — plausible, not byte-verified |

"Confidence" reflects whether the exact byte-identical file was ever
verified against the public source, not whether the app or origin project
is legitimate — all of these are real, working models currently bundled in
the app; only the paper trail back to a specific public upload is
incomplete for several of them.
