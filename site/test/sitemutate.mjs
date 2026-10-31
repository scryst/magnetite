// Proves each check in sitecheck.mjs still rejects the regression it names.
//
// Each mutation breaks one thing in a temporary copy of site/ (plus the three
// repository files the checks read) and runs only the check that should catch
// it. A mutation that check passes, or that no longer applies because its target
// text moved, fails this harness, and so does a check with no mutation at all.
// The real tree is never written.
//
//   node site/test/sitemutate.mjs

import { cpSync, mkdtempSync, readFileSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const site = join(here, '..');
const repo = join(site, '..');
const check = join(here, 'sitecheck.mjs');

// The release-tied cases read the pinned release from install.sh and the size
// from the page, so a version bump does not leave them aiming at text that moved.
const installer = readFileSync(join(repo, 'install.sh'), 'utf8');
const VERSION = installer.match(/^PIN_VERSION="([^"]+)"/m)[1];
const PIN = installer.match(/^PIN_SHA256="([0-9a-f]{4})/m)[1];
const OTHER_PIN = (PIN[0] === 'f' ? '0' : 'f') + PIN.slice(1);
const [major, minor, patch] = VERSION.split('.').map(Number);
const OLDER = patch > 0 ? `${major}.${minor}.${patch - 1}` : `${major}.${minor - 1}.0`;
const KB = readFileSync(join(site, 'index.html'), 'utf8').match(/Free and open source, (\d+) KB\./)[1];
const ZIP = `releases/download/v${VERSION}/Magnetite-${VERSION}.zip`;

// [check, what breaks, file (relative to the copy's root), from, to]
// The copy's root holds site/ and the three repository files the checks read.
const MUTATIONS = [
  ['floor', 'the page offers an older release', 'site/index.html', `"softwareVersion": "${VERSION}"`, `"softwareVersion": "${OLDER}"`],
  ['floor', 'the app is a version behind the pin', 'Resources/Info.plist', `<string>${VERSION}</string>`, `<string>${OLDER}</string>`],
  ['floor', 'llms.txt offers an older release', 'site/llms.txt', `Magnetite v${VERSION}`, `Magnetite v${OLDER}`],
  ['download', 'a button links the releases page, not the zip', 'site/index.html', `href="https://github.com/scryst/magnetite-releases/${ZIP}"\n             aria-describedby="hero-requires"`, 'href="https://github.com/scryst/magnetite-releases/releases"\n             aria-describedby="hero-requires"'],
  ['download', 'the size is from an older build', 'site/index.html', `Free and open source, ${KB} KB.`, `Free and open source, ${Number(KB) + 2} KB.`],
  ['download', 'install.sh pins other bytes', 'install.sh', `PIN_SHA256="${PIN}`, `PIN_SHA256="${OTHER_PIN}`],
  ['requires', 'a download button lost its requirement', 'site/index.html', '\n         aria-describedby="requires"', ''],
  ['requires', 'the requirement drops Apple silicon', 'site/index.html', 'Needs macOS 26 on Apple silicon (', 'Needs macOS 26 ('],
  ['crawlable', 'structured data stops parsing', 'site/index.html', '"isAccessibleForFree": true,', '"isAccessibleForFree": true,,'],
  ['crawlable', 'the screenshot points at a deleted file', 'site/index.html', 'media/demo-poster.webp",', 'media/desktop.webp",'],
  ['policies', 'the footer drops Privacy', 'site/index.html', '<a href="privacy.html">Privacy</a>', ''],
  ['type', 'the headline falls back to the old face', 'site/css/magnetite.css', "--display: 'Geist'", "--display: 'Gloock'"],
  ['type', 'the font ships without its license', 'site/css/type.css', 'OFL: fonts/OFL-Geist.txt', 'OFL: fonts/OFL-Archivo.txt'],
  ['spelling', 'British spelling comes back', 'site/index.html', 'MIT license', 'MIT licence'], // us-spelling: ok
  ['spelling', 'the British visualizer comes back', 'site/llms.txt', 'visualizer', 'visualiser'], // us-spelling: ok
  ['gray', 'the screen keeps its color close up', 'site/css/magnetite.css', 'to { filter: grayscale(1); }', 'to { filter: grayscale(0.3); }'],
  ['gray', 'the screen grays only after the first gesture', 'site/css/magnetite.css', 'animation-range: contain 6% contain 30%;', 'animation-range: contain 6% contain 45%;'],
  ['deck', 'the grilles shrink back to a guess', 'site/css/magnetite.css', 'grid-template-columns: 4.4cqw 89.4cqw 4.4cqw', 'grid-template-columns: 2.4cqw 89.4cqw 2.4cqw'],
  ['deck', 'the trackpad is drawn wider than Apple makes it', 'site/css/magnetite.css', 'width: 41.4cqw; height: 25.9cqw;', 'width: 47.3cqw; height: 25.9cqw;'],
  ['accent', 'a colored flair comes back', 'site/css/magnetite.css', '  --bg: #000;\n', '  --bg: #000;\n  --pink: #FF4FA3;\n'],
  ['firstlaunch', 'the steps lose Open Anyway', 'site/index.html', 'click <b>Open Anyway</b>', 'click <b>Open</b>'],
  ['credit', 'a song loses its credit', 'site/index.html', '<a href="https://open.spotify.com/track/4zXZ5Mq2L6jnsOsTssgRh8" rel="external">“Hush” by The Marías</a>', 'Hush'],
  ['credit', 'credit names wrap', 'site/css/magnetite.css', '.demo__credit a { white-space: nowrap; }', ''],
  ['gray', 'the gray comes on partway down the journey', 'site/css/magnetite.css', 'from { filter: grayscale(0); }\n  ', ''],
  ['songs', 'the light goes back to page layers', 'site/index.html', '<canvas data-glow width="120" height="80"></canvas>', '<i data-for="sunsetz" class="on"></i>'],
  ['songs', 'the desktop is drawn bigger than its stills', 'site/index.html', '<canvas data-wall width="160" height="104">', '<canvas data-wall width="1600" height="1040">'],
  ['songs', 'the turning copies come back as layers', 'site/css/magnetite.css', '  --bg: #000;\n', '  --bg: #000;\n}\n@keyframes turn { to { rotate: 1turn; }\n'],
  ['songs', 'the song going fades out under the one coming', 'site/js/site.js', 'const layers = k < 1 ? [[went, 1], [shown, k]] : [[shown, 1]];', 'const layers = k < 1 ? [[went, 1 - k], [shown, k]] : [[shown, 1]];'],
  ['songs', 'the desktop keeps drawing off screen', 'site/js/site.js', 'if (onScreen && (lightDue || !still.matches)) drawing', 'if (lightDue || !still.matches) drawing'],
  ['songs', 'the light loses glow-mask.webp', 'site/js/site.js', "glow.globalCompositeOperation = 'destination-in'; glow.globalAlpha = 1; glow.drawImage(art.mask, 0, 0, 120, 80);", ''],
  ['songs', 'a tour glow loses its falloff', 'site/css/magnetite.css', '  -webkit-mask: url(../media/glow-mask.webp) 0 0 / 100% 100% no-repeat;\n  mask: url(../media/glow-mask.webp) 0 0 / 100% 100% no-repeat;\n}\n.shot__media--pop', '}\n.shot__media--pop'],
  ['flicker', 'the blur comes on partway down the journey', 'site/css/magnetite.css', 'from { filter: blur(0); }\n  ', ''],
  ['flicker', 'the screen goes back in the lid\'s plane', 'site/css/magnetite.css', "behind the lid's black for a frame. */\n  transform: translateZ(1px);\n", "behind the lid's black for a frame. */\n"],
  ['flicker', 'the deck is not softened', 'site/css/magnetite.css', 'animation: fade linear both, soften linear both, gone linear both;', 'animation: fade linear both, gone linear both;'],
  ['compositor', 'the words hide in the same keyframe that fades them', 'site/css/magnetite.css', '  to { opacity: 0; transform: translateY(-24px); }', '  to { opacity: 0; transform: translateY(-24px); visibility: hidden; }'],
  ['compositor', 'the lid\'s rim fades by its box-shadow', 'site/css/magnetite.css', '@keyframes fade {\n  to { opacity: 0; }', '@keyframes fade {\n  to { opacity: 0; box-shadow: none; }'],
  ['compositor', 'the headline fades and returns in two animations', 'site/css/magnetite.css', 'animation: pitch linear both, gone linear both', 'animation: pitch linear both, lift linear forwards, gone linear both'],
  ['compositor', 'the eye goes back on the pin', 'site/css/magnetite.css', '    .journey__pin {\n      position: sticky;', '    .journey__pin {\n      perspective: var(--p);\n      position: sticky;'],
  ['flicker', 'the softening starts too late to hold', 'site/css/magnetite.css', 'contain 6% contain 22%', 'contain 10% contain 22%'],
  ['flicker', 'the deck is blurred too little', 'site/css/magnetite.css', 'to { filter: blur(3px); }', 'to { filter: blur(2px); }'],
  ['scale', 'the film is placed at twice its size', 'site/css/magnetite.css', 'left: 36.772%; width: 26.455%;', 'left: 23.545%; width: 52.91%;'],
  ['scale', 'the camera stops at the lid\'s own size', 'site/css/magnetite.css', '--zoom: 2;', '--zoom: 1;'],
  ['moves', 'two gestures share the screen', 'site/css/magnetite.css', 'contain 60% contain 82%', 'contain 57% contain 82%'],
  ['dock', 'the dock counts a faded button', 'site/js/site.js', 'opacityProperty: true, ', ''],
  ['name', 'the wordmark leaves the top of the page', 'site/index.html', '<a class="brand" href="#top">', '<a class="brandless" href="#top">'],
  ['name', 'the dock forgets the name', 'site/index.html', '>Get Magnetite</a></div>', '>Get it</a></div>'],
  ['name', 'a legal page loses its way home', 'site/privacy.html', 'alt="" width="22" height="22">Magnetite</a>', 'alt="" width="22" height="22">Home</a>'],
  ['mark', 'the inline glyph is edited by hand', 'site/index.html', '<path fill="currentColor" d="M272.5 283C', '<path fill="currentColor" d="M272.5 284C'],
  ['mark', 'the symbol sheet takes room on the page', 'site/css/magnetite.css', '.defs { position: absolute; width: 0; height: 0;', '.defs { position: absolute;'],
  ['mark', 'the menu-bar icon is edited by hand', 'Sources/NotchApp/App/MagnetiteMark.swift', 'static let aspect: CGFloat = ', 'static let aspect: CGFloat = 1.0 * '],
  ['demo', 'the box is not the film size', 'site/index.html', 'width="800" height="512"', 'width="800" height="450"'],
  ['demo', 'the film can make sound by itself', 'site/index.html', 'data-demo muted loop', 'data-demo loop'],
  ['clips', 'a clip plays off screen and under Reduce Motion', 'site/index.html', 'data-clip muted loop playsinline preload="none" width="800"', 'data-clip muted loop playsinline autoplay preload="none" width="800"'],
  ['clips', 'the folded clip box is not its size', 'site/index.html', 'width="640" height="72"', 'width="640" height="80"'],
  ['clips', 'a clip names a description that is not on the page', 'site/index.html', 'aria-describedby="liquid-text liquid-more"', 'aria-describedby="liquid-text liquid-gone"'],
  ['script', 'a simulation script comes back', 'site/index.html', '<script type="module" src="js/site.js"></script>', '<script type="module" src="js/site.js"></script>\n<script type="module" src="js/sim.js"></script>'],
  ['script', 'site.js starts listening to audio', 'site/js/site.js', 'label();\n', 'label();\nnew AudioContext();\n'],
  ['links', 'a song still drawn from nowhere', 'site/js/site.js', 'load(`media/field-${song}.webp`)', 'load(`media/fields/${song}.webp`)'],
  ['links', 'a link into test/', 'site/index.html', '<a href="privacy.html">Privacy</a>', '<a href="test/og.html">Privacy</a> <a href="privacy.html">Privacy</a>'],
  ['links', 'an anchor no element carries', 'site/index.html', '<div class="dock" data-dock hidden><a class="button" href="#download">', '<div class="dock" data-dock hidden><a class="button" href="#get">'],
];

const checks = [...readFileSync(check, 'utf8').matchAll(/^  (?:async )?(\w+)\(\) \{$/gm)].map((m) => m[1]);
const results = [];
for (const name of checks) {
  if (!MUTATIONS.some((m) => m[0] === name)) results.push(`FAIL ${name}: no mutation covers it`);
}

for (const [name, what, file, from, to] of MUTATIONS) {
  const root = mkdtempSync(join(tmpdir(), 'sitemutate-'));
  try {
    cpSync(site, join(root, 'site'), { recursive: true });
    mkdirSync(join(root, 'Resources'));
    cpSync(join(repo, 'Resources/Info.plist'), join(root, 'Resources/Info.plist'));
    cpSync(join(repo, 'install.sh'), join(root, 'install.sh'));
    cpSync(join(repo, 'Sources/NotchApp/App/MagnetiteMark.swift'), join(root, 'Sources/NotchApp/App/MagnetiteMark.swift'));
    cpSync(join(repo, 'tools/notchtake.swift'), join(root, 'tools/notchtake.swift'));
    const path = join(root, file);
    const text = readFileSync(path, 'utf8');
    if (!text.includes(from)) { results.push(`FAIL ${name}: "${what}" no longer applies (target text not in ${file})`); continue; }
    writeFileSync(path, text.replace(from, to));
    const run = spawnSync(process.execPath, [check, `--only=${name}`, `--site=${join(root, 'site')}`, `--repo=${root}`], { encoding: 'utf8' });
    results.push(run.status === 1 ? `ok   ${name}: rejects ${what}` : `FAIL ${name}: passed with ${what}\n${run.stdout}${run.stderr}`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// The unmutated copy must pass every check, or the mutations prove nothing.
const clean = spawnSync(process.execPath, [check], { encoding: 'utf8' });
results.push(clean.status === 0 ? 'ok   baseline: the real tree passes' : `FAIL baseline\n${clean.stdout}`);

console.log(results.join('\n'));
process.exit(results.some((r) => r.startsWith('FAIL')) ? 1 : 0);
