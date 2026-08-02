import processing.video.*;
import java.io.File;
import java.awt.Toolkit;
import java.awt.datatransfer.StringSelection;

// ---------- Fixed settings ----------
String videoFile  = "input.mp4";      // lives in the sketch's data folder
int    cellSize   = 10;               // pixel block -> one ASCII char
String outputDir  = "output_frames";  // PNG sequence goes here, inside the sketch folder

// ---------- UI-editable settings ----------
String ramp = " .:-=+*#%@";           // characters, sparsest (darkest) -> densest (brightest)
boolean invert = false;               // dark chars on light background

enum ColorMode { ORIGINAL, GRAYSCALE, MONOCHROME, GRADIENT }
ColorMode colorMode = ColorMode.ORIGINAL;

color monoColor     = color(0, 255, 0);
color gradientStart = color(20, 20, 90);
color gradientEnd   = color(255, 180, 40);

// ---------- Internals ----------
Movie video;
PFont font;
PGraphics asciiBuffer;
int cols, rows;

enum State { LOADING, PREVIEW, RENDERING, DONE }
State state = State.LOADING;

boolean previewCaptured = false;
boolean gridConfigured = false;
boolean gridPending = false;
boolean frameReady = false;
int renderFrameIndex = 0;
int totalFrames = 0;
int loadingEventCount = 0;
String ffmpegCommand = "";

int uiBarHeight = 240;

// ---------- UI layout (computed once in setup) ----------
float actionBtnX, actionBtnY, actionBtnW = 174, actionBtnH = 36;

float fieldX, fieldY, fieldW = 380, fieldH = 26;
boolean editingRamp = false;
int maxRampLen = 48;

String[] presetNames = {"Classic", "Minimal", "Detailed", "Binary"};
String[] presetRamps = {
  " .:-=+*#%@",
  " .*#",
  " .'`^,:;Il!i><~+_-?][}{1)(|/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$",
  " #"
};
float[] presetBtnX = new float[4];
float presetBtnY, presetBtnW = 82, presetBtnH = 26;

float invertBoxX, invertBoxY, invertBoxSize = 18;

String[] modeNames = {"Original", "Grayscale", "Mono", "Gradient"};
float[] modeTabX = new float[4];
float modeTabY, modeTabW = 110, modeTabH = 30;

float swatchY, swatchSize = 40;
float monoSwatchX;
float gradStartSwatchX, gradEndSwatchX;
int activeColorTarget = 0; // 0 = mono, 1 = gradient start, 2 = gradient end

float sliderX, sliderYBase, sliderW = 260, sliderH = 14, sliderGap = 26;
char draggingChannel = ' ';

float gradPreviewX, gradPreviewY, gradPreviewW = 220, gradPreviewH = 40;

void setup() {
  size(1280, 840); // placeholder height; corrected once the video's real aspect ratio is known
  pixelDensity(1);

  font = createFont("Courier New Bold", cellSize, true);

  // Placeholder grid so there's something to draw before the video loads.
  cols = width / cellSize;
  rows = (height - uiBarHeight) / cellSize;
  asciiBuffer = createGraphics(cols * cellSize, rows * cellSize);

  layoutUI();
  background(0);

  // Start the video last: movieEvent() can fire on a background thread
  // as soon as play() is called, so everything it touches must exist first.
  video = new Movie(this, videoFile);
  video.play();
}

// Resizes the grid (and the window) to match the source video's true aspect
// ratio, so square-ish cells don't stretch/squash the picture. Called once,
// as soon as the video reports real pixel dimensions.
void configureGridForVideo() {
  float videoAspect = float(video.width) / float(video.height);

  cols = width / cellSize; // keep the window width fixed
  rows = max(1, round(cols / videoAspect));

  int maxWindowHeight = 1400;
  if (uiBarHeight + rows * cellSize > maxWindowHeight) {
    rows = max(1, (maxWindowHeight - uiBarHeight) / cellSize);
  }

  asciiBuffer = createGraphics(cols * cellSize, rows * cellSize);

  int newWindowHeight = uiBarHeight + rows * cellSize;
  if (newWindowHeight != height) {
    surface.setSize(width, newWindowHeight);
  }

  gridConfigured = true;
}

