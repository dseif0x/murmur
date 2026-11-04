// Hash routes: #/items, #/timeline/2026-11-04?t=<transcript id>, #/runs
function parse() {
  const h = location.hash.replace(/^#\/?/, '');
  const [path, query = ''] = h.split('?');
  const parts = path.split('/').filter(Boolean);
  return { page: parts[0] || 'items', arg: parts[1] || '', query: new URLSearchParams(query) };
}

export const route = $state(parse());

if (typeof window !== 'undefined') {
  window.addEventListener('hashchange', () => Object.assign(route, parse()));
}

export function go(page, arg = '', query = {}) {
  const q = new URLSearchParams(Object.entries(query).filter(([, v]) => v)).toString();
  location.hash = `#/${page}${arg ? '/' + arg : ''}${q ? '?' + q : ''}`;
}
