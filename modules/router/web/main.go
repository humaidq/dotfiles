package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"
)

func main() {
	root := flag.String("root", ".", "directory containing static files")
	addr := flag.String("addr", ":80", "listen address")
	flag.Parse()

	staticRoot, err := filepath.Abs(*root)
	if err != nil {
		log.Fatalf("resolve static root: %v", err)
	}

	indexPath := filepath.Join(staticRoot, "index.html")
	if _, err := os.Stat(indexPath); err != nil {
		log.Fatalf("missing index.html in %s: %v", staticRoot, err)
	}

	handler := http.FileServer(http.Dir(staticRoot))

	server := &http.Server{
		Addr:    *addr,
		Handler: handler,
	}

	log.Printf("serving %s on http://%s", staticRoot, *addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server failed: %v", err)
	}
}