void layoutUI() {
  int rowY0 = 0,  rowH0 = 56;
  int rowY1 = rowY0 + rowH0,  rowH1 = 54;
  int rowY2 = rowY1 + rowH1,  rowH2 = 40;
  int rowY3 = rowY2 + rowH2;

  actionBtnX = width - 190;
  actionBtnY = rowY0 + 10;

  fieldX = 96;
  fieldY = rowY1 + 14;

  float px = fieldX + fieldW + 20;
  for (int i = 0; i < presetBtnX.length; i++) {
    presetBtnX[i] = px;
    px += presetBtnW + 8;
  }
  presetBtnY = rowY1 + 14;

  invertBoxX = px + 16;
  invertBoxY = rowY1 + 14;

  for (int i = 0; i < modeTabX.length; i++) {
    modeTabX[i] = 16 + i * (modeTabW + 8);
  }
  modeTabY = rowY2 + 5;

  swatchY = rowY3 + 15;
  monoSwatchX = 16;
  gradStartSwatchX = 16;
  gradEndSwatchX = 16 + swatchSize + 10;

  sliderX = 130;
  sliderYBase = rowY3 + 12;

  gradPreviewX = sliderX + sliderW + 60;
  gradPreviewY = rowY3;
}

// movieEvent() fires on a background GStreamer thread. It must stay
// featherweight: no graphics calls (createGraphics, PGraphics drawing) and
// no file I/O — those need Processing's main thread, and calling them here
// has repeatedly caused hangs/crashes. This callback only reads the new
// frame's pixels and flags state; draw() does all the real work.
void movieEvent(Movie m) {
  m.read();

  if (state == State.LOADING) {
    loadingEventCount++;
    boolean dimsKnown = video.width > 0 && video.height > 0;
    if (dimsKnown && !gridConfigured && !gridPending) gridPending = true;

    if (dimsKnown && gridConfigured) {
      if (video.duration() > 0) {
        state = State.PREVIEW;
        video.jump(video.duration() / 2.0);
      } else if (loadingEventCount > 10) {
        // Duration never became available for this file; preview whatever frame we have.
        state = State.PREVIEW;
        frameReady = true;
      }
    }
    return;
  }

  if (state == State.PREVIEW || state == State.RENDERING) {
    frameReady = true;
  }
}

void draw() {
  if (gridPending) {
    configureGridForVideo(); // safe here: this runs on the main animation thread
    gridPending = false;
  }

  if (state == State.PREVIEW && !previewCaptured && frameReady) {
    frameReady = false;
    previewCaptured = true;
    renderAsciiFrame(asciiBuffer);
    video.pause();
  }

  if (state == State.RENDERING && frameReady) {
    frameReady = false;
    renderAsciiFrame(asciiBuffer);
    saveCurrentFrame(renderFrameIndex);
    renderFrameIndex++;

    if (video.time() >= video.duration() - (1.0 / 60.0)) {
      totalFrames = renderFrameIndex;
      state = State.DONE;
      video.pause();

      float fps = totalFrames / video.duration();
      ffmpegCommand = "ffmpeg -framerate " + nf(fps, 1, 2) + " -i frame_%05d.png \\\n  -c:v libx264 -pix_fmt yuv420p -crf 18 ../output.mp4";
      copyToClipboard(ffmpegCommand);
      writeFfmpegScript(ffmpegCommand);

      println("Render complete: " + totalFrames + " frames written to " + sketchPath(outputDir));
      println("Command copied to clipboard, and saved to " + outputDir + "/render_video.sh:");
      println(ffmpegCommand);
    }
  }

  background(0);

  if (state == State.LOADING) {
    fill(255);
    textAlign(CENTER, CENTER);
    textSize(16);
    text("Loading video...", width / 2, uiBarHeight + (height - uiBarHeight) / 2);
  } else {
    image(asciiBuffer, 0, uiBarHeight);
  }

  drawUI();
}

// ---------- ASCII rendering ----------
void renderAsciiFrame(PGraphics pg) {
  video.loadPixels();
  if (video.pixels.length == 0) return;

  pg.beginDraw();
  pg.background(invert ? 255 : 0);
  pg.textFont(font);
  pg.textAlign(CENTER, CENTER);

  for (int y = 0; y < rows; y++) {
    for (int x = 0; x < cols; x++) {
      int vx = constrain(int(map(x, 0, cols, 0, video.width)), 0, video.width - 1);
      int vy = constrain(int(map(y, 0, rows, 0, video.height)), 0, video.height - 1);
      int idx = vy * video.width + vx;
      color c = video.pixels[idx];

      float b = brightness(c) / 255.0;
      int charIndex = int(b * (ramp.length() - 1));
      char ch = ramp.charAt(charIndex);

      pg.fill(pickColor(c, b));

      float px = x * cellSize + cellSize / 2.0;
      float py = y * cellSize + cellSize / 2.0;
      pg.text(ch, px, py);
    }
  }
  pg.endDraw();
}

