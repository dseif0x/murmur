import { api } from './api.js';

// Which features the server has on (GET /api/config). Classification (the
// LLM worker: items and runs) is optional; without it murmur stores and shows
// what was said.
export const config = $state({ loaded: false, classify: false, run_now: false, conversation_gap_minutes: 10 });

export async function loadConfig() {
  try {
    Object.assign(config, await api.config(), { loaded: true });
  } catch {
    config.loaded = true;
  }
}
