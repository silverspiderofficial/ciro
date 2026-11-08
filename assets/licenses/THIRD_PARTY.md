Kiro — third-party components used by the Studio (stage 2)

stable-diffusion.cpp (leejet) — MIT License — https://github.com/leejet/stable-diffusion.cpp
  Built from source at master-1056-9234ad8 (commit 9234ad822a376a4724638467736118ed61d68ee9),
  including its bundled ggml (MIT), Oniguruma (BSD-2-Clause) and utf8proc (MIT).

llama.cpp / ggml (ggml-org) — MIT License — https://github.com/ggml-org/llama.cpp

FFmpeg 8.1.3 — https://ffmpeg.org — built with --enable-gpl and libx264, therefore distributed
  under the GNU General Public License version 2 or later. Source: https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz
  (SHA-256 7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3); build script
  tool/ffmpeg/build_ffmpeg.sh in the Kiro repository.

x264 — GNU GPL version 2 or later — https://code.videolan.org/videolan/x264
  (stable branch, commit b35605ace3ddf7c1a5d67a2eb553f034aef41d55).

sherpa-onnx 1.13.8 (k2-fsa) — Apache License 2.0 — https://github.com/k2-fsa/sherpa-onnx
  Includes ONNX Runtime (MIT), piper-phonemize (MIT) and espeak-ng (GPL-3.0-or-later).

espeak-ng data (phontab, phonindex, phondata, intonations, fa_dict, en_dict, lang files) —
  GNU GPL version 3 or later — https://github.com/espeak-ng/espeak-ng (full text in
  assets/tts/espeak-ng-data.COPYING).

Piper voices (downloaded on demand, not bundled):
  fa_IR-amir-medium — dataset CC0 (datacula.com), fine-tuned from Piper's en_US lessac voice.
  en_US-joe-medium — dataset CC0 (NabuCasa voice-datasets), fine-tuned from en_US lessac.
  Piper: MIT — https://github.com/rhasspy/piper ; ONNX exports by k2-fsa (csukuangfj on Hugging Face).

Image models (downloaded on demand, not bundled):
  SD-Turbo (Stability AI) — Stability AI Community License — https://huggingface.co/stabilityai/sd-turbo
    GGUF conversion: Green-Sky/SD-Turbo-GGUF.
  Stable Diffusion v1.5 — CreativeML OpenRAIL-M — GGUF conversion: second-state/stable-diffusion-v1-5-GGUF.
  TAESD (madebyollin) — MIT License — https://github.com/madebyollin/taesd

Because FFmpeg/x264 (GPL-2.0+) and espeak-ng (GPL-3.0+) are included, a distributed build of
Kiro must make the corresponding source available to its recipients.
