// Unique AV Countdown — main process.
// Owns the timer engine, windows, menus, phone/OSC remote and update checks.
const {
  app, BrowserWindow, ipcMain, protocol, net, screen, Menu, dialog, shell, session,
  powerSaveBlocker, desktopCapturer, systemPreferences,
} = require('electron');
const path = require('path');
const fs = require('fs');
const { pathToFileURL } = require('url');
const { TimerEngine } = require('./engine');
const { OSCServer } = require('./osc');
const { WebRemoteServer, localIPv4 } = require('./web-remote');
const updater = require('./updater');

const IS_MAC = process.platform === 'darwin';
const SMOKE = process.env.UAV_SMOKE_TEST === '1';
const RENDERER_DIR = path.join(__dirname, '..', 'renderer');

protocol.registerSchemesAsPrivileged([
  { scheme: 'app', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, corsEnabled: true } },
]);

const gotLock = SMOKE || app.requestSingleInstanceLock();
if (!gotLock) app.quit();
// Warning beeps play without needing a click first.
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

// ---------------------------------------------------------------- state

const STATE_FILE = () => path.join(app.getPath('userData'), 'state.json');
let saved = {};
let engine;
let operator = null;
let presenter = null;
let placedKey = '';
let saveTimer = null;
let updateStatus = 'Not checked yet';
const web = new WebRemoteServer({
  state: () => engine.remoteState(),
  command: (c, v) => engine.perform(c, v, 'Web'),
});
const osc = new OSCServer((c, v) => engine.perform(c, v, 'OSC'));

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE(), 'utf8'));
  } catch {
    return {};
  }
}

function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveNow, 400);
}

function saveNow() {
  clearTimeout(saveTimer);
  try {
    fs.mkdirSync(path.dirname(STATE_FILE()), { recursive: true });
    const data = { segments: engine.segments, settings: engine.settings, skippedVersion: saved.skippedVersion || '' };
    fs.writeFileSync(STATE_FILE() + '.tmp', JSON.stringify(data, null, 2));
    fs.renameSync(STATE_FILE() + '.tmp', STATE_FILE());
  } catch (e) {
    console.error('Could not save state', e);
  }
}

function applyServices() {
  const s = engine.settings;
  if (s.webEnabled) {
    if (web.port !== s.webPort) web.start(s.webPort);
  } else if (web.port !== null) web.stop();
  if (s.oscEnabled) {
    if (osc.port !== s.oscPort) osc.start(s.oscPort);
  } else if (osc.port !== null) osc.stop();
}

function send(channel, ...args) {
  if (operator && !operator.isDestroyed()) operator.webContents.send(channel, ...args);
}

// ---------------------------------------------------------------- displays & presenter window

function displayList() {
  const primary = screen.getPrimaryDisplay();
  return screen.getAllDisplays().map((d, i) => {
    const name = d.label || (d.internal ? 'Built-in display' : `Display ${i + 1}`);
    return {
      id: d.id,
      name: `${name} — ${d.size.width}×${d.size.height}${d.id === primary.id ? ' (main)' : ''}`,
      primary: d.id === primary.id,
    };
  });
}

function targetDisplay() {
  const all = screen.getAllDisplays();
  const primary = screen.getPrimaryDisplay();
  return all.find((d) => d.id === engine.settings.presenterDisplayId)
    || all.find((d) => d.id !== primary.id)
    || primary;
}

/** Puts the presenter window full screen on the chosen display (or a window if there's only one screen). */
function placePresenter() {
  if (!presenter || presenter.isDestroyed()) return { windowed: true, open: false };
  const d = targetDisplay();
  const windowed = screen.getAllDisplays().length < 2 || d.id === screen.getPrimaryDisplay().id;
  const key = `${d.id}|${windowed}|${JSON.stringify(d.bounds)}`;
  if (key === placedKey && presenter.isVisible()) return { windowed, open: true };
  placedKey = key;

  if (IS_MAC) presenter.setSimpleFullScreen(false);
  else presenter.setFullScreen(false);

  if (windowed) {
    const wa = d.workArea;
    const w = Math.min(960, wa.width), h = Math.round(w * 9 / 16);
    presenter.setAlwaysOnTop(true, 'floating');
    presenter.setResizable(true);
    presenter.setBounds({ x: Math.round(wa.x + (wa.width - w) / 2), y: Math.round(wa.y + (wa.height - h) / 2), width: w, height: h });
    presenter.setAspectRatio(16 / 9);
  } else {
    presenter.setAspectRatio(0);
    presenter.setBounds(d.bounds);
    presenter.setAlwaysOnTop(true, 'screen-saver');
    if (IS_MAC) presenter.setSimpleFullScreen(true);
    else presenter.setFullScreen(true);
  }
  if (!presenter.isVisible()) presenter.showInactive();
  return { windowed, open: true };
}

