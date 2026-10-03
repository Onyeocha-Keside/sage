// Sage landing page: scales the Mac screenshot, plays the follow-along
// demo on a loop, and sends waitlist signups to the Sage Worker.

const WAITLIST_ENDPOINT = "https://sage-api.sage-api.workers.dev/waitlist";

const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// ---------- Sticky header border once scrolled ----------
const siteHeader = document.querySelector(".site-header");
const updateHeaderBorder = () => siteHeader.classList.toggle("is-scrolled", window.scrollY > 8);
window.addEventListener("scroll", updateHeaderBorder, { passive: true });
updateHeaderBorder();

// ---------- Apple logo in the fake menu bar ----------
// The logo is a character only Apple's own fonts contain. Elsewhere it would
// show as an empty box, so non-Mac visitors just see the app name first.
if (!/Mac|iPhone|iPad/.test(navigator.userAgent)) {
  document.getElementById("menubar-apple")?.remove();
}

// ---------- Scale the 1280×800 Mac screen to fit its frame ----------
const MAC_SCREEN_WIDTH = 1280;
const macStage = document.getElementById("mac-stage");
const macScreen = document.getElementById("mac-screen");

function fitMacScreenToStage() {
  const isPhoneView = window.matchMedia("(max-width: 600px)").matches;
  const viewWidth = isPhoneView ? 420 : MAC_SCREEN_WIDTH;
  macScreen.style.setProperty("--mac-scale", macStage.clientWidth / viewWidth);
  macScreen.style.left = "0px";
  macScreen.style.top = "0px";
}
new ResizeObserver(fitMacScreenToStage).observe(macStage);
fitMacScreenToStage();

// ---------- Demo helpers ----------
const userCursor = document.getElementById("user-cursor");
const clickRipple = document.getElementById("click-ripple");
const sageCursor = document.getElementById("sage-cursor");
const sageBubble = document.getElementById("sage-bubble");
const demoCaption = document.getElementById("demo-caption");
const formatValue = document.getElementById("format-value");
const formatMenu = document.getElementById("format-menu");
const formatButton = macScreen.querySelector('[data-target="format"]');
const exportButton = macScreen.querySelector('[data-target="export"]');
const sageMenuIcon = macScreen.querySelector('[data-target="sage-menu-icon"]');
const shareButton = macScreen.querySelector('[data-target="share"]');
const downloadOption = macScreen.querySelector('[data-target="download-option"]');
const sharePanel = document.getElementById("share-panel");
const downloadPanel = document.getElementById("download-panel");
const macNotification = document.getElementById("mac-notification");

/** Sage sits a little below-right of the user's pointer, like in the real app. */
const SAGE_OFFSET_FROM_POINTER = { x: 26, y: 22 };

let userPointerPosition = { x: 640, y: 430 };
let isSageFollowingPointer = true;

let isDemoPaused = false;
let demoGeneration = 0;
let activeGeneration = 0;
let isSoundEnabled = false;
const narrationAudio = new Audio();
narrationAudio.preload = "auto";
const narrationClips = new Map([
  ["I'm Sage. Let's download your poster together.", "welcome"],
  ["First, open Share in the top right.", "share"],
  ["Choose Download, right here.", "download"],
  ["Change the format to PNG, right here.", "format"],
  ["Now click Download.", "finish"],
  ["Done. It's in your downloads folder.", "done"],
  ["Now click Download. I'll point out each step, then wait for you.", "still"],
  ["Let's find the overdue invoices in Excel.", "excel-welcome"],
  ["Open the filter on the Status column.", "excel-status"],
  ["Clear Select All, so we can choose one status.", "excel-clear"],
  ["Now select Overdue.", "excel-overdue"],
  ["Click Apply Filter to show only those invoices.", "excel-apply"],
  ["There are three overdue invoices. The other rows are hidden, not deleted.", "excel-done"],
]);
let narrationGeneration = 0;
function stopNarration() {
  narrationGeneration += 1;
  narrationAudio.pause();
  narrationAudio.currentTime = 0;
}
const pauseButton = document.getElementById("demo-pause");
const replayButton = document.getElementById("demo-replay");
const soundButton = document.getElementById("demo-sound");
const demoNote = document.getElementById("demo-note");

