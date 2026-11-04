package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// The worker runs as a Kubernetes CronJob. Each run: anything pending? If
// not, exit at once (no model call, so the GPU node stays asleep). If so,
// take a batch, ask the model what needs doing, and publish the answer on
// NATS (murmur.results); the server stores it. Big backlogs go in several
// chunks, each waiting for the previous result to be stored so the model
// sees the items it just created.

type workerConfig struct {
	LLMBaseURL      string
	LLMAPIKey       string
	Model           string
	OutputLanguage  string
	MaxChars        int           // transcript text per model call
	MaxTranscripts  int           // per run
	ClaimTTL        time.Duration // a dead run's batch is free again after this
	LLMTimeout      time.Duration
	ApplyTimeout    time.Duration // waiting for the server to store a result
	OpenItemsInCtx  int
	ExtraPrompt     string
	DisableThinking bool
}

func newRunID() string {
	b := make([]byte, 4)
	rand.Read(b)
	return time.Now().UTC().Format("20060102-150405") + "-" + hex.EncodeToString(b)
}

func runWorker(ctx context.Context, st *store, b *bus, cfg workerConfig) error {
	n, err := st.pending(ctx, cfg.ClaimTTL)
	if err != nil {
		return err
	}
	if n == 0 {
		log.Print("nothing to do")
		return nil
	}
	log.Printf("%d transcripts pending", n)
	done := 0
	for done < cfg.MaxTranscripts {
		runID := newRunID()
		started := time.Now()
		batch, err := st.claim(ctx, runID, min(200, cfg.MaxTranscripts-done), cfg.ClaimTTL)
		if err != nil {
			return err
		}
		if len(batch) == 0 {
			break
		}
		// trim the batch to the per-call text budget; the rest goes back
		chunk, rest := splitByChars(batch, cfg.MaxChars)
		if len(rest) > 0 {
			if err := st.release(ctx, ids(rest)); err != nil {
				return err
			}
		}
		res, err := inferChunk(ctx, st, cfg, runID, started, chunk)
		if err != nil {
			// recorded as a failed run; the batch is released by the server
			log.Printf("run %s failed: %v", runID, err)
			res = runResult{RunID: runID, StartedAt: started, Model: cfg.Model, TranscriptIDs: ids(chunk), Error: err.Error()}
		}
		if err := b.publish(ctx, subjResults, res); err != nil {
			st.release(context.Background(), ids(chunk))
			return fmt.Errorf("publish result: %w", err)
		}
		log.Printf("run %s: %d transcripts, %d actions published", runID, len(chunk), len(res.Actions))
		if res.Error != "" {
			return errors.New(res.Error)
		}
		if err := waitApplied(ctx, st, chunk, cfg.ApplyTimeout); err != nil {
			log.Printf("run %s: %v (the server will store it when it can)", runID, err)
			return nil
		}
		done += len(chunk)
	}
	log.Printf("done: %d transcripts processed", done)
	return nil
}

func ids(ts []Transcript) []string {
	out := make([]string, len(ts))
	for i, t := range ts {
		out[i] = t.ID
	}
	return out
}

func splitByChars(ts []Transcript, max int) (chunk, rest []Transcript) {
	total := 0
	for i, t := range ts {
		total += len(t.Text) + 40
		if total > max && i > 0 {
			return ts[:i], ts[i:]
		}
	}
	return ts, nil
}

func waitApplied(ctx context.Context, st *store, chunk []Transcript, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		n, err := st.processedCount(ctx, ids(chunk))
		if err != nil {
			return err
		}
		if n == len(chunk) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return errors.New("result not stored yet")
}

// ---- the model call ---------------------------------------------------------

