// murmur turns what you say through the day into reminders, todos, events
// and notes. Devices transcribe speech on-device and send the text here;
// this binary is both the server (ingest API, web UI, storing results) and
// the worker (a Kubernetes CronJob that asks an LLM what needs doing).
//
//	murmur serve    the API + web UI + result consumer
//	murmur worker   one inference run (exits when done)
//	murmur migrate  apply database migrations and exit
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/nats-io/nats.go/jetstream"
)

var localZone = time.UTC

func env(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(k)); err == nil {
		return v
	}
	return def
}

func envDur(k string, def time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(k)); err == nil {
		return v
	}
	return def
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	if tz := env("TIMEZONE", env("TZ", "UTC")); tz != "" {
		if loc, err := time.LoadLocation(tz); err == nil {
			localZone = loc
		} else {
			log.Printf("unknown time zone %q, using UTC", tz)
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	dbURL := env("DATABASE_URL", "")
	if dbURL == "" {
		log.Fatal("DATABASE_URL is required")
	}
	pool, err := openDB(ctx, dbURL)
	if err != nil {
		log.Fatal(err)
	}
	defer pool.Close()
	if err := migrate(ctx, pool); err != nil {
		log.Fatal(err)
	}
	st := &store{db: pool}

	switch cmd {
	case "migrate":
		return
	case "worker":
		log.SetPrefix("worker: ")
		b, err := connectBus(ctx, env("NATS_URL", "nats://localhost:4222"))
		if err != nil {
			log.Fatal(err)
		}
		defer b.close()
		cfg := workerConfig{
			LLMBaseURL:      env("LLM_BASE_URL", "http://litellm.llama.svc.cluster.local:4000/v1"),
			LLMAPIKey:       env("LLM_API_KEY", ""),
			Model:           env("LLM_MODEL", "qwen3.8-flash-next-iq3"),
			OutputLanguage:  env("OUTPUT_LANGUAGE", ""),
			MaxChars:        envInt("MAX_CHARS_PER_CALL", 24000),
			MaxTranscripts:  envInt("MAX_TRANSCRIPTS_PER_RUN", 1000),
			ClaimTTL:        envDur("CLAIM_TTL", 2*time.Hour),
			LLMTimeout:      envDur("LLM_TIMEOUT", 15*time.Minute),
			ApplyTimeout:    envDur("APPLY_TIMEOUT", 2*time.Minute),
			OpenItemsInCtx:  envInt("OPEN_ITEMS_IN_CONTEXT", 150),
			ExtraPrompt:     env("EXTRA_PROMPT", ""),
			DisableThinking: env("LLM_DISABLE_THINKING", "false") == "true",
		}
		if err := runWorker(ctx, st, b, cfg); err != nil {
			log.Fatal(err)
		}
	case "serve":
		serve(ctx, st)
	default:
		log.Fatalf("unknown command %q (serve, worker, migrate)", cmd)
	}
}

func serve(ctx context.Context, st *store) {
	b, err := connectBus(ctx, env("NATS_URL", "nats://localhost:4222"))
	if err != nil {
		log.Fatal(err)
	}
	defer b.close()

	tokens := map[string]string{}
	for i, t := range strings.FieldsFunc(env("INGEST_TOKENS", ""), func(r rune) bool { return r == ',' || r == '\n' }) {
		if t = strings.TrimSpace(t); t != "" {
			tokens[t] = fmt.Sprintf("token%d", i+1)
		}
	}
	if len(tokens) == 0 {
		log.Print("warning: INGEST_TOKENS is empty, devices can't upload")
	}
	s := &server{st: st, bus: b, tokens: tokens, static: env("STATIC_DIR", "./static"), retainDs: envInt("RETENTION_DAYS", 30)}
	if cj := env("WORKER_CRONJOB", ""); cj != "" {
		s.runNow = func(ctx context.Context) (string, error) { return createJobFromCronJob(ctx, cj) }
	}

	go consumeResults(ctx, st, b)
	go retentionLoop(ctx, st, s.retainDs)

	addr := ":" + env("PORT", "8080")
	srv := &http.Server{Addr: addr, Handler: s.routes(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(sctx)
	}()
	log.Printf("murmur listening on %s (time zone %s, retention %d days)", addr, localZone, s.retainDs)
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

// consumeResults stores worker results from murmur.results (durable, so
// results published while the server was down are stored when it's back).
func consumeResults(ctx context.Context, st *store, b *bus) {
	cons, err := b.js.CreateOrUpdateConsumer(ctx, streamName, jetstream.ConsumerConfig{
		Durable:       resultsConsumer,
		FilterSubject: subjResults,
		AckPolicy:     jetstream.AckExplicitPolicy,
		AckWait:       time.Minute,
		MaxDeliver:    20,
	})
	if err != nil {
		log.Fatalf("results consumer: %v", err)
	}
	cc, err := cons.Consume(func(m jetstream.Msg) {
		var r runResult
		if err := json.Unmarshal(m.Data(), &r); err != nil {
			log.Printf("bad result message: %v", err)
			m.Term()
			return
		}
		events, err := st.applyResult(ctx, r)
		if err != nil {
			log.Printf("storing run %s: %v", r.RunID, err)
			m.NakWithDelay(10 * time.Second)
			return
		}
		m.Ack()
		log.Printf("run %s stored: %d transcripts, %d item changes%s", r.RunID, len(r.TranscriptIDs), len(events), errSuffix(r.Error))
		for _, ev := range events {
			subj := subjItemsUpdated
			if ev.Action == "created" {
				subj = subjItemsCreated
			}
			if err := b.publish(ctx, subj, ev); err != nil {
				log.Printf("publish %s: %v", subj, err)
			}
		}
	})
	if err != nil {
		log.Fatalf("results consumer: %v", err)
	}
	<-ctx.Done()
	cc.Stop()
}

func errSuffix(e string) string {
	if e == "" {
		return ""
	}
	return " (failed: " + e + ")"
}

func retentionLoop(ctx context.Context, st *store, days int) {
	if days <= 0 {
		return
	}
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		if n, err := st.expire(ctx, days); err != nil {
			log.Printf("retention: %v", err)
		} else if n > 0 {
			log.Printf("retention: deleted %d transcripts older than %d days", n, days)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// createJobFromCronJob starts the worker now: a Job from the CronJob's
// template, like `kubectl create job --from=cronjob/...`. Uses the pod's
// service account (the chart grants get cronjobs + create jobs).
func createJobFromCronJob(ctx context.Context, name string) (string, error) {
	const saDir = "/var/run/secrets/kubernetes.io/serviceaccount/"
	token, err := os.ReadFile(saDir + "token")
	if err != nil {
		return "", fmt.Errorf("no service account: %w", err)
	}
	ns, _ := os.ReadFile(saDir + "namespace")
	host := "https://" + os.Getenv("KUBERNETES_SERVICE_HOST") + ":" + os.Getenv("KUBERNETES_SERVICE_PORT")
	client, err := kubeClient(saDir + "ca.crt")
	if err != nil {
		return "", err
	}
	do := func(method, path string, body any, out any) error {
		var rd io.Reader
		if body != nil {
			data, _ := json.Marshal(body)
			rd = bytes.NewReader(data)
		}
		req, err := http.NewRequestWithContext(ctx, method, host+path, rd)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		data, _ := io.ReadAll(resp.Body)
		if resp.StatusCode/100 != 2 {
			return fmt.Errorf("kubernetes %s %s: %s %s", method, path, resp.Status, clip(string(data), 300))
		}
		if out != nil {
			return json.Unmarshal(data, out)
		}
		return nil
	}
	var cj struct {
		Spec struct {
			JobTemplate struct {
				Metadata map[string]any `json:"metadata"`
				Spec     map[string]any `json:"spec"`
			} `json:"jobTemplate"`
		} `json:"spec"`
	}
	nsS := strings.TrimSpace(string(ns))
	if err := do("GET", "/apis/batch/v1/namespaces/"+nsS+"/cronjobs/"+name, nil, &cj); err != nil {
		return "", err
	}
	jobName := fmt.Sprintf("%s-manual-%d", name, time.Now().Unix())
	if len(jobName) > 63 {
		jobName = jobName[len(jobName)-63:]
	}
	job := map[string]any{
		"apiVersion": "batch/v1",
		"kind":       "Job",
		"metadata": map[string]any{
			"name":        jobName,
			"labels":      map[string]string{"app.kubernetes.io/component": "worker", "murmur/trigger": "manual"},
			"annotations": map[string]string{"cronjob.kubernetes.io/instantiate": "manual"},
		},
		"spec": cj.Spec.JobTemplate.Spec,
	}
	if err := do("POST", "/apis/batch/v1/namespaces/"+nsS+"/jobs", job, nil); err != nil {
		return "", err
	}
	return jobName, nil
}
