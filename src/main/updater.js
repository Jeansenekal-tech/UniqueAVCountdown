// Checks the GitHub repo's latest release and offers to download a newer version.
// The repo must be public: the app checks without logging in.
const REPO = 'Jeansenekal-tech/UniqueAVCountdown';

function clean(tag) {
  let t = String(tag || '').trim();
  if (/^v/i.test(t)) t = t.slice(1);
  return t;
}

/** Compares "1.2.10"-style versions number by number. */
function isNewer(a, b) {
  const parts = (s) => String(s).split(/[^0-9]+/).filter(Boolean).map(Number);
  const x = parts(a), y = parts(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const l = x[i] || 0, r = y[i] || 0;
    if (l !== r) return l > r;
  }
  return false;
}

/** Picks the installer for this computer from a release's files. */
function pickAsset(assets, platform) {
  const by = (ext) => (assets || []).find((a) => a.name.toLowerCase().endsWith(ext));
  if (platform === 'darwin') return by('.dmg') || by('.zip');
  if (platform === 'win32') return by('.exe') || by('.msi') || by('.zip');
  return by('.appimage') || by('.zip');
}

async function fetchLatest(currentVersion) {
  const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
    headers: {
      Accept: 'application/vnd.github+json',
      'User-Agent': `UniqueAVCountdown/${currentVersion}`,
    },
    cache: 'no-store',
  });
  if (res.status === 404) return { status: 'none' };
  if (!res.ok) return { status: 'error', message: `HTTP ${res.status}` };
  const r = await res.json();
  return {
    status: 'ok',
    version: clean(r.tag_name),
    notes: (r.body || '').trim(),
    page: r.html_url,
    assets: (r.assets || []).map((a) => ({ name: a.name, url: a.browser_download_url })),
  };
}

module.exports = { REPO, clean, isNewer, pickAsset, fetchLatest };