// Count only playing time. Replays cancel the previous sequence at its next tick.
async function sleep(milliseconds) {
  const generationAtStart = activeGeneration;
  let remainingMilliseconds = milliseconds;
  while (remainingMilliseconds > 0) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    if (generationAtStart !== demoGeneration) throw new Error("Demo restarted");
    if (!isDemoPaused && !document.hidden) remainingMilliseconds -= 50;
  }
}

function updatePauseState() {
  macScreen.classList.toggle("is-paused", isDemoPaused || document.hidden);
  pauseButton.textContent = isDemoPaused ? "Resume demo" : "Pause demo";
  pauseButton.setAttribute("aria-pressed", String(isDemoPaused));
  if (isDemoPaused || document.hidden) narrationAudio.pause();
  else if (isSoundEnabled && narrationAudio.currentTime > 0 && !narrationAudio.ended) {
    playNarrationAudio();
  }
}
pauseButton.addEventListener("click", () => {
  isDemoPaused = !isDemoPaused;
  updatePauseState();
});
replayButton.addEventListener("click", () => {
  demoGeneration += 1;
  isDemoPaused = false;
  stopNarration();
  updatePauseState();
  if (prefersReducedMotion) currentDemo === "excel" ? showStillExcelFrame() : showStillDemoFrame();
});
soundButton.addEventListener("click", () => {
  isSoundEnabled = !isSoundEnabled;
  soundButton.setAttribute("aria-pressed", String(isSoundEnabled));
  soundButton.textContent = isSoundEnabled ? "Mute sound" : "Play with sound";
  demoNote.textContent = isSoundEnabled
    ? "Illustrated demo · Mac voice narration is on."
    : "Illustrated demo · Sound is off. Sage points; you make every click.";
  stopNarration();
  if (isSoundEnabled) {
    if (!prefersReducedMotion) replayButton.click();
    // Speak from the button gesture so browsers can activate audio immediately.
    speakDemoLine(currentDemo === "excel" ? "Let's find the overdue invoices in Excel." : prefersReducedMotion
      ? "Now click Download. I'll point out each step, then wait for you."
      : "I'm Sage. Let's download your poster together.");
  }
});
document.addEventListener("visibilitychange", updatePauseState);

function playNarrationAudio() {
  const generationAtStart = narrationGeneration;
  narrationAudio.play().catch(() => {
    if (generationAtStart !== narrationGeneration || !isSoundEnabled) return;
    isSoundEnabled = false;
    soundButton.setAttribute("aria-pressed", "false");
    soundButton.textContent = "Play with sound";
    demoNote.textContent = "Audio couldn’t play. Click Play with sound to try again.";
  });
}

function speakDemoLine(text) {
  if (!isSoundEnabled) return;
  const normalizedText = text.replace(/[“”]/g, "").trim().toLowerCase();
  const clip = [...narrationClips].find(([line]) => line.toLowerCase() === normalizedText)?.[1];
  if (!clip) return;
  stopNarration();
  narrationAudio.src = `assets/voice/${clip}.wav`;
  playNarrationAudio();
}

const dockIcons = [...macScreen.querySelectorAll(".dock-icon")];
function resetDockMagnification() {
  macScreen.classList.remove("is-touring-dock");
  dockIcons.forEach((icon) => {
    icon.style.removeProperty("--dock-scale");
    icon.style.removeProperty("--dock-lift");
    icon.classList.remove("is-demo-hovered");
  });
}

