# Demo video

`demo.mp4` — 2:11, 1080p, narrated. Rendered from `video.html` by `build.mjs`: narration is synthesised
with Piper, then the page is captured frame by frame by seeking its timeline, so text stays crisp and
audio never drifts.

Edit the words in `narration.json` and the visuals in `video.html`, then re-render:

```bash
python3 -m pip install piper-tts
PIPER_MODEL=/path/to/en_US-ryan-high.onnx node demo-video/build.mjs
```

Needs `ffmpeg` and a Chromium for Playwright (`CHROMIUM_PATH`, `PLAYWRIGHT_MODULE` if not default).

The screenshots in `assets/` are real captures of the running app and of HashScan. The
`ActionExecuted` card is labelled as structure only — at the time of recording the live registry had no
agents, so the video does not show a real transaction. After running `yarn foundry:demo` with a funded
key, capture `/agents/1` and swap it into the receipt scene to show a real one.