color pickColor(color c, float b) {
  switch (colorMode) {
    case GRAYSCALE:
      int g = int(b * 255);
      return color(g);
    case MONOCHROME:
      return monoColor;
    case GRADIENT:
      return lerpColor(gradientStart, gradientEnd, b);
    default:
      return c; // ORIGINAL
  }
}

void refreshPreview() {
  if (state == State.PREVIEW && previewCaptured) renderAsciiFrame(asciiBuffer);
}

// ---------- Rendering the full video ----------
void startRender() {
  File outDir = new File(sketchPath(outputDir));
  if (!outDir.exists()) outDir.mkdirs();

  renderFrameIndex = 0;
  totalFrames = 0;
  frameReady = false;
  state = State.RENDERING;
  // Seek while playing, not paused: jumping on a paused GStreamer pipeline
  // can deadlock waiting for a preroll frame that never arrives.
  video.play();
  video.jump(0);
}

void saveCurrentFrame(int idx) {
  asciiBuffer.save(sketchPath(outputDir) + "/frame_" + nf(idx, 5) + ".png");
}

void copyToClipboard(String s) {
  StringSelection sel = new StringSelection(s);
  Toolkit.getDefaultToolkit().getSystemClipboard().setContents(sel, sel);
}

// Writes a ready-to-run script next to the frames, so the command is
// available as real, selectable text even outside the sketch window.
void writeFfmpegScript(String cmd) {
  String scriptPath = sketchPath(outputDir) + "/render_video.sh";
  saveStrings(scriptPath, new String[]{ "#!/bin/sh", "cd \"$(dirname \"$0\")\"", cmd });
  new File(scriptPath).setExecutable(true);
}

// ---------- UI drawing ----------
void drawUI() {
  noStroke();
  fill(30);
  rect(0, 0, width, uiBarHeight);

  drawRow0();
  drawRow1();
  drawRow2();
  drawRow3();
}

void drawRow0() {
  fill(255);
  textAlign(LEFT, CENTER);
  textSize(13);
  String status = "";
  if (state == State.LOADING) status = "Loading video...";
  else if (state == State.PREVIEW) status = "Preview (midpoint frame) — " + cols + "x" + rows + " cells";
  else if (state == State.RENDERING) {
    float pct = video.duration() > 0 ? video.time() / video.duration() : 0;
    status = "Rendering... frame " + renderFrameIndex + "  (" + timeString(video.time()) + " / " + timeString(video.duration()) + ", " + int(pct * 100) + "%)";
  } else if (state == State.DONE) status = "Done! " + totalFrames + " frames saved to /" + outputDir + " — ffmpeg command copied to clipboard";
  text(status, 16, 28);

  if (state == State.DONE) {
    fill(180);
    textSize(11);
    text("Also saved as " + outputDir + "/render_video.sh — open it in any editor to select/copy the command", 16, 44);
  }

  if (state == State.RENDERING) {
    float pct = video.duration() > 0 ? video.time() / video.duration() : 0;
    drawProgressBar(16, 40, width - 220, 8, pct);
  }

  String label;
  boolean enabled;
  if (state == State.LOADING) { label = "Loading..."; enabled = false; }
  else if (state == State.RENDERING) { label = "Cancel"; enabled = true; }
  else if (state == State.DONE) { label = "Render Again"; enabled = true; }
  else { label = "Render Full Video"; enabled = true; }
  drawButton(actionBtnX, actionBtnY, actionBtnW, actionBtnH, label, enabled);
}

void drawRow1() {
  fill(200);
  textAlign(LEFT, CENTER);
  textSize(12);
  text("Characters (dark -> light):", 16, fieldY + fieldH / 2);

  fill(editingRamp ? color(50, 50, 75) : color(45));
  rect(fieldX, fieldY, fieldW, fieldH, 4);
  if (editingRamp) {
    stroke(70, 130, 220);
    noFill();
    rect(fieldX, fieldY, fieldW, fieldH, 4);
    noStroke();
  }
  fill(255);
  textAlign(LEFT, CENTER);
  boolean showCursor = editingRamp && (frameCount / 30) % 2 == 0;
  text(ramp + (showCursor ? "|" : ""), fieldX + 8, fieldY + fieldH / 2);

  for (int i = 0; i < presetNames.length; i++) {
    boolean active = ramp.equals(presetRamps[i]);
    drawSmallButton(presetBtnX[i], presetBtnY, presetBtnW, presetBtnH, presetNames[i], active);
  }

  fill(45);
  rect(invertBoxX, invertBoxY, invertBoxSize, invertBoxSize, 3);
  if (invert) {
    fill(70, 130, 220);
    rect(invertBoxX + 3, invertBoxY + 3, invertBoxSize - 6, invertBoxSize - 6, 2);
  }
  fill(200);
  textAlign(LEFT, CENTER);
  text("Invert bg", invertBoxX + invertBoxSize + 8, invertBoxY + invertBoxSize / 2);
}