async function passThroughDock() {
  // A short incidental pass, without opening any apps or changing the task.
  const tourIcons = dockIcons.slice(7, 11);
  const iconPositions = dockIcons.map((icon) => centerOf(icon));
  const firstPosition = iconPositions[7];
  const lastPosition = iconPositions[10];
  moveUserPointerTo(firstPosition);
  await sleep(900);
  macScreen.classList.add("is-touring-dock");
  try {
    for (let frameIndex = 0; frameIndex <= 36; frameIndex += 1) {
      const progress = frameIndex / 36;
      const pointerPosition = {
        x: firstPosition.x + (lastPosition.x - firstPosition.x) * progress,
        y: firstPosition.y,
      };
      moveUserPointerTo(pointerPosition);
      dockIcons.forEach((icon, iconIndex) => {
        const distance = Math.abs(pointerPosition.x - iconPositions[iconIndex].x);
        const influence = Math.max(0, 1 - distance / 90);
        icon.style.setProperty("--dock-scale", 1 + influence * 0.35);
        icon.style.setProperty("--dock-lift", `${-influence * 9}px`);
        icon.classList.toggle("is-demo-hovered", distance < 22 && tourIcons.includes(icon));
      });
      await sleep(50);
    }
  } finally {
    resetDockMagnification();
  }
}


/** Center of an element, in the Mac screen's own 1280×800 coordinates. */
function centerOf(element) {
  const elementBounds = element.getBoundingClientRect();
  const screenBounds = macScreen.getBoundingClientRect();
  const screenScale = screenBounds.width / macScreen.offsetWidth;
  return {
    x: (elementBounds.left + elementBounds.width / 2 - screenBounds.left) / screenScale,
    y: (elementBounds.top + elementBounds.height / 2 - screenBounds.top) / screenScale,
  };
}

function setPosition(element, position) {
  element.style.setProperty("--x", `${position.x}px`);
  element.style.setProperty("--y", `${position.y}px`);
}

function moveSageTo(position) {
  const boundedPosition = {
    x: Math.max(12, Math.min(position.x, macScreen.offsetWidth - 12)),
    y: Math.max(12, Math.min(position.y, macScreen.offsetHeight - 12)),
  };
  setPosition(sageCursor, boundedPosition);
  // Put labels above their targets, away from the next worksheet row.
  const bubbleWidth = sageBubble.offsetWidth || 120;
  setPosition(sageBubble, {
    x: Math.max(8, Math.min(boundedPosition.x - bubbleWidth / 2, macScreen.offsetWidth - bubbleWidth - 8)),
    y: Math.max(8, boundedPosition.y - 44),
  });
}

function moveUserPointerTo(position) {
  if (window.matchMedia("(max-width: 600px)").matches) {
    position = { x: Math.min(position.x, 380), y: Math.min(position.y, 535) };
  }
  userPointerPosition = position;
  // The arrow's tip is a few pixels into its graphic.
  setPosition(userCursor, { x: position.x - 4, y: position.y - 2 });
  if (isSageFollowingPointer) {
    moveSageTo({ x: position.x + SAGE_OFFSET_FROM_POINTER.x, y: position.y + SAGE_OFFSET_FROM_POINTER.y });
  }
}

function setSageMode(mode) {
  sageCursor.dataset.mode = mode;
}

/** Flies Sage to just below-right of an element so its tip points at it,
 *  then shows the label once it lands (like the real app). */
async function pointSageAt(element, label) {
  isSageFollowingPointer = false;
  hideSageBubble();
  const target = centerOf(element);
  moveSageTo({ x: target.x + 6, y: target.y + 8 });
  await sleep(850);
  sageBubble.textContent = label;
  moveSageTo({ x: target.x + 6, y: target.y + 8 });
  sageBubble.classList.add("is-visible");
}

function hideSageBubble() {
  sageBubble.classList.remove("is-visible");
}

async function clickAt(element) {
  moveUserPointerTo(centerOf(element));
  await sleep(900);
  setPosition(clickRipple, userPointerPosition);
  clickRipple.classList.remove("is-clicking");
  void clickRipple.offsetWidth; // restart the animation
  clickRipple.classList.add("is-clicking");
}

