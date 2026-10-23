package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestAuthenticatedImmutableObjectsAndHeadCAS(t *testing.T) {
	s := &relay{root: t.TempDir(), enrollment: strings.Repeat("e", 32)}
	token := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	path := "/v1/vaults/00000000-0000-4000-8000-000000000001"
	call := func(method, url, body, auth, match, enroll string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, url, strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+auth)
		if match != "" {
			r.Header.Set("If-Match", match)
		}
		r.Header.Set("X-Enrollment-Key", enroll)
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		return w
	}
	if got := call("PUT", path, "", token, "", "").Code; got != 403 {
		t.Fatalf("unapproved enrollment: %d", got)
	}
	if got := call("PUT", path, "", token, "", s.enrollment).Code; got != 201 {
		t.Fatalf("create: %d", got)
	}
	if got := call("GET", path+"/head", "", base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32)), "", "").Code; got != 401 {
		t.Fatalf("wrong token: %d", got)
	}
	body := "opaque encrypted snapshot"
	digest := sha256.Sum256([]byte(body))
	hash := hex.EncodeToString(digest[:])
	if got := call("PUT", path+"/objects/"+hash, "tampered", token, "", "").Code; got != 400 {
		t.Fatalf("bad hash: %d", got)
	}
	if got := call("PUT", path+"/objects/"+hash, body, token, "", "").Code; got != 201 {
		t.Fatalf("upload: %d", got)
	}
	if got := call("PUT", path+"/head", hash, token, "", "").Code; got != 409 {
		t.Fatalf("missing CAS: %d", got)
	}
	var wg sync.WaitGroup
	codes := make(chan int, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); codes <- call("PUT", path+"/head", hash, token, `""`, "").Code }()
	}
	wg.Wait()
	close(codes)
	counts := map[int]int{}
	for code := range codes {
		counts[code]++
	}
	if counts[204] != 1 || counts[409] != 1 {
		t.Fatalf("CAS results: %v", counts)
	}
	if got := call("GET", path+"/head", "", token, "", "").Body.String(); got != hash {
		t.Fatalf("head: %q", got)
	}
	if got := call("GET", path+"/objects/"+hash, "", token, "", "").Body.String(); got != body {
		t.Fatalf("object: %q", got)
	}
	if got := call("GET", path+"/objects/../../auth", "", token, "", "").Code; got == 200 {
		t.Fatal("path traversal accepted")
	}
}
