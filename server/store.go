package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Transcript struct {
	ID        string    `json:"id"`
	Device    string    `json:"device"`
	Mode      string    `json:"mode"`
	StartedAt time.Time `json:"started_at"`
	EndedAt   time.Time `json:"ended_at"`
	Text      string    `json:"text"`
	Language  string    `json:"language,omitempty"`
	Processed bool      `json:"processed"`
	ItemIDs   []int64   `json:"item_ids,omitempty"`
}

type Item struct {
	ID          int64      `json:"id"`
	Kind        string     `json:"kind"`
	Title       string     `json:"title"`
	Details     string     `json:"details"`
	DueAt       *time.Time `json:"due_at,omitempty"`
	EndsAt      *time.Time `json:"ends_at,omitempty"`
	Status      string     `json:"status"`
	Evidence    string     `json:"evidence"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
	CompletedAt *time.Time `json:"completed_at,omitempty"`
	CreatedBy   string     `json:"created_by"`
	Sources     []string   `json:"sources"`
}

type Run struct {
	ID               string    `json:"id"`
	StartedAt        time.Time `json:"started_at"`
	FinishedAt       time.Time `json:"finished_at"`
	Model            string    `json:"model"`
	Transcripts      int       `json:"transcripts"`
	ItemsCreated     int       `json:"items_created"`
	ItemsUpdated     int       `json:"items_updated"`
	PromptTokens     int       `json:"prompt_tokens"`
	CompletionTokens int       `json:"completion_tokens"`
	Error            string    `json:"error"`
}

var (
	itemKinds  = map[string]bool{"reminder": true, "todo": true, "note": true, "event": true}
	itemStates = map[string]bool{"open": true, "done": true, "dismissed": true}
)

type store struct{ db *pgxpool.Pool }

// ---- transcripts ------------------------------------------------------------

// insertTranscripts stores new transcripts; ones already there (a retried
// upload) are skipped. Returns the ids that were new.
func (s *store) insertTranscripts(ctx context.Context, ts []Transcript) ([]string, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var added []string
	for _, t := range ts {
		var id string
		err := tx.QueryRow(ctx, `
			INSERT INTO transcripts (id, device, mode, started_at, ended_at, text, language)
			VALUES ($1, $2, $3, $4, $5, $6, NULLIF($7, ''))
			ON CONFLICT (id) DO NOTHING RETURNING id`,
			t.ID, t.Device, t.Mode, t.StartedAt, t.EndedAt, t.Text, t.Language).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, err
		}
		added = append(added, id)
	}
	return added, tx.Commit(ctx)
}

type transcriptQuery struct {
	From, To time.Time
	Search   string
	Device   string
	ID       string
	Limit    int
}

func (s *store) listTranscripts(ctx context.Context, q transcriptQuery) ([]Transcript, error) {
	args := []any{}
	where := []string{}
	add := func(cond string, v any) {
		args = append(args, v)
		where = append(where, fmt.Sprintf(cond, len(args)))
	}
	if !q.From.IsZero() {
		add("t.started_at >= $%d", q.From)
	}
	if !q.To.IsZero() {
		add("t.started_at < $%d", q.To)
	}
	if q.Device != "" {
		add("t.device = $%d", q.Device)
	}
	if q.ID != "" {
		add("t.id = $%d::uuid", q.ID)
	}
	if q.Search != "" {
		add("to_tsvector('simple', t.text) @@ websearch_to_tsquery('simple', $%d)", q.Search)
	}
	if q.Limit <= 0 || q.Limit > 2000 {
		q.Limit = 500
	}
	order := "t.started_at"
	if q.Search != "" {
		order = "t.started_at DESC" // search: newest first
	}
	sql := `SELECT t.id, t.device, t.mode, t.started_at, t.ended_at, t.text, coalesce(t.language, ''),
		t.processed_at IS NOT NULL,
		coalesce((SELECT array_agg(item_id ORDER BY item_id) FROM item_sources s WHERE s.transcript_id = t.id), '{}')
		FROM transcripts t`
	if len(where) > 0 {
		sql += " WHERE " + strings.Join(where, " AND ")
	}
	sql += fmt.Sprintf(" ORDER BY %s LIMIT %d", order, q.Limit)
	rows, err := s.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Transcript{}
	for rows.Next() {
		var t Transcript
		if err := rows.Scan(&t.ID, &t.Device, &t.Mode, &t.StartedAt, &t.EndedAt, &t.Text, &t.Language, &t.Processed, &t.ItemIDs); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

type dayCount struct {
	Day   string `json:"day"` // YYYY-MM-DD in tz
	Count int    `json:"count"`
	Words int    `json:"words"`
}

// days counts transcripts per local day (tz is an IANA zone name).
func (s *store) days(ctx context.Context, tz string) ([]dayCount, error) {
	rows, err := s.db.Query(ctx, `
		SELECT to_char(started_at AT TIME ZONE $1, 'YYYY-MM-DD') AS day, count(*),
			sum(array_length(regexp_split_to_array(trim(text), '\s+'), 1))
		FROM transcripts GROUP BY day ORDER BY day DESC`, tz)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []dayCount{}
	for rows.Next() {
		var d dayCount
		var words *int
		if err := rows.Scan(&d.Day, &d.Count, &words); err != nil {
			return nil, err
		}
		if words != nil {
			d.Words = *words
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *store) devices(ctx context.Context) ([]string, error) {
	rows, err := s.db.Query(ctx, `SELECT DISTINCT device FROM transcripts ORDER BY device`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// pending counts transcripts waiting for a run (unprocessed, unclaimed or
// claimed by a run that died longer than claimTTL ago).
func (s *store) pending(ctx context.Context, claimTTL time.Duration) (int, error) {
	var n int
	err := s.db.QueryRow(ctx, `SELECT count(*) FROM transcripts WHERE processed_at IS NULL
		AND (claimed_at IS NULL OR claimed_at < now() - $1::interval)`, claimTTL.String()).Scan(&n)
	return n, err
}

// claim takes up to limit pending transcripts (oldest first) for a run.
func (s *store) claim(ctx context.Context, run string, limit int, claimTTL time.Duration) ([]Transcript, error) {
	rows, err := s.db.Query(ctx, `
		UPDATE transcripts SET claimed_by = $1, claimed_at = now()
		WHERE id IN (
			SELECT id FROM transcripts WHERE processed_at IS NULL
				AND (claimed_at IS NULL OR claimed_at < now() - $3::interval)
			ORDER BY started_at LIMIT $2 FOR UPDATE SKIP LOCKED)
		RETURNING id, device, mode, started_at, ended_at, text, coalesce(language, '')`,
		run, limit, claimTTL.String())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Transcript
	for rows.Next() {
		var t Transcript
		if err := rows.Scan(&t.ID, &t.Device, &t.Mode, &t.StartedAt, &t.EndedAt, &t.Text, &t.Language); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// release gives claimed transcripts back (a run that won't finish them).
func (s *store) release(ctx context.Context, ids []string) error {
	_, err := s.db.Exec(ctx, `UPDATE transcripts SET claimed_by = NULL, claimed_at = NULL
		WHERE id = ANY($1::uuid[]) AND processed_at IS NULL`, ids)
	return err
}

func (s *store) processedCount(ctx context.Context, ids []string) (int, error) {
	var n int
	err := s.db.QueryRow(ctx, `SELECT count(*) FROM transcripts WHERE id = ANY($1::uuid[]) AND processed_at IS NOT NULL`, ids).Scan(&n)
	return n, err
}

// expire deletes transcripts older than the retention period (items keep
// their evidence text).
func (s *store) expire(ctx context.Context, days int) (int64, error) {
	if days <= 0 {
		return 0, nil
	}
	tag, err := s.db.Exec(ctx, `DELETE FROM transcripts WHERE started_at < now() - make_interval(days => $1)`, days)
	return tag.RowsAffected(), err
}

// ---- items ------------------------------------------------------------------

const itemCols = `i.id, i.kind, i.title, i.details, i.due_at, i.ends_at, i.status, i.evidence,
	i.created_at, i.updated_at, i.completed_at, i.created_by,
	coalesce((SELECT array_agg(transcript_id::text) FROM item_sources s WHERE s.item_id = i.id), '{}')`

func scanItem(row pgx.Row) (Item, error) {
	var it Item
	err := row.Scan(&it.ID, &it.Kind, &it.Title, &it.Details, &it.DueAt, &it.EndsAt, &it.Status, &it.Evidence,
		&it.CreatedAt, &it.UpdatedAt, &it.CompletedAt, &it.CreatedBy, &it.Sources)
	return it, err
}

func (s *store) listItems(ctx context.Context, status, kind string, limit int) ([]Item, error) {
	args := []any{}
	where := []string{}
	if status != "" && status != "all" {
		args = append(args, status)
		where = append(where, fmt.Sprintf("i.status = $%d", len(args)))
	}
	if kind != "" {
		args = append(args, kind)
		where = append(where, fmt.Sprintf("i.kind = $%d", len(args)))
	}
	if limit <= 0 || limit > 1000 {
		limit = 300
	}
	sql := "SELECT " + itemCols + " FROM items i"
	if len(where) > 0 {
		sql += " WHERE " + strings.Join(where, " AND ")
	}
	// open: soonest due first, undated after; otherwise newest first
	sql += fmt.Sprintf(` ORDER BY (i.status = 'open') DESC,
		CASE WHEN i.status = 'open' THEN i.due_at END ASC NULLS LAST,
		i.updated_at DESC LIMIT %d`, limit)
	rows, err := s.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Item{}
	for rows.Next() {
		it, err := scanItem(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

func (s *store) getItem(ctx context.Context, q interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, id int64) (Item, error) {
	return scanItem(q.QueryRow(ctx, "SELECT "+itemCols+" FROM items i WHERE i.id = $1", id))
}

type itemPatch struct {
	Status  *string    `json:"status"`
	Title   *string    `json:"title"`
	Details *string    `json:"details"`
	Kind    *string    `json:"kind"`
	DueAt   *time.Time `json:"due_at"`
	NoDue   bool       `json:"clear_due"`
}

// updateItemByUser applies a manual change.
func (s *store) updateItemByUser(ctx context.Context, id int64, p itemPatch) (Item, string, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Item{}, "", err
	}
	defer tx.Rollback(ctx)
	before, err := s.getItem(ctx, tx, id)
	if err != nil {
		return Item{}, "", err
	}
	action := "updated"
	if p.Status != nil && *p.Status != before.Status {
		switch *p.Status {
		case "done":
			action = "completed"
		case "dismissed":
			action = "dismissed"
		case "open":
			action = "reopened"
		}
	}
	_, err = tx.Exec(ctx, `UPDATE items SET
		status = coalesce($2, status),
		title = coalesce($3, title),
		details = coalesce($4, details),
		kind = coalesce($5, kind),
		due_at = CASE WHEN $7 THEN NULL ELSE coalesce($6, due_at) END,
		completed_at = CASE WHEN coalesce($2, status) = 'done' THEN coalesce(completed_at, now()) ELSE NULL END,
		updated_at = now()
		WHERE id = $1`, id, p.Status, p.Title, p.Details, p.Kind, p.DueAt, p.NoDue)
	if err != nil {
		return Item{}, "", err
	}
	detail, _ := json.Marshal(p)
	if _, err := tx.Exec(ctx, `INSERT INTO item_events (item_id, actor, action, detail) VALUES ($1, 'user', $2, $3)`, id, action, detail); err != nil {
		return Item{}, "", err
	}
	it, err := s.getItem(ctx, tx, id)
	if err != nil {
		return Item{}, "", err
	}
	return it, action, tx.Commit(ctx)
}

func (s *store) createItemByUser(ctx context.Context, it Item) (Item, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Item{}, err
	}
	defer tx.Rollback(ctx)
	var id int64
	if err := tx.QueryRow(ctx, `INSERT INTO items (kind, title, details, due_at, created_by)
		VALUES ($1, $2, $3, $4, 'user') RETURNING id`, it.Kind, it.Title, it.Details, it.DueAt).Scan(&id); err != nil {
		return Item{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO item_events (item_id, actor, action) VALUES ($1, 'user', 'created')`, id); err != nil {
		return Item{}, err
	}
	out, err := s.getItem(ctx, tx, id)
	if err != nil {
		return Item{}, err
	}
	return out, tx.Commit(ctx)
}