function setCaption(speaker, text) {
  demoCaption.style.opacity = "0";
  const speakerClass = speaker === "Sage" ? "caption-speaker is-sage" : "caption-speaker";
  demoCaption.innerHTML = `<span class="${speakerClass}">${speaker}</span> ${text}`;
  demoCaption.style.opacity = "1";
  if (isSoundEnabled && speaker === "Sage" && !text.includes("<em>")) {
    speakDemoLine(demoCaption.textContent.replace(/^Sage\s*/, ""));
  }
}

function resetDemoScene() {
  showApplication(currentDemo);
  resetExcelDemo();
  resetDockMagnification();
  sharePanel.classList.remove("is-open");
  downloadPanel.classList.remove("is-open");
  shareButton.classList.remove("is-pressed");
  formatValue.textContent = "JPG";
  formatMenu.classList.remove("is-open");
  formatMenu.querySelectorAll("li").forEach((item) => item.classList.remove("is-highlighted"));
  formatButton.classList.remove("is-pressed");
  exportButton.classList.remove("is-pressed");
  macNotification.classList.remove("is-visible");
  sageMenuIcon.classList.remove("is-active");
  hideSageBubble();
  isSageFollowingPointer = true;
  setSageMode("following");
  moveUserPointerTo({ x: 840, y: 420 });
}

// ---------- The demo script: one follow-along run ----------
async function playFollowAlongDemo() {
  resetDemoScene();
  await sleep(900);

  // 1. The user holds control + option and asks.
  sageMenuIcon.classList.add("is-active");
  setSageMode("listening");
  setCaption("You", "“how do I export this as a PNG?”");
  await sleep(2600);

  // 2. Sage thinks.
  setSageMode("thinking");
  await sleep(1200);

  // Follow Canva’s actual export path; every click belongs to the user.
  setSageMode("pointing");
  setCaption("Sage", "“first, open Share in the top right.”");
  await pointSageAt(shareButton, "share");
  await sleep(1100);
  setSageMode("watching");
  await clickAt(shareButton);
  hideSageBubble();
  shareButton.classList.add("is-pressed");
  sharePanel.classList.add("is-open");
  await sleep(900);
  setSageMode("pointing");
  setCaption("Sage", "“choose Download, right here.”");
  await pointSageAt(downloadOption, "download");
  await sleep(1100);
  setSageMode("watching");
  await clickAt(downloadOption);
  hideSageBubble();
  sharePanel.classList.remove("is-open");
  downloadPanel.classList.add("is-open");
  await sleep(900);

  // 3. Step one: Sage points at the format menu, then watches.
  setSageMode("pointing");
  setCaption("Sage", "“change the format to png, right here.”");
  await pointSageAt(formatButton, "format");
  await sleep(1100);
  setSageMode("watching");
  await sleep(600);

  // 4. The user opens the menu and picks PNG.
  await clickAt(formatButton);
  formatButton.classList.add("is-pressed");
  formatMenu.classList.add("is-open");
  hideSageBubble();
  await sleep(700);
  const pngMenuItem = formatMenu.querySelector('[data-target="format-png"]');
  pngMenuItem.classList.add("is-highlighted");
  await clickAt(pngMenuItem);
  await sleep(250);
  formatMenu.classList.remove("is-open");
  formatButton.classList.remove("is-pressed");
  formatValue.textContent = "PNG";

  // 5. Sage notices the change and looks again.
  setCaption("Sage", "<em>sees the new screen…</em>");
  setSageMode("thinking");
  await sleep(1100);

  // 6. Step two: the export button.
  setSageMode("pointing");
  setCaption("Sage", "“now click Download.”");
  await pointSageAt(exportButton, "download");
  await sleep(900);
  setSageMode("watching");
  await clickAt(exportButton);
  exportButton.classList.add("is-pressed");
  await sleep(160);
  exportButton.classList.remove("is-pressed");
  hideSageBubble();
  await sleep(500);
  downloadPanel.classList.remove("is-open");
  shareButton.classList.remove("is-pressed");
  macNotification.classList.add("is-visible");

  // 7. Done. Sage flies home to the pointer.
  setSageMode("following");
  setCaption("Sage", "“done. it's in your downloads folder.”");
  isSageFollowingPointer = true;
  sageMenuIcon.classList.remove("is-active");
  await sleep(900);
  await passThroughDock();
  moveUserPointerTo({ x: 700, y: 470 });
  await sleep(1200);
}

