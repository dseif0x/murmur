<script>
  import { tick } from 'svelte';
  import Icon from './Icon.svelte';
  import { api, fmtTime, fmtDay, dayKey } from '../lib/api.js';
  import { route, go } from '../lib/router.svelte.js';
  import { config } from '../lib/config.svelte.js';

  let { refreshKey = 0 } = $props();

  let days = $state([]);
  let transcripts = $state([]);
  let loading = $state(false);
  let error = $state('');
  let query = $state(route.query.get('q') || '');
  let searchTimer;

  const day = $derived(route.arg || '');
  const focus = $derived(route.query.get('t') || '');
  const searching = $derived(!!route.query.get('q'));

  async function loadDays() {
    try {
      days = await api.days();
    } catch (e) {
      error = e.message;
    }
  }

  $effect(() => {
    refreshKey;
    loadDays();
  });

  // a transcript link without a day: look the transcript up, open its day
  $effect(() => {
    if (focus && !day && !searching) {
      api.transcripts({ id: focus }).then((r) => {
        if (r[0]) go('timeline', dayKey(r[0].started_at), { t: focus });
        else error = 'That transcript has expired.';
      });
    }
  });

  // no day picked: open the newest one
  $effect(() => {
    if (!day && !focus && !searching && days.length) go('timeline', days[0].day);
  });

  $effect(() => {
    const d = day;
    const q = route.query.get('q') || '';
    refreshKey;
    if (!d && !q) return;
    loading = true;
    error = '';
    api
      .transcripts(q ? { q, limit: 300 } : { day: d, limit: 2000 })
      .then(async (r) => {
        transcripts = r;
        loading = false;
        await tick();
        if (focus) document.getElementById('t-' + focus)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
      })
      .catch((e) => {
        error = e.message;
        loading = false;
      });
  });

  function onSearch() {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      const q = query.trim();
      if (q) go('timeline', '', { q });
      else go('timeline', days[0]?.day || '');
    }, 300);
  }

  // Conversations: a device's transcripts, split where it heard nothing for
  // longer than the server's gap (conversation_gap_minutes). Devices don't mix:
  // the Mac and the phone in the same room are two conversations.
  const blocks = $derived.by(() => {
    if (searching) return transcripts.map((t) => ({ start: t.started_at, end: t.ended_at, device: t.device, items: [t] }));
    const gap = (config.conversation_gap_minutes || 10) * 60000;
    const open = new Map(); // device -> its current conversation
    const out = [];
    for (const t of transcripts) {
      let cur = open.get(t.device);
      if (!cur || new Date(t.started_at) - new Date(cur.end) > gap) {
        cur = { start: t.started_at, end: t.ended_at, device: t.device, items: [] };
        open.set(t.device, cur);
        out.push(cur);
      }
      cur.items.push(t);
      if (new Date(t.ended_at) > new Date(cur.end)) cur.end = t.ended_at;
    }
    return out;
  });

  const words = (b) => b.items.reduce((n, t) => n + (t.text.trim().split(/\s+/).filter(Boolean).length || 0), 0);

  function duration(b) {
    const min = Math.round((new Date(b.end) - new Date(b.start)) / 60000);
    return min < 1 ? '<1 min' : min < 60 ? `${min} min` : `${Math.floor(min / 60)} h ${min % 60} min`;
  }

  // a stable colour per speaker label ("me" gets the accent)
  const PALETTE = ['#f6c177', '#9ccfd8', '#c4a7e7', '#eb6f92', '#a3be8c', '#ebbcba'];
  function speakerColor(s) {
    if (s === 'me') return 'var(--accent)';
    const n = parseInt(s.replace(/\D/g, ''), 10) || 0;
    return PALETTE[n % PALETTE.length];
  }

  let copied = $state('');
  async function copy(b) {
    const head = `## ${fmtDay(b.start)} ${fmtTime(b.start)}–${fmtTime(b.end)} · ${b.device}`;
    const body = b.items
      .map((t) => `**${fmtTime(t.started_at)}${t.speaker ? ' · ' + t.speaker : ''}** ${t.text}`)
      .join('\n\n');
    try {
      await navigator.clipboard.writeText(`${head}\n\n${body}\n`);
      copied = b.start + b.device;
      setTimeout(() => (copied = ''), 2000);
    } catch {
      /* clipboard needs https or localhost */
    }
  }

  const dayInfo = $derived(days.find((d) => d.day === day));
</script>