const systemPrompt = `You are murmur. An always-on microphone records one person, the owner, through the day, and speech recognition turns it into text. You read new transcripts and keep the owner's list of things to do and remember up to date.

Item kinds:
- reminder: something to do at a specific date or time ("call mum tomorrow at five")
- todo: a task without a fixed time ("I need to buy batteries")
- event: an appointment or meeting with a start time, maybe an end time
- note: information the owner wants to remember ("remember that ...", "the code is 4711", an idea they want to keep)

Rules:
- Only create items for things the owner commits to, agrees to do when asked, or clearly wants to remember. Ignore TV, radio, videos, music, hypotheticals, jokes, small talk and other people's business that doesn't involve the owner.
- Be conservative: no item is better than a wrong one. Transcripts contain recognition errors and fragments; don't build items from garbled text.
- Never duplicate: if an open item already covers something, use "update" (new details, new due date) instead of "create".
- If the owner says something is done ("I've called mum"), "complete" the open item. If a plan is cancelled, "dismiss" it.
- Resolve relative dates ("tomorrow", "next Friday", "in two hours", "übermorgen", "nächste Woche") against the timestamp of the transcript they were said in, in the time zone given. Write dates as "YYYY-MM-DDTHH:MM" (local time) or "YYYY-MM-DD" when there is no time.
- Titles are short and actionable (under 80 characters). Write titles and details in %s.
- "evidence" is a short exact quote of what was said. "transcripts" lists the refs (t1, t2, ...) the item comes from.

Answer with JSON only, no other text:
{"actions": [
  {"action": "create", "kind": "reminder|todo|event|note", "title": "...", "details": "...", "due": "...", "ends": "...", "evidence": "...", "transcripts": ["t3"]},
  {"action": "update", "id": 12, "title": "...", "details": "...", "due": "...", "evidence": "...", "transcripts": ["t5"]},
  {"action": "complete", "id": 7, "evidence": "...", "transcripts": ["t9"]},
  {"action": "dismiss", "id": 4, "evidence": "...", "transcripts": ["t9"]}
]}
Leave out fields you don't need. If nothing needs doing, answer {"actions": []}.`

func buildPrompt(cfg workerConfig, open []Item, chunk []Transcript, now time.Time) (sys, user string, refs map[string]string) {
	lang := cfg.OutputLanguage
	if lang == "" {
		lang = "the language the owner spoke"
	}
	sys = fmt.Sprintf(systemPrompt, lang)
	if cfg.ExtraPrompt != "" {
		sys += "\n\nAdditional instructions from the owner:\n" + cfg.ExtraPrompt
	}
	var u strings.Builder
	fmt.Fprintf(&u, "Now: %s (%s, time zone %s)\n\n", now.In(localZone).Format("2006-01-02T15:04"), now.In(localZone).Weekday(), localZone)
	u.WriteString("Open items:\n")
	if len(open) == 0 {
		u.WriteString("(none)\n")
	}
	for _, it := range open {
		due := ""
		if it.DueAt != nil {
			due = ", due " + it.DueAt.In(localZone).Format("2006-01-02T15:04")
		}
		fmt.Fprintf(&u, "- id %d [%s%s] %s", it.ID, it.Kind, due, it.Title)
		if it.Details != "" {
			fmt.Fprintf(&u, " - %s", clip(it.Details, 200))
		}
		u.WriteString("\n")
	}
	u.WriteString("\nNew transcripts:\n")
	refs = map[string]string{}
	for i, t := range chunk {
		ref := fmt.Sprintf("t%d", i+1)
		refs[ref] = t.ID
		local := t.StartedAt.In(localZone)
		fmt.Fprintf(&u, "[%s] %s %s (%s): %s\n", ref, local.Format("2006-01-02 15:04"), local.Weekday().String()[:3], t.Device, t.Text)
	}
	return sys, u.String(), refs
}

func inferChunk(ctx context.Context, st *store, cfg workerConfig, runID string, started time.Time, chunk []Transcript) (runResult, error) {
	open, err := st.openItemsForContext(ctx, cfg.OpenItemsInCtx)
	if err != nil {
		return runResult{}, err
	}
	sys, user, refs := buildPrompt(cfg, open, chunk, time.Now())
	text, usage, err := chatCompletion(ctx, cfg, sys, user)
	if err != nil {
		return runResult{}, err
	}
	actions, err := parseActions(text)
	if err != nil {
		return runResult{}, fmt.Errorf("model answer: %w", err)
	}
	return runResult{
		RunID: runID, StartedAt: started, Model: cfg.Model, TranscriptIDs: ids(chunk), Refs: refs,
		Actions: actions, PromptTokens: usage.PromptTokens, CompletionTokens: usage.CompletionTokens,
	}, nil
}

type chatUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
}

// chatCompletion calls an OpenAI-compatible chat endpoint (LiteLLM). A cold
// GPU backend can take a minute or two to answer the first request; 5xx and
// timeouts are retried a few times.
func chatCompletion(ctx context.Context, cfg workerConfig, sys, user string) (string, chatUsage, error) {
	body := map[string]any{
		"model": cfg.Model,
		"messages": []map[string]string{
			{"role": "system", "content": sys},
			{"role": "user", "content": user},
		},
		"temperature":     0.2,
		"max_tokens":      4096,
		"response_format": map[string]string{"type": "json_object"},
	}
	if cfg.DisableThinking {
		body["chat_template_kwargs"] = map[string]any{"enable_thinking": false}
	}
	payload, _ := json.Marshal(body)
	var lastErr error
	for attempt := 0; attempt < 4; attempt++ {
		if attempt > 0 {
			wait := time.Duration(attempt*attempt) * 15 * time.Second
			log.Printf("model call failed (%v), retrying in %s", lastErr, wait)
			select {
			case <-ctx.Done():
				return "", chatUsage{}, ctx.Err()
			case <-time.After(wait):
			}
		}
		text, usage, retry, err := chatOnce(ctx, cfg, payload)
		if err == nil {
			return text, usage, nil
		}
		lastErr = err
		if !retry {
			break
		}
	}
	return "", chatUsage{}, lastErr
}

func chatOnce(ctx context.Context, cfg workerConfig, payload []byte) (string, chatUsage, bool, error) {
	cctx, cancel := context.WithTimeout(ctx, cfg.LLMTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodPost, strings.TrimRight(cfg.LLMBaseURL, "/")+"/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return "", chatUsage{}, false, err
	}
	req.Header.Set("Content-Type", "application/json")
	if cfg.LLMAPIKey != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.LLMAPIKey)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", chatUsage{}, true, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode >= 500 || resp.StatusCode == http.StatusTooManyRequests {
		return "", chatUsage{}, true, fmt.Errorf("%s: %s", resp.Status, clip(string(data), 300))
	}
	if resp.StatusCode != http.StatusOK {
		return "", chatUsage{}, false, fmt.Errorf("%s: %s", resp.Status, clip(string(data), 300))
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage chatUsage `json:"usage"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return "", chatUsage{}, false, err
	}
	if len(out.Choices) == 0 {
		return "", chatUsage{}, true, errors.New("no choices in the answer")
	}
	return out.Choices[0].Message.Content, out.Usage, false, nil
}

var thinkRe = regexp.MustCompile(`(?s)<think>.*?</think>`)

// parseActions reads the model's JSON, tolerating a thinking block, code
// fences or text around it.
func parseActions(text string) ([]llmAction, error) {
	text = thinkRe.ReplaceAllString(text, "")
	start := strings.Index(text, "{")
	end := strings.LastIndex(text, "}")
	if start < 0 || end < start {
		return nil, fmt.Errorf("no JSON object in %q", clip(text, 200))
	}
	var out struct {
		Actions []llmAction `json:"actions"`
	}
	if err := json.Unmarshal([]byte(text[start:end+1]), &out); err != nil {
		return nil, err
	}
	var valid []llmAction
	for _, a := range out.Actions {
		a.Action = strings.ToLower(strings.TrimSpace(a.Action))
		switch a.Action {
		case "create":
			if itemKinds[strings.ToLower(a.Kind)] && strings.TrimSpace(a.Title) != "" {
				valid = append(valid, a)
			}
		case "update", "complete", "dismiss":
			if a.ID > 0 {
				valid = append(valid, a)
			}
		}
	}
	return valid, nil
}
