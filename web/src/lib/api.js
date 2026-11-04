async function req(method, path, body) {
  const r = await fetch(path, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await r.json().catch(() => null);
  if (!r.ok) throw new Error(data?.error || `${r.status} ${r.statusText}`);
  return data;
}

const qs = (o) => {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(o)) if (v !== undefined && v !== null && v !== '') p.set(k, v);
  const s = p.toString();
  return s ? '?' + s : '';
};

export const api = {
  status: () => req('GET', '/api/status'),
  items: (status = 'open', kind = '') => req('GET', '/api/items' + qs({ status, kind })),
  createItem: (it) => req('POST', '/api/items', it),
  patchItem: (id, p) => req('PATCH', `/api/items/${id}`, p),
  days: () => req('GET', '/api/days'),
  transcripts: (o) => req('GET', '/api/transcripts' + qs(o)),
  runs: () => req('GET', '/api/runs'),
  runNow: () => req('POST', '/api/runs'),
};

// ---- formatting -------------------------------------------------------------

const DAY = 86400000;

export function startOfDay(d) {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x;
}

export function dayKey(d) {
  const x = new Date(d);
  return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
}

export function fmtTime(d) {
  return new Date(d).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

export function fmtDay(d) {
  const x = startOfDay(d);
  const today = startOfDay(new Date());
  const diff = Math.round((x - today) / DAY);
  if (diff === 0) return 'Today';
  if (diff === -1) return 'Yesterday';
  if (diff === 1) return 'Tomorrow';
  return x.toLocaleDateString([], {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: x.getFullYear() === today.getFullYear() ? undefined : 'numeric',
  });
}

// "Tomorrow 17:00", "Fri 9 Nov", "in 2 h"
export function fmtDue(d) {
  if (!d) return '';
  const x = new Date(d);
  const hasTime = x.getHours() !== 0 || x.getMinutes() !== 0;
  const mins = (x - Date.now()) / 60000;
  if (hasTime && mins > 0 && mins < 120) return `in ${Math.round(mins)} min`;
  return fmtDay(x) + (hasTime ? ' ' + fmtTime(x) : '');
}

export function fmtAgo(d) {
  const s = (Date.now() - new Date(d)) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return fmtDay(d);
}

// <input type="datetime-local"> value <-> Date
export function toLocalInput(d) {
  if (!d) return '';
  const x = new Date(d);
  return `${dayKey(x)}T${String(x.getHours()).padStart(2, '0')}:${String(x.getMinutes()).padStart(2, '0')}`;
}
