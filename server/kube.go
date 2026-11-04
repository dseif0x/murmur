package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net/http"
	"os"
	"time"
)

func kubeClient(caFile string) (*http.Client, error) {
	ca, err := os.ReadFile(caFile)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, errors.New("bad kubernetes CA")
	}
	return &http.Client{
		Timeout:   15 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}},
	}, nil
}
