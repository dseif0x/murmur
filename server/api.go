package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type server struct {
	st       *store
	bus      *bus
	tokens   map[string]string // token -> name (ingest)
	static   string
	runNow   func(ctx context.Context) (string, error)
	retainDs int
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	// devices (bearer token)
	mux.HandleFunc("POST /v1/transcripts", s.auth(s.handleIngest))
	mux.HandleFunc("GET /v1/ping", s.auth(func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]bool{"ok": true}) }))
	// web UI (runs behind the cluster's login)
	mux.HandleFunc("GET /api/transcripts", s.handleTranscripts)
	mux.HandleFunc("GET /api/days", s.handleDays)
	mux.HandleFunc("GET /api/items", s.handleItems)
	mux.HandleFunc("POST /api/items", s.handleCreateItem)
	mux.HandleFunc("PATCH /api/items/{id}", s.handlePatchItem)
	mux.HandleFunc("GET /api/runs", s.handleRuns)
	mux.HandleFunc("POST /api/runs", s.handleRunNow)
	mux.HandleFunc("GET /api/status", s.handleStatus)
	mux.HandleFunc("GET /", s.handleStatic)
	return mux
}

func (s *server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || !s.validToken(strings.TrimSpace(tok)) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid token"})
			return
		}
		next(w, r)
	}
}

func (s *server) validToken(tok string) bool {
	if tok == "" {
		return false
	}
	ok := false
	for t := range s.tokens {
		if subtle.ConstantTimeCompare([]byte(t), []byte(tok)) == 1 {
			ok = true
		}
	}
	return ok
}

type ingestRequest struct {
	Device   string `json:"device"`
	Segments []struct {
		ID        string    `json:"id"`
		Text      string    `json:"text"`
		StartedAt time.Time `json:"started_at"`
		EndedAt   time.Time `json:"ended_at"`
		Language  string    `json:"language"`
		Mode      string    `json:"mode"`
	} `json:"segments"`
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (s *server) handleIngest(w http.ResponseWriter, r *http.Request) {
	var req ingestRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	device := clip(req.Device, 64)
	if device == "" {
		device = "unknown"
	}
	var ts []Transcript
	for _, seg := range req.Segments {
		text := strings.TrimSpace(seg.Text)
		if !uuidRe.MatchString(seg.ID) || text == "" || seg.StartedAt.IsZero() {
			continue
		}
		if seg.EndedAt.Before(seg.StartedAt) {
			seg.EndedAt = seg.StartedAt
		}
		mode := seg.Mode
		if mode != "ptt" {
			mode = "always"
		}
		ts = append(ts, Transcript{ID: strings.ToLower(seg.ID), Device: device, Mode: mode, StartedAt: seg.StartedAt,
			EndedAt: seg.EndedAt, Text: clip(text, 20000), Language: clip(seg.Language, 16)})
	}
	added, err := s.st.insertTranscripts(r.Context(), ts)
	if err != nil {
		writeError(w, err)
		return
	}
	if len(added) > 0 && s.bus != nil {
		if err := s.bus.publish(r.Context(), subjTranscripts, transcriptsCreated{Device: device, IDs: added}); err != nil {
			log.Printf("publish %s: %v", subjTranscripts, err)
		}
	}
	// every segment the device sent is now stored (new or from before)
	writeJSON(w, http.StatusOK, map[string]int{"received": len(ts), "added": len(added)})
}

func parseTime(s string) time.Time {
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t
	}
	if t, err := time.ParseInLocation("2006-01-02", s, localZone); err == nil {
		return t
	}
	return time.Time{}
}

func (s *server) handleTranscripts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	tq := transcriptQuery{From: parseTime(q.Get("from")), To: parseTime(q.Get("to")), Search: strings.TrimSpace(q.Get("q")), Device: q.Get("device")}
	if day := q.Get("day"); day != "" {
		if d := parseTime(day); !d.IsZero() {
			tq.From, tq.To = d, d.AddDate(0, 0, 1)
		}
	}
	if id := q.Get("id"); uuidRe.MatchString(id) {
		tq.ID = id
	}
	tq.Limit, _ = strconv.Atoi(q.Get("limit"))
	out, err := s.st.listTranscripts(r.Context(), tq)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) handleDays(w http.ResponseWriter, r *http.Request) {
	out, err := s.st.days(r.Context(), localZone.String())
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) handleItems(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	status := q.Get("status")
	if status != "" && status != "all" && !itemStates[status] {
		status = "open"
	}
	if status == "" {
		status = "open"
	}
	kind := q.Get("kind")
	if kind != "" && !itemKinds[kind] {
		kind = ""
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	out, err := s.st.listItems(r.Context(), status, kind, limit)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) handleCreateItem(w http.ResponseWriter, r *http.Request) {
	var in Item
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	in.Title = clip(in.Title, 300)
	in.Details = clip(in.Details, 4000)
	if !itemKinds[in.Kind] || in.Title == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "kind and title required"})
		return
	}
	it, err := s.st.createItemByUser(r.Context(), in)
	if err != nil {
		writeError(w, err)
		return
	}
	s.announce(r.Context(), itemEvent{Item: it, Action: "created"})
	writeJSON(w, http.StatusOK, it)
}

func (s *server) handlePatchItem(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad id"})
		return
	}
	var p itemPatch
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&p); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if p.Status != nil && !itemStates[*p.Status] || p.Kind != nil && !itemKinds[*p.Kind] || p.Title != nil && strings.TrimSpace(*p.Title) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid change"})
		return
	}
	it, action, err := s.st.updateItemByUser(r.Context(), id, p)
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no such item"})
		return
	}
	if err != nil {
		writeError(w, err)
		return
	}
	s.announce(r.Context(), itemEvent{Item: it, Action: action})
	writeJSON(w, http.StatusOK, it)
}

func (s *server) announce(ctx context.Context, ev itemEvent) {
	if s.bus == nil {
		return
	}
	subj := subjItemsUpdated
	if ev.Action == "created" {
		subj = subjItemsCreated
	}
	if err := s.bus.publish(ctx, subj, ev); err != nil {
		log.Printf("publish %s: %v", subj, err)
	}
}

func (s *server) handleRuns(w http.ResponseWriter, r *http.Request) {
	out, err := s.st.listRuns(r.Context(), 50)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) handleRunNow(w http.ResponseWriter, r *http.Request) {
	if s.runNow == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "starting runs from the UI is not enabled"})
		return
	}
	name, err := s.runNow(r.Context())
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"job": name})
}

func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	pending, err := s.st.pending(r.Context(), 2*time.Hour)
	if err != nil {
		writeError(w, err)
		return
	}
	devices, err := s.st.devices(r.Context())
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"pending": pending, "devices": devices, "timezone": localZone.String(),
		"retention_days": s.retainDs, "run_now": s.runNow != nil,
	})
}

func (s *server) handleStatic(w http.ResponseWriter, r *http.Request) {
	p := filepath.Join(s.static, filepath.FromSlash(filepath.Clean("/"+r.URL.Path)))
	if st, err := os.Stat(p); err != nil || st.IsDir() {
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFile(w, r, filepath.Join(s.static, "index.html"))
		return
	}
	if strings.HasPrefix(r.URL.Path, "/assets/") {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	}
	http.ServeFile(w, r, p)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, err error) {
	log.Printf("error: %v", err)
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
}