// ---------------------------------------------------------------- operator window

function createOperator() {
  operator = new BrowserWindow({
    width: 1320,
    height: 860,
    minWidth: 1040,
    minHeight: 680,
    title: 'Unique AV Countdown',
    backgroundColor: '#111317',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: false, // keep the presenter screen ticking when this window is hidden
    },
  });

  operator.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('app://ui/presenter.html')) {
      return {
        action: 'allow',
        overrideBrowserWindowOptions: {
          show: false,
          frame: false,
          title: 'Presenter',
          backgroundColor: '#000000',
          autoHideMenuBar: true,
          fullscreenable: true,
          skipTaskbar: false,
          webPreferences: { backgroundThrottling: false, contextIsolation: true, nodeIntegration: false },
        },
      };
    }
    if (/^https?:/i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });

  operator.webContents.on('did-create-window', (win) => {
    presenter = win;
    placedKey = '';
    if (!IS_MAC) win.setMenu(null);
    win.once('ready-to-show', () => placePresenter());
    win.on('closed', () => {
      presenter = null;
      placedKey = '';
      send('presenter:closed');
    });
  });

  operator.on('ready-to-show', () => { if (!SMOKE) operator.show(); });
  operator.on('closed', () => {
    operator = null;
    if (presenter && !presenter.isDestroyed()) presenter.close();
  });
  operator.loadURL('app://ui/operator.html');
}

// ---------------------------------------------------------------- menu