void drawRow2() {
  for (int i = 0; i < modeNames.length; i++) {
    boolean active = colorMode.ordinal() == i;
    drawSmallButton(modeTabX[i], modeTabY, modeTabW, modeTabH, modeNames[i], active);
  }
}

void drawRow3() {
  fill(180);
  textAlign(LEFT, CENTER);
  textSize(12);

  if (colorMode == ColorMode.ORIGINAL) {
    text("Colors are sampled directly from the video frame.", 16, sliderYBase + sliderGap);
    return;
  }
  if (colorMode == ColorMode.GRAYSCALE) {
    text("Brightness is mapped straight to grayscale.", 16, sliderYBase + sliderGap);
    return;
  }

  if (colorMode == ColorMode.MONOCHROME) {
    noStroke();
    fill(monoColor);
    rect(monoSwatchX, swatchY, swatchSize, swatchSize, 4);
  } else if (colorMode == ColorMode.GRADIENT) {
    noStroke();
    fill(gradientStart);
    rect(gradStartSwatchX, swatchY, swatchSize, swatchSize, 4);
    if (activeColorTarget == 1) {
      stroke(255);
      noFill();
      rect(gradStartSwatchX, swatchY, swatchSize, swatchSize, 4);
      noStroke();
    }

    fill(gradientEnd);
    rect(gradEndSwatchX, swatchY, swatchSize, swatchSize, 4);
    if (activeColorTarget == 2) {
      stroke(255);
      noFill();
      rect(gradEndSwatchX, swatchY, swatchSize, swatchSize, 4);
      noStroke();
    }

    for (int i = 0; i < int(gradPreviewW); i++) {
      float t = i / gradPreviewW;
      stroke(lerpColor(gradientStart, gradientEnd, t));
      line(gradPreviewX + i, gradPreviewY, gradPreviewX + i, gradPreviewY + gradPreviewH);
    }
    noStroke();
  }

  color cur = getActiveColor();
  drawSlider(sliderX, sliderYBase, sliderW, sliderH, int(red(cur)), "R");
  drawSlider(sliderX, sliderYBase + sliderGap, sliderW, sliderH, int(green(cur)), "G");
  drawSlider(sliderX, sliderYBase + sliderGap * 2, sliderW, sliderH, int(blue(cur)), "B");
}

void drawButton(float x, float y, float w, float h, String label, boolean enabled) {
  fill(enabled ? color(70, 130, 220) : color(80));
  rect(x, y, w, h, 6);
  fill(enabled ? 255 : 160);
  textAlign(CENTER, CENTER);
  textSize(13);
  text(label, x + w / 2, y + h / 2);
}

void drawSmallButton(float x, float y, float w, float h, String label, boolean active) {
  fill(active ? color(70, 130, 220) : color(55));
  rect(x, y, w, h, 5);
  fill(255);
  textAlign(CENTER, CENTER);
  textSize(11);
  text(label, x + w / 2, y + h / 2);
}

void drawProgressBar(float x, float y, float w, float h, float pct) {
  pct = constrain(pct, 0, 1);
  noStroke();
  fill(70);
  rect(x, y, w, h, 4);
  fill(70, 130, 220);
  rect(x, y, w * pct, h, 4);
}

String timeString(float seconds) {
  int mm = int(seconds) / 60;
  int ss = int(seconds) % 60;
  return nf(mm, 1) + ":" + nf(ss, 2);
}

void drawSlider(float x, float y, float w, float h, int value, String label) {
  fill(200);
  textAlign(RIGHT, CENTER);
  textSize(12);
  text(label, x - 12, y + h / 2);

  noStroke();
  fill(60);
  rect(x, y, w, h, h / 2);
  float hx = x + map(value, 0, 255, 0, w);
  fill(70, 130, 220);
  ellipse(hx, y + h / 2, h + 8, h + 8);

  fill(220);
  textAlign(LEFT, CENTER);
  text(value, x + w + 12, y + h / 2);
}

// ---------- Color target helpers ----------
color getActiveColor() {
  if (activeColorTarget == 1) return gradientStart;
  if (activeColorTarget == 2) return gradientEnd;
  return monoColor;
}

