<script>
  import Icon from './Icon.svelte';
  import ItemCard from './ItemCard.svelte';
  import { api, startOfDay } from '../lib/api.js';

  let { refreshKey = 0 } = $props();

  const STATUSES = [
    { id: 'open', label: 'Open' },
    { id: 'done', label: 'Done' },
    { id: 'dismissed', label: 'Dismissed' },
  ];
  const KINDS = [
    { id: '', label: 'All' },
    { id: 'reminder', label: 'Reminders' },
    { id: 'todo', label: 'Todos' },
    { id: 'event', label: 'Events' },
    { id: 'note', label: 'Notes' },
  ];

  let status = $state('open');
  let kind = $state('');
  let items = $state([]);
  let loading = $state(true);
  let error = $state('');
  let adding = $state(false);
  let newKind = $state('todo');
  let newTitle = $state('');
  let newDue = $state('');

  async function load() {
    error = '';
    try {
      items = await api.items(status, kind);
    } catch (e) {
      error = e.message;
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    status;
    kind;
    refreshKey;
    load();
  });

  // open items in buckets by when they're due; notes on their own
  const groups = $derived.by(() => {
    if (status !== 'open') return [{ label: '', items }];
    const today = startOfDay(new Date());
    const tomorrow = new Date(+today + 86400000);
    const week = new Date(+today + 7 * 86400000);
    const g = { Overdue: [], Today: [], Tomorrow: [], 'This week': [], Later: [], 'No date': [], Notes: [] };
    for (const it of items) {
      if (it.kind === 'note') g.Notes.push(it);
      else if (!it.due_at) g['No date'].push(it);
      else {
        const d = new Date(it.due_at);
        // a bare date is due by the end of that day
        const dateOnly = d.getHours() === 0 && d.getMinutes() === 0;
        const deadline = dateOnly ? new Date(+d + 86400000 - 1) : d;
        if (deadline < Date.now()) g.Overdue.push(it);
        else if (d < tomorrow) g.Today.push(it);
        else if (d < new Date(+tomorrow + 86400000)) g.Tomorrow.push(it);
        else if (d < week) g['This week'].push(it);
        else g.Later.push(it);
      }
    }
    return Object.entries(g)
      .filter(([, v]) => v.length)
      .map(([label, v]) => ({ label, items: v }));
  });

  function changed(it) {
    const i = items.findIndex((x) => x.id === it.id);
    if (i < 0) return;
    // leaves the current view when its status no longer matches
    if (it.status !== status) items = items.filter((x) => x.id !== it.id);
    else items[i] = it;
  }

  async function add(e) {
    e.preventDefault();
    try {
      const it = await api.createItem({ kind: newKind, title: newTitle, due_at: newDue ? new Date(newDue).toISOString() : null });
      if (status === 'open') items = [it, ...items];
      newTitle = '';
      newDue = '';
      adding = false;
    } catch (e) {
      error = e.message;
    }
  }
</script>

<div class="toolbar">
  <div class="seg">
    {#each STATUSES as s (s.id)}
      <button class:on={status === s.id} onclick={() => (status = s.id)}>{s.label}</button>
    {/each}
  </div>
  <button class="btn" onclick={() => (adding = !adding)}><Icon name="plus" size={16} /> Add</button>
</div>
<div class="chips">
  {#each KINDS as k (k.id)}
    <button class="chip" class:on={kind === k.id} onclick={() => (kind = k.id)}>{k.label}</button>
  {/each}
</div>

{#if adding}
  <form class="add" onsubmit={add}>
    <select bind:value={newKind}>
      <option value="todo">Todo</option>
      <option value="reminder">Reminder</option>
      <option value="event">Event</option>
      <option value="note">Note</option>
    </select>
    <input bind:value={newTitle} placeholder="Title" required maxlength="300" />
    <input type="datetime-local" bind:value={newDue} />
    <button class="btn primary" type="submit">Add</button>
  </form>
{/if}

{#if error}<p class="error">{error}</p>{/if}

{#if loading}
  <p class="muted">Loading…</p>
{:else if !items.length}
  <div class="empty">
    <Icon name="wave" size={36} />
    <p>{status === 'open' ? 'Nothing to do. Things you say you need to do show up here.' : 'Nothing here.'}</p>
  </div>
{:else}
  {#each groups as g (g.label)}
    {#if g.label}<h2 class:danger={g.label === 'Overdue'}>{g.label} <span>{g.items.length}</span></h2>{/if}
    <div class="list">
      {#each g.items as it (it.id)}
        <ItemCard item={it} onchange={changed} />
      {/each}
    </div>
  {/each}
{/if}

<style>
  .toolbar {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    margin-bottom: 10px;
  }
  .chips {
    display: flex;
    gap: 6px;
    overflow-x: auto;
    margin-bottom: 14px;
    scrollbar-width: none;
  }
  .add {
    display: grid;
    grid-template-columns: auto 1fr auto auto;
    gap: 6px;
    margin-bottom: 14px;
  }
  @media (max-width: 600px) {
    .add {
      grid-template-columns: 1fr 1fr;
    }
    .add input[required] {
      grid-column: span 2;
    }
  }
  h2 {
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--muted);
    margin: 18px 4px 8px;
  }
  h2 span {
    font-weight: 400;
    margin-left: 4px;
  }
  h2.danger {
    color: var(--danger);
  }
  .list {
    display: grid;
    gap: 8px;
  }
  .empty {
    text-align: center;
    color: var(--muted);
    padding: 60px 20px;
  }
  .error {
    color: var(--danger);
  }
</style>
