const registrations = new WeakMap();

const annotations = Object.freeze({
  readOnlyHint: true,
  untrustedContentHint: false
});

function downloadInfo(documentRef) {
  const link = documentRef?.querySelector?.('[data-download]');
  const requirements = documentRef?.querySelector?.('[data-requires]');
  const url = String(link?.href || '');
  const version = /\/releases\/tag\/v([0-9]+(?:\.[0-9]+){2})(?:$|[?#])/.exec(url)?.[1] || null;
  return {
    available: Boolean(url && version),
    version,
    url: url || null,
    label: String(link?.textContent || '').replace(/\s+/g, ' ').trim(),
    requirements: String(requirements?.textContent || '').replace(/\s+/g, ' ').trim(),
    action: 'A human chooses whether to visit the release, download, install, and launch the native app.'
  };
}

export function resolveModelContext(documentRef = globalThis.document) {
  return documentRef?.modelContext?.registerTool ? documentRef.modelContext : null;
}

export function buildWebMcpTools({ documentRef = globalThis.document, windowRef = globalThis.window } = {}) {
  return [
    {
      name: 'magnetite_site_overview',
      title: 'Magnetite Site Overview',
      description: 'Returns the current Magnetite product page, native app purpose, audio behavior, and human-only download boundary.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      annotations,
      execute: async () => ({
        product: 'Magnetite',
        page: {
          title: String(documentRef?.title || 'Magnetite'),
          url: `${windowRef?.location?.origin || 'https://magnetite.app'}${windowRef?.location?.pathname || '/'}`
        },
        purpose: 'A native macOS music player that lives in the camera notch.',
        behavior: 'One continuous black ferrofluid reservoir reacts to a real tap on system audio.',
        soundtrack: 'Circles at the foot of the page play, pause and choose between two tracks, which drive the liquid through the app\'s twelve-band analyser. It asks to play on load, starts on the visitor\'s first gesture where the browser requires one, and remembers a pause.',
        licenseCost: 'Free and open source (MIT License)',
        sourceCode: 'https://github.com/scryst/magnetite',
        protectedBoundary: 'These website tools are read-only. They do not download, install, launch, control audio, or change the native Magnetite app.'
      })
    },
    {
      name: 'magnetite_get_download',
      title: 'Get Magnetite Download',
      description: 'Returns the exact GitHub Release page, build version, displayed requirements, and file size from the visible page without starting a download.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      annotations,
      execute: async () => downloadInfo(documentRef)
    },
    {
      name: 'magnetite_get_demo_states',
      title: 'Get Magnetite Demo States',
      description: 'Explains the page simulation, filmed native app, and retracted download view.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      annotations,
      execute: async () => ({
        views: [
          { state: 'hero', element: '#hero-print', description: 'A printed MacBook with the page simulation hanging open from its notch.' },
          { state: 'native-film', element: '#demo-film', description: 'Recorded footage shows the real app opening, controlling music, and retracting.' },
          { state: 'retracted', element: '#band-print', description: 'A printed menu bar with the page simulation retracted into the notch, which is the download link.' }
        ],
        relationship: 'The hero and menu-bar prints are two views of one page simulation; the film between them is the native app itself.'
      })
    }
  ];
}

export async function initWebMcp({
  documentRef = globalThis.document,
  windowRef = globalThis.window,
  modelContext = resolveModelContext(documentRef)
} = {}) {
  if (!modelContext) return { supported: false, registeredToolNames: [] };
  let registered = registrations.get(modelContext);
  if (!registered) {
    registered = new Set();
    registrations.set(modelContext, registered);
  }
  const registeredToolNames = [];
  for (const tool of buildWebMcpTools({ documentRef, windowRef })) {
    if (registered.has(tool.name)) continue;
    await modelContext.registerTool(tool);
    registered.add(tool.name);
    registeredToolNames.push(tool.name);
  }
  return { supported: true, registeredToolNames };
}

if (globalThis.document && globalThis.window) {
  void initWebMcp().catch((error) => {
    globalThis.console?.warn('[magnetite-webmcp] Tool registration failed:', error);
  });
}