void setActiveColor(color c) {
  if (activeColorTarget == 1) gradientStart = c;
  else if (activeColorTarget == 2) gradientEnd = c;
  else monoColor = c;
}

// ---------- Mouse interaction ----------
boolean hit(float px, float py, float x, float y, float w, float h) {
  return px >= x && px <= x + w && py >= y && py <= y + h;
}

void mousePressed() {
  if (hit(mouseX, mouseY, actionBtnX, actionBtnY, actionBtnW, actionBtnH)) {
    if (state != State.LOADING) handleActionButton();
    return;
  }

  if (state == State.RENDERING) return; // settings locked while rendering

  boolean clickedField = hit(mouseX, mouseY, fieldX, fieldY, fieldW, fieldH);
  editingRamp = clickedField;
  if (clickedField) return;

  for (int i = 0; i < presetNames.length; i++) {
    if (hit(mouseX, mouseY, presetBtnX[i], presetBtnY, presetBtnW, presetBtnH)) {
      ramp = presetRamps[i];
      refreshPreview();
      return;
    }
  }

  if (hit(mouseX, mouseY, invertBoxX, invertBoxY, invertBoxSize, invertBoxSize)) {
    invert = !invert;
    refreshPreview();
    return;
  }

  for (int i = 0; i < modeNames.length; i++) {
    if (hit(mouseX, mouseY, modeTabX[i], modeTabY, modeTabW, modeTabH)) {
      colorMode = ColorMode.values()[i];
      if (colorMode == ColorMode.MONOCHROME) activeColorTarget = 0;
      else if (colorMode == ColorMode.GRADIENT && activeColorTarget == 0) activeColorTarget = 1;
      refreshPreview();
      return;
    }
  }

  if (colorMode == ColorMode.GRADIENT) {
    if (hit(mouseX, mouseY, gradStartSwatchX, swatchY, swatchSize, swatchSize)) {
      activeColorTarget = 1;
      return;
    }
    if (hit(mouseX, mouseY, gradEndSwatchX, swatchY, swatchSize, swatchSize)) {
      activeColorTarget = 2;
      return;
    }
  }

  if (colorMode == ColorMode.MONOCHROME || colorMode == ColorMode.GRADIENT) {
    checkSliderPress('R', sliderYBase);
    checkSliderPress('G', sliderYBase + sliderGap);
    checkSliderPress('B', sliderYBase + sliderGap * 2);
  }
}

void checkSliderPress(char channel, float y) {
  if (mouseX >= sliderX - 10 && mouseX <= sliderX + sliderW + 10 &&
      mouseY >= y - 10 && mouseY <= y + sliderH + 10) {
    draggingChannel = channel;
    updateChannelFromMouse(channel);
  }
}

void mouseDragged() {
  if (draggingChannel != ' ') updateChannelFromMouse(draggingChannel);
}

void mouseReleased() {
  draggingChannel = ' ';
}

void updateChannelFromMouse(char channel) {
  int value = int(constrain(map(mouseX, sliderX, sliderX + sliderW, 0, 255), 0, 255));
  color cur = getActiveColor();
  int r = int(red(cur)), g = int(green(cur)), b = int(blue(cur));
  if (channel == 'R') r = value;
  else if (channel == 'G') g = value;
  else if (channel == 'B') b = value;
  setActiveColor(color(r, g, b));
  refreshPreview();
}

void handleActionButton() {
  if (state == State.PREVIEW) {
    startRender();
  } else if (state == State.RENDERING) {
    // The movie is still playing at this point; jump while playing (not
    // paused) to avoid a GStreamer deadlock. draw() will pause it once
    // the seeked frame is captured.
    state = State.PREVIEW;
    previewCaptured = false;
    frameReady = false;
    video.jump(video.duration() / 2.0);
  } else if (state == State.DONE) {
    startRender();
  }
}

// ---------- Keyboard ----------
void keyPressed() {
  if (editingRamp) {
    if (key == BACKSPACE) {
      if (ramp.length() > 1) ramp = ramp.substring(0, ramp.length() - 1);
    } else if (key == ENTER || key == RETURN) {
      editingRamp = false;
    } else if (key == ESC) {
      editingRamp = false;
      key = 0; // prevent Processing's default "ESC closes the sketch"
    } else if (key >= 32 && key < 127 && ramp.length() < maxRampLen) {
      ramp += key;
    }
    refreshPreview();
    return;
  }

  if (key == 's') {
    asciiBuffer.save("ascii_frame-" + nf(frameCount, 4) + ".png");
  }
}