/** For visitors who prefer less motion: a single still frame of the demo. */
function showStillDemoFrame() {
  resetDemoScene();
  downloadPanel.classList.add("is-open");
  formatValue.textContent = "PNG";
  moveUserPointerTo({ x: 700, y: 470 });
  isSageFollowingPointer = false;
  setSageMode("pointing");
  const exportPosition = centerOf(exportButton);
  moveSageTo({ x: exportPosition.x + 10, y: exportPosition.y + 12 });
  sageBubble.textContent = "download";
  sageBubble.classList.add("is-visible");
  setCaption("Sage", "“now click Download.” Sage points at each step, then waits for you.");
}

async function runDemoForever() {
  // Give fonts time to load without letting a slow font request stall the demo.
  await Promise.race([
    document.fonts.ready,
    new Promise((resolve) => setTimeout(resolve, 1500)),
  ]);
  if (prefersReducedMotion) {
    pauseButton.disabled = true;
    currentDemo === "excel" ? showStillExcelFrame() : showStillDemoFrame();
    return;
  }
  while (true) {
    activeGeneration = demoGeneration;
    try {
      if (currentDemo === "excel") await playExcelDemo();
      else await playFollowAlongDemo();
      await sleep(1800);
      await switchApplicationThroughDock(currentDemo === "canva" ? "excel" : "canva");
    } catch (error) {
      if (activeGeneration === demoGeneration) throw error;
    }
  }
}
runDemoForever();

// ---------- Waitlist ----------
const waitlistForm = document.getElementById("waitlist");
const formNote = document.getElementById("form-note");
const submitButton = waitlistForm.querySelector('button[type="submit"]');

function showFormNote(message, state) {
  formNote.textContent = message;
  formNote.classList.toggle("is-success", state === "success");
  formNote.classList.toggle("is-error", state === "error");
}

waitlistForm.addEventListener("submit", async (submitEvent) => {
  submitEvent.preventDefault();
  const formData = new FormData(waitlistForm);
  const emailAddress = String(formData.get("email") || "").trim();

  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(emailAddress)) {
    showFormNote("That email doesn't look quite right.", "error");
    waitlistForm.querySelector('input[type="email"]').focus();
    return;
  }

  submitButton.disabled = true;
  submitButton.textContent = "Joining…";

  const requestController = new AbortController();
  const requestTimeout = setTimeout(() => requestController.abort(), 12000);
  try {
    const response = await fetch(WAITLIST_ENDPOINT, {
      signal: requestController.signal,
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        email: emailAddress,
        platform: formData.get("platform"),
        website: formData.get("website"), // honeypot, empty for people
      }),
    });
    if (response.status === 429) throw new Error("rate-limit");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    waitlistForm.reset();
    const isWindows = formData.get("platform") === "windows";
    showFormNote(
      isWindows ? "You're on the list. We'll tell you when Sage comes to Windows." : "You're on the list. We'll email you when your invite is ready.",
      "success"
    );
  } catch (error) {
    const message = error.name === "AbortError"
      ? "The request took too long. Please try again."
      : error.message === "rate-limit"
        ? "Too many attempts from this connection. Please try again in a minute."
        : "We couldn’t join the waitlist. Check your connection and try again.";
    showFormNote(message, "error");
  } finally {
    clearTimeout(requestTimeout);
    submitButton.disabled = false;
    submitButton.textContent = "Get early access";
  }
});