function buildMenu() {
  const cmd = (c, a) => () => engine.perform(c, a);
  const ui = (what) => () => send('menu', what);
  const fileItems = [
    { label: 'New Rundown', accelerator: 'CmdOrCtrl+N', click: newRundown },
    { label: 'Open Rundown…', accelerator: 'CmdOrCtrl+O', click: openRundown },
    { type: 'separator' },
    { label: 'Save Rundown As…', accelerator: 'CmdOrCtrl+S', click: saveRundown },
  ];
  if (!IS_MAC) {
    fileItems.push(
      { type: 'separator' },
      { label: 'Settings…', accelerator: 'Ctrl+,', click: ui('settings') },
      { label: 'Check for Updates…', click: () => checkForUpdates(true) },
      { type: 'separator' },
      { role: 'quit', label: 'Exit' },
    );
  }
  const template = [
    ...(IS_MAC ? [{
      label: app.name,
      submenu: [
        { role: 'about' },
        { label: 'Check for Updates…', click: () => checkForUpdates(true) },
        { type: 'separator' },
        { label: 'Settings…', accelerator: 'Cmd+,', click: ui('settings') },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    }] : []),
    { label: 'File', submenu: fileItems },
    { role: 'editMenu' },
    {
      label: 'Timer',
      submenu: [
        { label: 'Start / Pause', accelerator: 'CmdOrCtrl+Enter', click: cmd('toggle') },
        { label: 'Reset Segment', accelerator: 'CmdOrCtrl+R', click: cmd('reset') },
        { type: 'separator' },
        { label: 'Next Segment  (→)', click: cmd('next') },
        { label: 'Previous Segment  (←)', click: cmd('prev') },
        { type: 'separator' },
        { label: 'Add 1 Minute', accelerator: 'CmdOrCtrl+=', click: cmd('add', 60) },
        { label: 'Remove 1 Minute', accelerator: 'CmdOrCtrl+-', click: cmd('sub', 60) },
        { type: 'separator' },
        { label: 'Flash Message', accelerator: 'CmdOrCtrl+Shift+F', click: cmd('flash') },
        { label: 'Hide Message', accelerator: 'CmdOrCtrl+Shift+H', click: cmd('message-hide') },
        { label: 'Toggle Blackout', accelerator: 'CmdOrCtrl+Shift+B', click: cmd('blackout') },
        { type: 'separator' },
        { label: 'Video PIP On / Off', accelerator: 'CmdOrCtrl+Shift+V', click: cmd('video') },
        { label: 'Next Video Layout', accelerator: 'CmdOrCtrl+Shift+L', click: cmd('layout') },
        { type: 'separator' },
        { label: 'Show / Hide Presenter Screen', accelerator: 'CmdOrCtrl+Shift+D', click: ui('toggle-presenter') },
      ],
    },
    {
      label: 'View',
      submenu: [
        { role: 'togglefullscreen' },
        { type: 'separator' },
        { role: 'toggleDevTools' },
      ],
    },
    { role: 'windowMenu' },
    {
      role: 'help',
      submenu: [
        { label: 'User Guide (README)', click: () => shell.openExternal(`https://github.com/${updater.REPO}#readme`) },
        { label: 'Releases', click: () => shell.openExternal(`https://github.com/${updater.REPO}/releases`) },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---------------------------------------------------------------- rundown files

async function newRundown() {
  const { response } = await dialog.showMessageBox(operator, {
    type: 'question',
    buttons: ['New Rundown', 'Cancel'],
    defaultId: 0,
    cancelId: 1,
    message: 'Start a new rundown?',
    detail: 'The current rundown will be replaced. Save it first if you need it.',
  });
  if (response === 0) engine.newRundown();
}

async function openRundown() {
  const r = await dialog.showOpenDialog(operator, {
    title: 'Open Rundown',
    filters: [{ name: 'Rundown', extensions: ['json'] }],
    properties: ['openFile'],
  });
  if (r.canceled || !r.filePaths[0]) return;
  try {
    engine.loadRundown(JSON.parse(fs.readFileSync(r.filePaths[0], 'utf8')));
  } catch (e) {
    dialog.showErrorBox("Couldn't open rundown", e.message);
  }
}

async function saveRundown() {
  const r = await dialog.showSaveDialog(operator, {
    title: 'Save Rundown',
    defaultPath: 'Rundown.json',
    filters: [{ name: 'Rundown', extensions: ['json'] }],
  });
  if (r.canceled || !r.filePath) return;
  try {
    fs.writeFileSync(r.filePath, JSON.stringify(engine.rundownFile(), null, 2));
  } catch (e) {
    dialog.showErrorBox("Couldn't save rundown", e.message);
  }
}

// ---------------------------------------------------------------- updates

async function checkForUpdates(userInitiated) {
  const current = app.getVersion();
  const info = (message, detail) => dialog.showMessageBox(operator, { type: 'info', message, detail, buttons: ['OK'] });
  let r;
  try {
    r = await updater.fetchLatest(current);
  } catch (e) {
    updateStatus = `Update check failed: ${e.message}`;
    if (userInitiated) info("Couldn't check for updates", e.message);
    return;
  }
  if (r.status === 'none') {
    updateStatus = 'No releases published yet';
    if (userInitiated) info('No updates found', 'No releases have been published yet.');
    return;
  }
  if (r.status !== 'ok') {
    updateStatus = `Update check failed (${r.message})`;
    if (userInitiated) info("Couldn't check for updates", r.message);
    return;
  }
  const t = new Date();
  updateStatus = `Checked ${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')} — latest is ${r.version}`;
  if (!updater.isNewer(r.version, current)) {
    if (userInitiated) info("You're up to date", `Unique AV Countdown ${current} is the latest version.`);
    return;
  }
  if (!userInitiated && r.version === saved.skippedVersion) return;

  let notes = r.notes;
  if (notes.length > 700) notes = notes.slice(0, 700) + '…';
  const how = IS_MAC
    ? 'To install: quit this app, open the downloaded DMG and drag the app onto Applications (choose Replace).'
    : 'To install: quit this app and run the downloaded Setup file. It replaces the installed version.';
  const { response } = await dialog.showMessageBox(operator, {
    type: 'info',
    buttons: ['Download', 'Later', 'Skip This Version'],
    defaultId: 0,
    cancelId: 1,
    message: `Unique AV Countdown ${r.version} is available`,
    detail: `You have version ${current}.${notes ? `\n\nWhat's new:\n${notes}` : ''}\n\n${how}`,
  });
  if (response === 0) {
    const asset = updater.pickAsset(r.assets, process.platform);
    shell.openExternal(asset ? asset.url : r.page);
  } else if (response === 2) {
    saved.skippedVersion = r.version;
    saveNow();
  }
}

// ---------------------------------------------------------------- IPC

function registerIPC() {
  ipcMain.handle('app:info', () => ({ version: app.getVersion(), platform: process.platform }));
  ipcMain.handle('config:get', () => engine.getConfig());
  ipcMain.handle('cmd', (_e, c, a, source) => engine.perform(c, a, source || ''));
  ipcMain.handle('settings:update', (_e, patch) => engine.updateSettings(patch));
  ipcMain.handle('segment:update', (_e, id, patch) => engine.updateSegment(id, patch));
  ipcMain.handle('segment:add', (_e, afterId) => engine.addSegment(afterId));
  ipcMain.handle('segment:duplicate', (_e, id) => engine.duplicateSegment(id));
  ipcMain.handle('segment:delete', (_e, id) => engine.deleteSegment(id));
  ipcMain.handle('segment:move', (_e, id, to) => engine.moveSegment(id, to));
  ipcMain.handle('segment:goto', (_e, id, autostart) => engine.goTo(id, !!autostart));
  ipcMain.handle('quick', (_e, seconds) => engine.quickTimer(Number(seconds)));
  ipcMain.handle('rundown:new', newRundown);
  ipcMain.handle('rundown:open', openRundown);
  ipcMain.handle('rundown:save', saveRundown);

  ipcMain.handle('displays:get', () => ({ displays: displayList(), selected: targetDisplay().id }));
  ipcMain.handle('presenter:place', () => placePresenter());
  ipcMain.handle('presenter:setDisplay', (_e, id) => {
    engine.updateSettings({ presenterDisplayId: id });
    return placePresenter();
  });

  ipcMain.handle('remote:info', () => ({
    web: web.status,
    osc: osc.status,
    urls: engine.settings.webEnabled ? localIPv4().map((ip) => `http://${ip}:${engine.settings.webPort}`) : [],
  }));

  ipcMain.handle('video:desktopSources', async () => {
    try {
      const sources = await desktopCapturer.getSources({
        types: ['screen', 'window'],
        thumbnailSize: { width: 0, height: 0 },
        fetchWindowIcons: false,
      });
      const ownTitles = new Set(BrowserWindow.getAllWindows().map((w) => w.getTitle()));
      return sources
        .filter((s) => !(s.id.startsWith('window') && ownTitles.has(s.name)))
        .map((s) => ({ id: s.id, name: s.name, kind: s.id.startsWith('screen') ? 'screen' : 'window' }));
    } catch (e) {
      return [];
    }
  });
  ipcMain.handle('video:screenAccess', () => (IS_MAC ? systemPreferences.getMediaAccessStatus('screen') : 'granted'));
  ipcMain.handle('video:openScreenSettings', () => {
    if (IS_MAC) shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture');
  });
  ipcMain.handle('video:askCamera', async () => {
    if (!IS_MAC) return true;
    if (systemPreferences.getMediaAccessStatus('camera') === 'granted') return true;
    return systemPreferences.askForMediaAccess('camera');
  });

  ipcMain.handle('updates:check', () => checkForUpdates(true));
  ipcMain.handle('updates:status', () => updateStatus);
  ipcMain.handle('open:external', (_e, url) => { if (/^https?:/i.test(url)) shell.openExternal(url); });
}

// ---------------------------------------------------------------- smoke test (CI)

function runSmokeTest() {
  const dir = process.env.UAV_SMOKE_DIR || path.join(process.cwd(), 'smoke');
  fs.mkdirSync(dir, { recursive: true });
  const problems = [];
  const watch = (wc, name) => {
    wc.on('console-message', (event, level, message, line, sourceId) => {
      const lvl = event && event.level !== undefined ? event.level : level;
      const msg = event && event.message !== undefined ? event.message : message;
      const where = event && event.sourceId !== undefined ? `${event.sourceId}:${event.lineNumber}` : `${sourceId}:${line}`;
      const text = `[${name}] ${msg} (${where})`;
      fs.appendFileSync(path.join(dir, 'console.log'), text + '\n');
      if (lvl === 3 || lvl === 'error') problems.push(text);
    });
    wc.on('render-process-gone', (_e, d) => problems.push(`[${name}] renderer gone: ${d.reason}`));
    wc.on('preload-error', (_e, p, err) => problems.push(`[${name}] preload error: ${err.message}`));
  };
  watch(operator.webContents, 'operator');
  operator.webContents.on('did-create-window', (win) => watch(win.webContents, 'presenter'));
  operator.setSize(1400, 900);
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const shot = async (win, file) => {
    if (!win || win.isDestroyed()) { problems.push(`missing window for ${file}`); return; }
    const img = await win.webContents.capturePage();
    fs.writeFileSync(path.join(dir, file), img.toPNG());
  };
  operator.webContents.once('did-finish-load', async () => {
    try {
      operator.show();
      await wait(2500);
      await shot(operator, '1-operator.png');
      send('menu', 'toggle-presenter');
      engine.start();
      await wait(2500);
      await shot(presenter, '2-presenter-timer.png');
      engine.perform('message', 'Please wrap up');
      engine.updateSettings({ videoLayout: 'videoPIP' });
      await wait(1200);
      await shot(presenter, '3-presenter-message.png');
      await shot(operator, '4-operator-running.png');
      send('menu', 'settings');
      await wait(800);
      await shot(operator, '5-settings.png');
    } catch (e) {
      problems.push(`smoke error: ${e.stack}`);
    }
    fs.writeFileSync(path.join(dir, 'result.txt'), problems.length ? problems.join('\n') : 'OK');
    console.log(problems.length ? `SMOKE TEST PROBLEMS:\n${problems.join('\n')}` : 'SMOKE TEST OK');
    app.exit(problems.length ? 1 : 0);
  });
}

// ---------------------------------------------------------------- startup

app.whenReady().then(() => {
  if (!gotLock) return;
  protocol.handle('app', (req) => {
    const u = new URL(req.url);
    let p = decodeURIComponent(u.pathname);
    if (p === '/' || p === '') p = '/operator.html';
    const file = path.normalize(path.join(RENDERER_DIR, p));
    if (!file.startsWith(RENDERER_DIR)) return new Response('Forbidden', { status: 403 });
    return net.fetch(pathToFileURL(file).toString());
  });

  const allowed = new Set(['media', 'midi', 'midiSysex', 'display-capture']);
  session.defaultSession.setPermissionRequestHandler((_wc, permission, callback) => callback(allowed.has(permission)));
  session.defaultSession.setPermissionCheckHandler((_wc, permission) => allowed.has(permission));

  saved = SMOKE ? {} : loadState();
  engine = new TimerEngine(saved);
  engine.on('config', () => {
    send('config', engine.getConfig());
    applyServices();
    if (!SMOKE) scheduleSave();
  });
  engine.on('sound', (kind) => send('sound', kind));
  setInterval(() => {
    engine.tick();
    send('tick', engine.snapshot());
  }, 100);

  registerIPC();
  buildMenu();
  applyServices();
  createOperator();

  const onDisplays = () => {
    if (presenter) placePresenter();
    send('displays:changed');
  };
  screen.on('display-added', onDisplays);
  screen.on('display-removed', onDisplays);
  screen.on('display-metrics-changed', onDisplays);

  powerSaveBlocker.start('prevent-display-sleep');

  if (SMOKE) runSmokeTest();
  else if (engine.settings.checkUpdatesOnLaunch) setTimeout(() => checkForUpdates(false), 4000);
});

app.on('second-instance', () => {
  if (operator) {
    if (operator.isMinimized()) operator.restore();
    operator.focus();
  }
});

app.on('window-all-closed', () => app.quit());
app.on('before-quit', () => {
  if (engine && !SMOKE) saveNow();
  web.stop();
  osc.stop();
});
