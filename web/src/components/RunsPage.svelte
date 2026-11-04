<script>
  import { api, fmtAgo } from '../lib/api.js';

  let { refreshKey = 0 } = $props();
  let runs = $state([]);
  let error = $state('');

  $effect(() => {
    refreshKey;
    api
      .runs()
      .then((r) => (runs = r))
      .catch((e) => (error = e.message));
  });

  const secs = (r) => Math.max(0, Math.round((new Date(r.finished_at) - new Date(r.started_at)) / 1000));
</script>

<h1>Runs</h1>
<p class="muted intro">
  Every run the worker made with something to process. Runs that found nothing to do aren't listed (they don't call the
  model).
</p>
{#if error}<p class="error">{error}</p>{/if}
<div class="table">
  <div class="row head">
    <span>When</span><span>Transcripts</span><span>Created</span><span>Updated</span><span>Tokens</span><span>Took</span>
  </div>
  {#each runs as r (r.id)}
    <div class="row" class:failed={r.error}>
      <span title={new Date(r.finished_at).toLocaleString()}>{fmtAgo(r.finished_at)}</span>
      <span>{r.transcripts}</span>
      <span>{r.items_created}</span>
      <span>{r.items_updated}</span>
      <span>{r.prompt_tokens + r.completion_tokens}</span>
      <span>{secs(r)} s</span>
      {#if r.error}<p class="err">{r.error}</p>{/if}
    </div>
  {:else}
    <p class="muted">No runs yet.</p>
  {/each}
</div>

<style>
  h1 {
    font-size: 20px;
    margin: 0 0 6px;
  }
  .intro {
    margin: 0 0 16px;
    font-size: 14px;
  }
  .table {
    display: grid;
    gap: 2px;
  }
  .row {
    display: grid;
    grid-template-columns: 1.6fr repeat(5, 1fr);
    gap: 8px;
    padding: 9px 12px;
    border-radius: 8px;
    background: var(--card);
    font-variant-numeric: tabular-nums;
    font-size: 14px;
  }
  .head {
    background: none;
    color: var(--muted);
    font-size: 12px;
  }
  .failed {
    box-shadow: inset 3px 0 0 var(--danger);
  }
  .err {
    grid-column: 1 / -1;
    margin: 4px 0 0;
    color: var(--danger);
    font-size: 12.5px;
    overflow-wrap: anywhere;
  }
  .error {
    color: var(--danger);
  }
  @media (max-width: 600px) {
    .row {
      grid-template-columns: 1.5fr repeat(3, 1fr);
    }
    .row > span:nth-child(5),
    .row > span:nth-child(6) {
      display: none;
    }
  }
</style>