<div class="layout">
  <aside class="days">
    <div class="search">
      <Icon name="search" size={16} />
      <input bind:value={query} oninput={onSearch} placeholder="Search everything" type="search" />
    </div>
    <nav>
      {#each days as d (d.day)}
        <button class:on={d.day === day && !searching} onclick={() => go('timeline', d.day)}>
          <span>{fmtDay(d.day + 'T12:00:00')}</span>
          <small>{d.count}</small>
        </button>
      {:else}
        <p class="muted pad">No transcripts yet.</p>
      {/each}
    </nav>
  </aside>

  <section class="main">
    {#if searching}
      <h1>Results for “{route.query.get('q')}” <small>{transcripts.length}</small></h1>
    {:else if day}
      <h1>
        {fmtDay(day + 'T12:00:00')}
        {#if dayInfo}<small>{dayInfo.count} segments · {dayInfo.words} words</small>{/if}
      </h1>
    {/if}
    {#if error}<p class="error">{error}</p>{/if}
    {#if loading && !transcripts.length}
      <p class="muted">Loading…</p>
    {:else if !transcripts.length && (day || searching)}
      <p class="muted">Nothing {searching ? 'found' : 'on this day'}.</p>
    {/if}
    {#each blocks as b, i (b.start + b.device + i)}
      {#if !searching}
        <div class="block-head">
          <span>{fmtTime(b.start)} – {fmtTime(b.end)}</span>
          <span>· {b.device}</span>
          <span>· {duration(b)} · {words(b)} words</span>
          <button class="copy" onclick={() => copy(b)} title="Copy this conversation as Markdown">
            <Icon name={copied === b.start + b.device ? 'check' : 'copy'} size={12} />
            {copied === b.start + b.device ? 'Copied' : 'Copy'}
          </button>
        </div>
      {/if}
      <div class="block">
        {#each b.items as t (t.id)}
          <div class="seg" id="t-{t.id}" class:focus={t.id === focus}>
            <div class="when">
              {#if searching}<button class="link" onclick={() => go('timeline', dayKey(t.started_at), { t: t.id })}>{fmtDay(t.started_at)}</button>{/if}
              <span>{fmtTime(t.started_at)}</span>
            </div>
            <div class="text">
              {#if t.speaker}<span class="speaker" style="color: {speakerColor(t.speaker)}">{t.speaker}</span>{/if}
              <p>{t.text}</p>
              <div class="tags">
                <span title="Device"><Icon name={t.mode === 'ptt' ? 'mic' : 'laptop'} size={12} /> {t.device}</span>
                {#if t.language}<span>{t.language}</span>{/if}
                {#if config.classify}
                  {#if !t.processed}<span class="pending">not processed yet</span>{/if}
                  {#each t.item_ids as id (id)}
                    <a class="item-link" href="#/items">item #{id}</a>
                  {/each}
                {/if}
              </div>
            </div>
          </div>
        {/each}
      </div>
    {/each}
  </section>
</div>

<style>
  .layout {
    display: grid;
    grid-template-columns: 220px 1fr;
    gap: 20px;
  }
  .days {
    position: sticky;
    top: 70px;
    align-self: start;
    max-height: calc(100vh - 90px);
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .search {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 10px;
    border-radius: 10px;
    background: var(--card);
    border: 1px solid var(--line);
    color: var(--muted);
  }
  .search input {
    border: 0;
    background: none;
    padding: 9px 0;
    flex: 1;
    min-width: 0;
  }
  nav {
    overflow-y: auto;
    display: grid;
    gap: 2px;
  }
  nav button {
    display: flex;
    justify-content: space-between;
    padding: 8px 10px;
    border-radius: 8px;
    color: var(--soft);
    text-align: left;
  }
  nav button:hover {
    background: var(--hover);
  }
  nav button.on {
    background: var(--hover-strong);
    color: var(--text);
    font-weight: 600;
  }
  nav small {
    color: var(--muted);
  }
  h1 {
    font-size: 20px;
    margin: 0 0 14px;
  }
  h1 small {
    font-size: 13px;
    font-weight: 400;
    color: var(--muted);
    margin-left: 8px;
  }
  .block-head {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    color: var(--muted);
    margin: 18px 0 6px;
    letter-spacing: 0.03em;
  }
  .copy {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    margin-left: auto;
    padding: 2px 8px;
    border-radius: 6px;
    font-size: 11.5px;
    color: var(--muted);
  }
  .copy:hover {
    color: var(--text);
    background: var(--hover);
  }
  .block {
    border-left: 2px solid var(--line);
    padding-left: 12px;
    display: grid;
    gap: 2px;
  }
  .seg {
    display: grid;
    grid-template-columns: 56px 1fr;
    gap: 10px;
    padding: 6px 8px;
    border-radius: 8px;
    scroll-margin-top: 90px;
  }
  .seg.focus {
    background: rgba(138, 180, 255, 0.14);
    box-shadow: inset 0 0 0 1px rgba(138, 180, 255, 0.4);
  }
  .when {
    font-size: 12.5px;
    color: var(--muted);
    font-variant-numeric: tabular-nums;
    padding-top: 2px;
    display: grid;
    align-content: start;
  }
  .speaker {
    display: inline-block;
    font-size: 11.5px;
    font-weight: 600;
    letter-spacing: 0.02em;
    margin-bottom: 1px;
  }
  .text p {
    margin: 0;
    line-height: 1.5;
    overflow-wrap: anywhere;
  }
  .tags {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 3px;
    font-size: 11.5px;
    color: var(--muted);
  }
  .tags span {
    display: inline-flex;
    align-items: center;
    gap: 3px;
  }
  .pending {
    color: #f6c177;
  }
  .item-link {
    color: var(--accent);
  }
  .link {
    color: var(--accent);
    font-size: 12px;
    text-align: left;
    padding: 0;
  }
  .pad {
    padding: 8px 10px;
  }
  .error {
    color: var(--danger);
  }
  @media (max-width: 760px) {
    .layout {
      grid-template-columns: 1fr;
      gap: 12px;
    }
    .days {
      position: static;
      max-height: none;
    }
    nav {
      display: flex;
      overflow-x: auto;
      gap: 6px;
      scrollbar-width: none;
    }
    nav button {
      flex: none;
      gap: 8px;
      background: var(--card);
      border: 1px solid var(--line);
    }
    .seg {
      grid-template-columns: 46px 1fr;
      gap: 8px;
    }
  }
</style>
