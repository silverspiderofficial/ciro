## Kiro v1.1.0 — Studio

- On-device image generation (stable-diffusion.cpp, SD-Turbo / SD 1.5 + TAESD), run in the isolated AI process with a free-RAM check.
- Ready-made post templates with Persian RTL text, exported as PNG.
- Video / Reels rendering with FFmpeg: Ken Burns scenes, transitions, animated text, burned-in subtitles, background music, offline narrator voice (Piper via sherpa-onnx).
- Foreground progress notification for long jobs, save to gallery, drafts with image and video previews.
- New agent tools: make_image_prompt, generate_image, edit_video.

arm64-v8a only, Android 8.0+. Image and voice models are optional downloads from Hugging Face inside the app.
