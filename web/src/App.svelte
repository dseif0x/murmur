<script>
  import Icon from './components/Icon.svelte';
  import ItemsPage from './components/ItemsPage.svelte';
  import TimelinePage from './components/TimelinePage.svelte';
  import RunsPage from './components/RunsPage.svelte';
  import { api } from './lib/api.js';
  import { route, go } from './lib/router.svelte.js';
  import { config, loadConfig } from './lib/config.svelte.js';

  let status = $state(null);
  let refreshKey = $state(0);
  let starting = $state(false);
  let toast = $state('');
  let toastTimer;

  function say(msg) {
    toast = msg;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (toast = ''), 4000);
  }

  async function loadStatus() {
    try {
      status = await api.status();
    } catch {
      status = null;
    }
  }

  $effect(() => {
    loadConfig();
    loadStatus();
    // keep counts and lists fresh while the page is open
    const t = setInterval(() => {
      if (document.visibilityState === 'visible') {
        loadStatus();
        refreshKey++;
      }
    }, 60000);
    return () => clearInterval(t);
  });

  async function runNow() {
    starting = true;
    try {
      const r = await api.runNow();
      say(`Started ${r.job}. Results show up in a minute or two.`);
    } catch (e) {
      say(e.message);
    } finally {
      starting = false;
    }
  }

  const ALL_TABS = [
    { id: 'items', label: 'Items', icon: 'todo', classify: true },
    { id: 'timeline', label: 'Timeline', icon: 'wave' },
    { id: 'runs', label: 'Runs', icon: 'runs', classify: true },
  ];
  // without classification there are no items or runs: only the timeline
  const TABS = $derived(ALL_TABS.filter((t) => !t.classify || config.classify));
  const home = $derived(config.classify ? 'items' : 'timeline');
  // the default page (or an items/runs link with classification off)
  const page = $derived(
    config.loaded && (!route.page || (!config.classify && (route.page === 'items' || route.page === 'runs')))
      ? home
      : route.page || home,
  );
</script>

<header>
  <div class="inner">
    <a class="brand" href="#/{home}"><img src="/icon.svg" alt="" width="26" height="26" /> murmur</a>
    <nav>
      {#each TABS as t (t.id)}
        <button class:on={page === t.id} onclick={() => go(t.id)}>
          <Icon name={t.icon} size={16} /><span>{t.label}</span>
        </button>
      {/each}
    </nav>
    <div class="status">
      {#if status && config.classify}
        <span class="pending" title="Transcripts waiting for the next run">{status.pending} pending</span>
        {#if status.run_now}
          <button class="btn small" disabled={starting || !status.pending} onclick={runNow} title="Process pending transcripts now">
            <Icon name={starting ? 'loader' : 'play'} size={14} /> Run
          </button>
        {/if}
      {/if}
    </div>
  </div>
</header>

<main>
  {#if !config.loaded}
    <p class="muted">Loading…</p>
  {:else if page === 'timeline'}
    <TimelinePage {refreshKey} />
  {:else if page === 'runs'}
    <RunsPage {refreshKey} />
  {:else}
    <ItemsPage {refreshKey} />
  {/if}
</main>

{#if toast}<div class="toast">{toast}</div>{/if}

<style>
  header {
    position: sticky;
    top: 0;
    z-index: 10;
    background: rgba(13, 15, 20, 0.85);
    backdrop-filter: blur(14px);
    -webkit-backdrop-filter: blur(14px);
    border-bottom: 1px solid var(--line);
    padding-top: env(safe-area-inset-top);
  }
  .inner {
    max-width: 1100px;
    margin: 0 auto;
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 10px 16px;
  }
  .brand {
    display: flex;
    align-items: center;
    gap: 8px;
    font-weight: 700;
    font-size: 17px;
    color: var(--text);
    text-decoration: none;
  }
  nav {
    display: flex;
    gap: 4px;
    flex: 1;
  }
  nav button {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 7px 12px;
    border-radius: 9px;
    color: var(--muted);
  }
  nav button:hover {
    color: var(--text);
    background: var(--hover);
  }
  nav button.on {
    color: var(--text);
    background: var(--hover-strong);
  }
  .status {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    color: var(--muted);
  }
  main {
    max-width: 1100px;
    margin: 0 auto;
    padding: 18px 16px calc(40px + env(safe-area-inset-bottom));
  }
  .toast {
    position: fixed;
    left: 50%;
    bottom: calc(24px + env(safe-area-inset-bottom));
    transform: translateX(-50%);
    background: #23262f;
    border: 1px solid var(--line);
    padding: 10px 16px;
    border-radius: 12px;
    font-size: 14px;
    box-shadow: 0 6px 24px rgba(0, 0, 0, 0.4);
    max-width: calc(100vw - 32px);
  }
  @media (max-width: 600px) {
    .inner {
      gap: 8px;
      padding: 8px 12px;
    }
    .brand {
      font-size: 0;
      gap: 0;
    }
    nav button span {
      display: none;
    }
    nav button.on span {
      display: inline;
    }
  }
</style>
