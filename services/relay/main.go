// Proximus relay stores opaque ciphertext only. Run behind TLS on a dedicated host.
package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"proximus.local/passwords/services/internal/securehttp"
)

const maxObject = 12 * 1024 * 1024
const maxVaultBytes int64 = 256 * 1024 * 1024

var vaultPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type relay struct {
	root, enrollment string
	mu               sync.Mutex
}

func (s *relay) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/healthz" && r.Method == "GET" {
		w.WriteHeader(204)
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/"), "/")
	if len(parts) < 3 || parts[0] != "v1" || parts[1] != "vaults" || !vaultPattern.MatchString(parts[2]) {
		http.NotFound(w, r)
		return
	}
	token, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if err != nil || len(token) != 32 || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		http.Error(w, "unauthorized", 401)
		return
	}
	digest := sha256.Sum256(token)
	dir := filepath.Join(s.root, parts[2])
	s.mu.Lock()
	defer s.mu.Unlock()
	stored, err := os.ReadFile(filepath.Join(dir, "auth"))
	if len(parts) == 3 && r.Method == "PUT" && errors.Is(err, os.ErrNotExist) {
		provided := sha256.Sum256([]byte(r.Header.Get("X-Enrollment-Key")))
		expected := sha256.Sum256([]byte(s.enrollment))
		if len(s.enrollment) < 32 || subtle.ConstantTimeCompare(provided[:], expected[:]) != 1 {
			http.Error(w, "enrollment denied", 403)
			return
		}
		entries, readErr := os.ReadDir(s.root)
		if readErr != nil || len(entries) >= 100 {
			http.Error(w, "vault capacity reached", 507)
			return
		}
		if err := os.Mkdir(dir, 0700); err != nil {
			http.Error(w, "storage unavailable", 500)
			return
		}
		if err := os.Mkdir(filepath.Join(dir, "objects"), 0700); err != nil {
			_ = os.RemoveAll(dir)
			http.Error(w, "storage unavailable", 500)
			return
		}
		if err := securehttp.AtomicFile(filepath.Join(dir, "auth"), digest[:]); err != nil {
			_ = os.RemoveAll(dir)
			http.Error(w, "storage unavailable", 500)
			return
		}
		w.WriteHeader(201)
		return
	}
	if err != nil || subtle.ConstantTimeCompare(stored, digest[:]) != 1 {
		http.Error(w, "unauthorized", 401)
		return
	}
	if len(parts) == 3 && r.Method == "PUT" {
		w.WriteHeader(204)
		return
	}
	if len(parts) == 4 && parts[3] == "head" {
		current, err := os.ReadFile(filepath.Join(dir, "head"))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			http.Error(w, "storage unavailable", 500)
			return
		}
		if r.Method == "GET" {
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write(current)
			return
		}
		if r.Method == "PUT" {
			if r.Header.Get("If-Match") != `"`+string(current)+`"` {
				http.Error(w, "head changed", 409)
				return
			}
			body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64))
			if err != nil || !hashPattern.Match(body) {
				http.Error(w, "invalid hash", 400)
				return
			}
			if _, err := os.Stat(filepath.Join(dir, "objects", string(body))); err != nil {
				http.Error(w, "object missing", 400)
				return
			}
			if err := securehttp.AtomicFile(filepath.Join(dir, "head"), body); err != nil {
				http.Error(w, "storage unavailable", 500)
				return
			}
			w.WriteHeader(204)
			return
		}
	}
	if len(parts) == 5 && parts[3] == "objects" && hashPattern.MatchString(parts[4]) {
		path := filepath.Join(dir, "objects", parts[4])
		if r.Method == "GET" {
			f, err := os.Open(path)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			defer f.Close()
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = io.Copy(w, io.LimitReader(f, maxObject))
			return
		}
		if r.Method == "PUT" {
			body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxObject))
			digest := sha256.Sum256(body)
			if err != nil || hex.EncodeToString(digest[:]) != parts[4] {
				http.Error(w, "invalid object", 400)
				return
			}
			if _, err := os.Stat(path); err == nil {
				w.WriteHeader(204)
				return
			}
			entries, err := os.ReadDir(filepath.Join(dir, "objects"))
			if err != nil {
				http.Error(w, "storage unavailable", 500)
				return
			}
			var total int64
			for _, entry := range entries {
				info, err := entry.Info()
				if err != nil {
					http.Error(w, "storage unavailable", 500)
					return
				}
				total += info.Size()
			}
			if total+int64(len(body)) > maxVaultBytes || len(entries) >= 10000 {
				http.Error(w, "vault quota reached", 507)
				return
			}
			if err := securehttp.AtomicFile(path, body); err != nil {
				http.Error(w, "storage unavailable", 500)
				return
			}
			w.WriteHeader(201)
			return
		}
	}
	w.Header().Set("Allow", "GET, PUT")
	http.Error(w, "unsupported request", 405)
}

func main() {
	root := securehttp.Env("PROXIMUS_DATA", "./data/relay")
	lock, err := securehttp.LockDirectory(root)
	if err != nil {
		log.Fatal("relay data directory is unavailable or already in use")
	}
	defer lock.Close()
	if err := os.MkdirAll(root, 0700); err != nil {
		log.Fatal("cannot create relay data directory")
	}
	s := &relay{root: root, enrollment: os.Getenv("PROXIMUS_ENROLLMENT_KEY")}
	address := securehttp.Env("PROXIMUS_LISTEN", "127.0.0.1:8088")
	log.Printf("Proximus ciphertext relay listening on %s", address)
	log.Fatal(securehttp.Server(address, securehttp.Harden(s, 2400)).ListenAndServe())
}
