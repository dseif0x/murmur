package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// NATS JetStream carries murmur's events. One stream, MURMUR, holds every
// subject under murmur.>:
//
//	murmur.transcripts.created  ingest stored new transcripts
//	murmur.results              a worker run's inference result; the server
//	                            stores it (durable consumer "store-results")
//	murmur.items.created        an item appeared   (for integrations)
//	murmur.items.updated        an item changed    (for integrations)
const (
	streamName       = "MURMUR"
	subjTranscripts  = "murmur.transcripts.created"
	subjResults      = "murmur.results"
	subjItemsCreated = "murmur.items.created"
	subjItemsUpdated = "murmur.items.updated"
	resultsConsumer  = "store-results"
)

type bus struct {
	nc *nats.Conn
	js jetstream.JetStream
}

func connectBus(ctx context.Context, url string) (*bus, error) {
	nc, err := nats.Connect(url, nats.Name("murmur"), nats.MaxReconnects(-1), nats.ReconnectWait(2*time.Second), nats.RetryOnFailedConnect(true))
	if err != nil {
		return nil, fmt.Errorf("nats: %w", err)
	}
	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, err
	}
	// the server may come up together with us: retry for two minutes
	deadline := time.Now().Add(2 * time.Minute)
	for {
		_, err = js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
			Name:      streamName,
			Subjects:  []string{"murmur.>"},
			Storage:   jetstream.FileStorage,
			Retention: jetstream.LimitsPolicy,
			MaxAge:    14 * 24 * time.Hour,
			MaxBytes:  256 << 20,
		})
		if err == nil {
			break
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			nc.Close()
			return nil, fmt.Errorf("nats stream: %w", err)
		}
		time.Sleep(3 * time.Second)
	}
	return &bus{nc: nc, js: js}, nil
}

func (b *bus) close() {
	if b != nil {
		b.nc.Drain()
	}
}

func (b *bus) publish(ctx context.Context, subject string, v any) error {
	if b == nil {
		return errors.New("no nats connection")
	}
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = b.js.Publish(ctx, subject, data)
	return err
}

// ---- messages ---------------------------------------------------------------

type transcriptsCreated struct {
	Device string   `json:"device"`
	IDs    []string `json:"ids"`
}

// runResult is what a worker run publishes on murmur.results.
type runResult struct {
	RunID            string            `json:"run_id"`
	StartedAt        time.Time         `json:"started_at"`
	Model            string            `json:"model"`
	TranscriptIDs    []string          `json:"transcript_ids"`
	Refs             map[string]string `json:"refs"` // short ref in the prompt (t1) -> transcript id
	Actions          []llmAction       `json:"actions"`
	PromptTokens     int               `json:"prompt_tokens"`
	CompletionTokens int               `json:"completion_tokens"`
	Error            string            `json:"error,omitempty"`
}

// llmAction is one thing the model wants done.
type llmAction struct {
	Action      string   `json:"action"` // create | update | complete | dismiss
	ID          int64    `json:"id,omitempty"`
	Kind        string   `json:"kind,omitempty"` // reminder | todo | note | event
	Title       string   `json:"title,omitempty"`
	Details     string   `json:"details,omitempty"`
	Due         string   `json:"due,omitempty"` // RFC 3339 or YYYY-MM-DD
	Ends        string   `json:"ends,omitempty"`
	Evidence    string   `json:"evidence,omitempty"`
	Transcripts []string `json:"transcripts,omitempty"` // short refs (t1, t2, ...) or ids
}

type itemEvent struct {
	Item   Item   `json:"item"`
	Action string `json:"action"`
	RunID  string `json:"run_id,omitempty"`
}