// openItemsForContext lists what the model should know is already tracked.
func (s *store) openItemsForContext(ctx context.Context, limit int) ([]Item, error) {
	return s.listItems(ctx, "open", "", limit)
}

// ---- runs -------------------------------------------------------------------

func (s *store) listRuns(ctx context.Context, limit int) ([]Run, error) {
	rows, err := s.db.Query(ctx, `SELECT id, started_at, finished_at, model, transcripts, items_created,
		items_updated, prompt_tokens, completion_tokens, error FROM runs ORDER BY finished_at DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Run{}
	for rows.Next() {
		var r Run
		if err := rows.Scan(&r.ID, &r.StartedAt, &r.FinishedAt, &r.Model, &r.Transcripts, &r.ItemsCreated,
			&r.ItemsUpdated, &r.PromptTokens, &r.CompletionTokens, &r.Error); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// applyResult stores a run's result in one transaction: items created or
// changed, transcripts marked processed, the run recorded. Applying the same
// run twice is a no-op (JetStream redelivery). Returns the item events to
// announce.
func (s *store) applyResult(ctx context.Context, r runResult) ([]itemEvent, error) {
	refs := map[string]string{}
	for k, v := range r.Refs {
		refs[k] = v
	}
	for _, id := range r.TranscriptIDs {
		refs[id] = id
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var seen bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM runs WHERE id = $1)`, r.RunID).Scan(&seen); err != nil {
		return nil, err
	}
	if seen {
		return nil, nil
	}
	var events []itemEvent
	created, updated := 0, 0
	if r.Error == "" {
		for _, a := range r.Actions {
			ev, err := applyAction(ctx, tx, s, r.RunID, a, refs)
			if err != nil {
				return nil, err
			}
			if ev == nil {
				continue
			}
			if ev.Action == "created" {
				created++
			} else {
				updated++
			}
			events = append(events, *ev)
		}
		if _, err := tx.Exec(ctx, `UPDATE transcripts SET processed_at = now() WHERE id = ANY($1::uuid[])`, r.TranscriptIDs); err != nil {
			return nil, err
		}
	} else {
		// a failed run gives its batch back for the next run
		if _, err := tx.Exec(ctx, `UPDATE transcripts SET claimed_by = NULL, claimed_at = NULL
			WHERE id = ANY($1::uuid[]) AND processed_at IS NULL`, r.TranscriptIDs); err != nil {
			return nil, err
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO runs (id, started_at, model, transcripts, items_created, items_updated,
		prompt_tokens, completion_tokens, error) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		r.RunID, r.StartedAt, r.Model, len(r.TranscriptIDs), created, updated, r.PromptTokens, r.CompletionTokens, r.Error); err != nil {
		return nil, err
	}
	return events, tx.Commit(ctx)
}

func applyAction(ctx context.Context, tx pgx.Tx, s *store, run string, a llmAction, refs map[string]string) (*itemEvent, error) {
	detail, _ := json.Marshal(a)
	switch a.Action {
	case "create":
		kind := strings.ToLower(a.Kind)
		if !itemKinds[kind] || strings.TrimSpace(a.Title) == "" {
			return nil, nil
		}
		var id int64
		err := tx.QueryRow(ctx, `INSERT INTO items (kind, title, details, due_at, ends_at, evidence)
			VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
			kind, clip(a.Title, 300), clip(a.Details, 4000), parseWhen(a.Due), parseWhen(a.Ends), clip(a.Evidence, 2000)).Scan(&id)
		if err != nil {
			return nil, err
		}
		for _, ref := range a.Transcripts {
			if tid, ok := refs[ref]; ok {
				if _, err := tx.Exec(ctx, `INSERT INTO item_sources VALUES ($1, $2) ON CONFLICT DO NOTHING`, id, tid); err != nil {
					return nil, err
				}
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO item_events (item_id, actor, action, run_id, detail) VALUES ($1, 'llm', 'created', $2, $3)`, id, run, detail); err != nil {
			return nil, err
		}
		it, err := s.getItem(ctx, tx, id)
		if err != nil {
			return nil, err
		}
		return &itemEvent{Item: it, Action: "created", RunID: run}, nil

	case "update", "complete", "dismiss":
		if a.ID <= 0 {
			return nil, nil
		}
		it, err := s.getItem(ctx, tx, a.ID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		if it.Status != "open" {
			return nil, nil // the model only touches open items; manual decisions stand
		}
		action := "updated"
		status := "open"
		switch a.Action {
		case "complete":
			action, status = "completed", "done"
		case "dismiss":
			action, status = "dismissed", "dismissed"
		}
		var title, details *string
		if t := strings.TrimSpace(a.Title); t != "" {
			t = clip(t, 300)
			title = &t
		}
		if d := strings.TrimSpace(a.Details); d != "" {
			d = clip(d, 4000)
			details = &d
		}
		_, err = tx.Exec(ctx, `UPDATE items SET status = $2, title = coalesce($3, title), details = coalesce($4, details),
			due_at = coalesce($5, due_at), ends_at = coalesce($6, ends_at),
			evidence = CASE WHEN $7 = '' THEN evidence WHEN evidence = '' THEN $7 ELSE evidence || E'\n' || $7 END,
			completed_at = CASE WHEN $2 = 'done' THEN now() ELSE completed_at END, updated_at = now()
			WHERE id = $1`, a.ID, status, title, details, parseWhen(a.Due), parseWhen(a.Ends), clip(a.Evidence, 2000))
		if err != nil {
			return nil, err
		}
		for _, ref := range a.Transcripts {
			if tid, ok := refs[ref]; ok {
				if _, err := tx.Exec(ctx, `INSERT INTO item_sources VALUES ($1, $2) ON CONFLICT DO NOTHING`, a.ID, tid); err != nil {
					return nil, err
				}
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO item_events (item_id, actor, action, run_id, detail) VALUES ($1, 'llm', $2, $3, $4)`, a.ID, action, run, detail); err != nil {
			return nil, err
		}
		it, err = s.getItem(ctx, tx, a.ID)
		if err != nil {
			return nil, err
		}
		return &itemEvent{Item: it, Action: action, RunID: run}, nil
	}
	return nil, nil
}

// parseWhen accepts RFC 3339, "YYYY-MM-DDTHH:MM" (local to the server's
// configured zone) or a bare date.
func parseWhen(s string) *time.Time {
	s = strings.TrimSpace(s)
	if s == "" || strings.EqualFold(s, "null") {
		return nil
	}
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05", "2006-01-02T15:04", "2006-01-02 15:04", "2006-01-02"} {
		var t time.Time
		var err error
		if layout == time.RFC3339 {
			t, err = time.Parse(layout, s)
		} else {
			t, err = time.ParseInLocation(layout, s, localZone)
		}
		if err == nil {
			return &t
		}
	}
	return nil
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len([]rune(s)) <= n {
		return s
	}
	return string([]rune(s)[:n])
}
