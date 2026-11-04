<script module>
  import Bell from '@lucide/svelte/icons/bell';
  import CircleCheck from '@lucide/svelte/icons/circle-check';
  import Circle from '@lucide/svelte/icons/circle';
  import CalendarDays from '@lucide/svelte/icons/calendar-days';
  import StickyNote from '@lucide/svelte/icons/sticky-note';
  import ListTodo from '@lucide/svelte/icons/list-todo';
  import MessageSquareQuote from '@lucide/svelte/icons/message-square-quote';
  import X from '@lucide/svelte/icons/x';
  import Undo from '@lucide/svelte/icons/undo-2';
  import Play from '@lucide/svelte/icons/play';
  import Search from '@lucide/svelte/icons/search';
  import Plus from '@lucide/svelte/icons/plus';
  import Pencil from '@lucide/svelte/icons/pencil';
  import Laptop from '@lucide/svelte/icons/laptop';
  import Mic from '@lucide/svelte/icons/mic';
  import Loader from '@lucide/svelte/icons/loader-circle';
  import AudioLines from '@lucide/svelte/icons/audio-lines';
  import Activity from '@lucide/svelte/icons/activity';
  import Check from '@lucide/svelte/icons/check';
  import ChevronLeft from '@lucide/svelte/icons/chevron-left';

  const ICONS = {
    reminder: Bell,
    todo: ListTodo,
    event: CalendarDays,
    note: StickyNote,
    done: CircleCheck,
    circle: Circle,
    quote: MessageSquareQuote,
    x: X,
    undo: Undo,
    play: Play,
    search: Search,
    plus: Plus,
    edit: Pencil,
    laptop: Laptop,
    mic: Mic,
    loader: Loader,
    wave: AudioLines,
    runs: Activity,
    check: Check,
    back: ChevronLeft,
  };
</script>

<script>
  let { name, size = 18 } = $props();
  const C = $derived(ICONS[name]);
</script>

{#if C}<C {size} strokeWidth={2} aria-hidden="true" />{/if}
