// Second illustrated walkthrough. Shared cursor, playback, and audio live in script.js.
let currentDemo = "canva";
const excelWindow = document.getElementById("excel-window");
const canvaWindow = document.querySelector(".canva-window");
const excelFilterPanel = document.getElementById("excel-filter-panel");
const excelStatusArrow = document.querySelector('[data-target="excel-status"]');
const excelSelectAll = document.querySelector('[data-target="excel-select-all"]');
const excelOverdue = document.querySelector('[data-target="excel-overdue"]');
const excelApply = document.querySelector('[data-target="excel-apply"]');
const demoScenarioButtons = [...document.querySelectorAll("[data-demo]")];
const safariMenuMarkup = document.querySelector(".menubar-left").innerHTML;

function showApplication(application) {
  currentDemo = application;
  canvaWindow.hidden = application !== "canva";
  excelWindow.hidden = application !== "excel";
  macScreen.dataset.application = application;
  document.querySelector(".menubar-left").innerHTML = application === "canva" ? safariMenuMarkup
    : '<span class="menubar-apple"></span><strong>Excel</strong><span>File</span><span>Edit</span><span>View</span><span>Insert</span><span>Format</span><span>Tools</span><span>Data</span><span>Window</span><span>Help</span>';
  if (!/Mac|iPhone|iPad/.test(navigator.userAgent)) document.querySelector(".menubar-apple")?.remove();
  demoScenarioButtons.forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.demo === application)));
  fitMacScreenToStage();
}

function resetExcelDemo() {
  excelFilterPanel.hidden = true;
  excelFilterPanel.querySelectorAll(".excel-checkbox").forEach((checkbox) => checkbox.classList.add("is-checked"));
  excelWindow.querySelectorAll(".excel-data-row").forEach((row) => { row.hidden = false; });
  document.getElementById("excel-statusbar-message").textContent = "Ready";
  excelStatusArrow.textContent = "⌄";
}

function applyOverdueFilter() {
  excelWindow.querySelectorAll(".excel-data-row").forEach((row) => { row.hidden = row.dataset.status !== "Overdue"; });
  excelFilterPanel.hidden = true;
  excelStatusArrow.textContent = "▽";
  document.getElementById("excel-statusbar-message").textContent = "3 of 8 records found";
}

async function switchApplicationThroughDock(application) {
  hideSageBubble();
  stopNarration();
  setSageMode("following");
  isSageFollowingPointer = true;
  // Briefly reveal the whole desktop on phones so the app switch stays visible.
  macScreen.dataset.application = "desktop";
  fitMacScreenToStage();
  const dockApplication = application === "excel"
    ? document.querySelector('[data-target="excel-dock"]')
    : document.querySelector('.dock-icon[data-app-name="Safari"]');
  dockApplication.classList.add("is-demo-hovered");
  try {
    await clickAt(dockApplication);
    await sleep(350);
    dockApplication.classList.add("is-running");
    showApplication(application);
    moveUserPointerTo(application === "excel" ? { x: 820, y: 320 } : { x: 840, y: 420 });
    await sleep(600);
  } finally {
    dockApplication.classList.remove("is-demo-hovered");
    if (macScreen.dataset.application === "desktop") showApplication(currentDemo);
  }
}

async function guideExcelClick(element, text, label) {
  setSageMode("pointing");
  setCaption("Sage", text);
  await pointSageAt(element, label);
  await sleep(1300);
  setSageMode("watching");
  await clickAt(element);
  hideSageBubble();
}

async function playExcelDemo() {
  resetDemoScene();
  await sleep(900);
  sageMenuIcon.classList.add("is-active");
  setSageMode("listening");
  setCaption("You", "“show me just the overdue invoices.”");
  await sleep(2500);
  setSageMode("thinking");
  await sleep(1100);
  await guideExcelClick(excelStatusArrow, "“open the filter on the Status column.”", "status filter");
  excelFilterPanel.hidden = false;
  await sleep(600);
  await guideExcelClick(excelSelectAll, "“clear Select All, so we can choose one status.”", "select all");
  excelFilterPanel.querySelectorAll(".excel-checkbox").forEach((checkbox) => checkbox.classList.remove("is-checked"));
  await sleep(500);
  await guideExcelClick(excelOverdue, "“now select Overdue.”", "overdue");
  excelOverdue.querySelector(".excel-checkbox").classList.add("is-checked");
  await sleep(500);
  await guideExcelClick(excelApply, "“click Apply Filter to show only those invoices.”", "apply filter");
  applyOverdueFilter();
  setSageMode("following");
  isSageFollowingPointer = true;
  moveUserPointerTo({ x: 820, y: 370 });
  sageMenuIcon.classList.remove("is-active");
  setCaption("Sage", "“there are three overdue invoices. The other rows are hidden, not deleted.”");
  await sleep(5300);
}

function showStillExcelFrame() {
  resetDemoScene();
  applyOverdueFilter();
  setCaption("Sage", "Three overdue invoices. Sage guides the filter, and you make the clicks.");
  const target = centerOf(excelStatusArrow);
  isSageFollowingPointer = false;
  setSageMode("pointing");
  moveSageTo({ x: target.x + 10, y: target.y + 12 });
}

demoScenarioButtons.forEach((button) => button.addEventListener("click", () => {
  stopNarration();
  showApplication(button.dataset.demo);
  replayButton.click();
}));
