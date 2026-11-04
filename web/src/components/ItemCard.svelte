<script>
  import Icon from './Icon.svelte';
  import { api, fmtDue, fmtAgo, toLocalInput } from '../lib/api.js';
  import { go } from '../lib/router.svelte.js';

  let { item, onchange } = $props();
  let editing = $state(false);
  let busy = $state(false);
  let error = $state('');
  let title = $state('');
  let details = $state('');
  let due = $state('');

  const overdue = $derived(item.status === 'open' && item.due_at && new Date(item.due_at) < Date.now() && item.kind !== 'note');

  async function patch(p) {
    busy = true;
    error = '';
    try {
      onchange(await api.patchItem(item.id, p));
      editing = false;
    } catch (e) {
      error = e.message;
    } finally {
      busy = false;
    }
  }

  function edit() {
    title = item.title;
    details = item.details;
    due = toLocalInput(item.due_at);
    editing = true;
  }

  function save(e) {
    e.preventDefault();
    const p = { title, details };
    if (due) p.due_at = new Date(due).toISOString();
    else p.clear_due = true;
    patch(p);
  }

  // the timeline finds the transcript's day itself
  function openSource() {
    if (item.sources[0]) go('timeline', '', { t: item.sources[0] });
  }
</script>

<article class="item" class:done={item.status !== 'open'} class:overdue>
  <button
    class="check"
    title={item.status === 'open' ? 'Mark done' : 'Reopen'}
    disabled={busy}
    onclick={() => patch({ status: item.status === 'open' ? 'done' : 'open' })}
  >
    <Icon name={item.status === 'done' ? 'done' : 'circle'} size={22} />
  </button>
  <div class="body">
    {#if editing}
      <form onsubmit={save} class="edit">
        <input bind:value={title} required maxlength="300" />
        <textarea bind:value={details} rows="2" placeholder="Details"></textarea>
        <input type="datetime-local" bind:value={due} />
        <div class="row">
          <button type="submit" class="btn primary" disabled={busy}>Save</button>
          <button type="button" class="btn" onclick={() => (editing = false)}>Cancel</button>
        </div>
      </form>
    {:else}
      <div class="title">{item.title}</div>
      <div class="meta">
        <span class="kind k-{item.kind}"><Icon name={item.kind} size={13} /> {item.kind}</span>
        {#if item.due_at}<span class="due">{fmtDue(item.due_at)}</span>{/if}
        {#if item.status === 'dismissed'}<span>dismissed</span>{/if}
        <span class="ago" title={new Date(item.created_at).toLocaleString()}>{fmtAgo(item.created_at)}</span>
      </div>
      {#if item.details}<p class="details">{item.details}</p>{/if}
      {#if item.evidence}
        <button class="evidence" onclick={openSource} disabled={!item.sources.length} title="Show in the timeline">
          <Icon name="quote" size={14} />
          <span>{item.evidence}</span>
        </button>
      {/if}
      {#if error}<p class="error">{error}</p>{/if}
    {/if}
  </div>
  {#if !editing}
    <div class="actions">
      <button class="icon" title="Edit" onclick={edit}><Icon name="edit" size={16} /></button>
      {#if item.status === 'open'}
        <button class="icon" title="Dismiss" disabled={busy} onclick={() => patch({ status: 'dismissed' })}><Icon name="x" size={16} /></button>
      {:else}
        <button class="icon" title="Reopen" disabled={busy} onclick={() => patch({ status: 'open' })}><Icon name="undo" size={16} /></button>
      {/if}
    </div>
  {/if}
</article>

<style>
  .item {
    display: flex;
    gap: 10px;
    padding: 12px 12px 12px 8px;
    border-radius: 14px;
    background: var(--card);
    border: 1px solid var(--line);
  }
  .item.done .title {
    text-decoration: line-through;
    color: var(--muted);
  }
  .check {
    color: var(--muted);
    padding: 2px;
    height: fit-content;
  }
  .item.done .check {
    color: var(--good);
  }
  .check:hover {
    color: var(--accent);
  }
  .body {
    flex: 1;
    min-width: 0;
  }
  .title {
    font-weight: 600;
    line-height: 1.35;
    overflow-wrap: anywhere;
  }
  .meta {
    display: flex;
    flex-wrap: wrap;
    gap: 4px 10px;
    margin-top: 4px;
    font-size: 12.5px;
    color: var(--muted);
  }
  .kind {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    text-transform: capitalize;
  }
  .k-reminder {
    color: #f6c177;
  }
  .k-event {
    color: #9ccfd8;
  }
  .k-todo {
    color: #8ab4ff;
  }
  .k-note {
    color: #c4a7e7;
  }
  .overdue .due {
    color: var(--danger);
    font-weight: 600;
  }
  .details {
    margin: 6px 0 0;
    color: var(--soft);
    font-size: 14px;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  .evidence {
    display: flex;
    gap: 6px;
    align-items: flex-start;
    margin-top: 8px;
    padding: 6px 8px;
    border-radius: 8px;
    background: var(--hover);
    color: var(--soft);
    font-size: 13px;
    font-style: italic;
    text-align: left;
    width: 100%;
  }
  .evidence :global(svg) {
    flex: none;
    margin-top: 2px;
    color: var(--muted);
  }
  .evidence:not(:disabled):hover {
    background: var(--hover-strong);
  }
  .evidence span {
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  .actions {
    display: flex;
    gap: 2px;
    height: fit-content;
  }
  .icon {
    width: 30px;
    height: 30px;
    border-radius: 8px;
    color: var(--muted);
  }
  .icon:hover {
    background: var(--hover);
    color: var(--text);
  }
  .edit {
    display: grid;
    gap: 6px;
  }
  .row {
    display: flex;
    gap: 6px;
  }
  .error {
    color: var(--danger);
    font-size: 13px;
    margin: 6px 0 0;
  }
</style>
