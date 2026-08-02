# processing-video-to-ascii

A [Processing](https://processing.org/) sketch that converts a video into ASCII art, frame by frame. It shows a live preview with an in-app control panel for tweaking the character ramp, colors, and inversion, then renders the whole video to a folder of PNG frames plus a ready-to-run `ffmpeg` command for stitching them back into a video.

## Requirements

- [Processing](https://processing.org/download) (desktop IDE)
- The **Video** library (Sketch → Import Library → Add Library → search "Video", by The Processing Foundation)
- `ffmpeg` installed and on your `PATH` if you want to reassemble the rendered frames into a video file

## Setup

1. Open `ASCII_Portfolio_Deck_Video_Maker.pde` in the Processing IDE.
2. Place your source video in the sketch's `data/` folder and name it `input.mp4` (or edit the `videoFile` variable at the top of the file to point elsewhere).
3. Run the sketch (▶).

## Usage

When the sketch starts it loads `input.mp4` and jumps to the frame at the video's midpoint to use as a live preview. A control panel across the top of the window lets you adjust the look before committing to a full render:

- **Characters (dark → light)** — the text field holds the "ramp": a string of characters ordered from sparsest/darkest to densest/brightest. Click the field to edit it directly, or click one of the **Classic / Minimal / Detailed / Binary** presets. Press `Enter` or `Esc` to stop editing.
- **Invert bg** — swaps a black background for a white one (and vice versa).
- **Original / Grayscale / Mono / Gradient** tabs — choose how each ASCII character is colored:
  - *Original*: sampled directly from the video's pixel color.
  - *Grayscale*: colored by brightness only.
  - *Mono*: a single solid color (click the swatch, then drag the R/G/B sliders).
  - *Gradient*: interpolates between two colors based on brightness (click either swatch to select it, then adjust with the sliders).
- **Render Full Video** — starts rendering every frame of the video as ASCII art. While rendering, the button becomes **Cancel** (returns you to the preview) and a progress bar shows how far along it is. Settings are locked during rendering.
- Press `s` at any time to save a snapshot of the current preview frame as a PNG in the sketch folder.

### Output

Rendered frames are written as `frame_00000.png`, `frame_00001.png`, … inside `output_frames/` (next to the sketch). When rendering finishes, the sketch:

- Computes the correct output frame rate from the video's duration and frame count.
- Copies a ready-to-use `ffmpeg` command to your clipboard.
- Writes that same command to `output_frames/render_video.sh` (marked executable) so you can run it directly:

  ```sh
  cd output_frames
  ./render_video.sh
  ```

  This encodes the PNG sequence into `output.mp4` one directory above `output_frames/`.

## How the core functions work

- **`setup()`** — creates the window, builds a placeholder ASCII grid (so there's something to draw before the video loads), lays out the UI, then starts loading the video. The video is started *last* because its background thread can start firing events immediately.
- **`movieEvent(Movie m)`** — called by Processing's Video library on a background thread whenever a new video frame is decoded. It only reads the frame and sets flags (`frameReady`, state transitions) — it deliberately avoids graphics or file operations, since those require the main thread and have caused hangs when called from here directly.
- **`draw()`** — the main loop, running ~60 times per second on the main thread. It checks the flags set by `movieEvent()` and does the actual work: configuring the grid to match the video's aspect ratio once dimensions are known, capturing the preview frame, or — while rendering — converting a frame to ASCII and saving it to disk. It also draws the ASCII buffer and the UI on every call.
- **`configureGridForVideo()`** — once the video reports its real width/height, this computes how many character columns/rows fit the window at the fixed `cellSize`, resizes the offscreen buffer (`asciiBuffer`) to match, and resizes the window so the aspect ratio isn't stretched.
- **`renderAsciiFrame(PGraphics pg)`** — the heart of the conversion. For every cell in the grid, it samples the corresponding pixel from the video frame, maps that pixel's brightness to an index into the `ramp` string to pick a character, chooses a color via `pickColor()`, and draws the character into the offscreen buffer.
- **`pickColor(color c, float b)`** — given a sampled pixel color `c` and its brightness `b` (0–1), returns the color to actually draw, depending on the selected `colorMode` (original pixel color, grayscale, a fixed mono color, or a two-color gradient interpolated by brightness).
- **`startRender()` / `saveCurrentFrame(int idx)`** — `startRender()` resets render state and seeks the video back to the start (seeking while the video is *playing*, not paused, avoids a deadlock in the underlying GStreamer pipeline). Each subsequent `draw()` call then converts and saves one frame via `saveCurrentFrame()`, until the video reaches its end.
- **`writeFfmpegScript(String cmd)`** — writes the generated `ffmpeg` command out as an executable shell script alongside the rendered frames, so it's available as selectable text even outside the sketch window.
- **UI drawing (`drawUI()`, `drawRow0()`–`drawRow3()`, `drawButton()`, `drawSlider()`, etc.)** — pure drawing functions that render the top control bar based on current state (ramp text, active presets, color mode tabs, swatches, sliders, progress bar).
- **Input handling (`mousePressed()`, `mouseDragged()`, `mouseReleased()`, `keyPressed()`)** — hit-tests mouse clicks against the UI element positions computed in `layoutUI()`, and updates the corresponding setting (ramp, invert, color mode, active color, slider values) or starts/cancels a render.
