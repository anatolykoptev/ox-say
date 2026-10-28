package daemon

import (
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

var routeLiteral = regexp.MustCompile(`^(GET|POST|PUT|PATCH|DELETE) (/\S*)$`)

// registeredGETPatterns lists every `GET /path` pattern the daemon registers, read from the package's non-test
// source (the string literals of every registration site, interactiveRoutes included) and then confirmed against
// the mux d.Routes really builds: a literal the mux does not resolve to itself is not a route and is dropped. A
// route added next month is found here without anyone editing a list.
func registeredGETPatterns(t *testing.T, d *Daemon) []string {
	t.Helper()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	d.Routes(mux)
	seen := map[string]bool{}
	fset := token.NewFileSet()
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(file, func(n ast.Node) bool {
			lit, ok := n.(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			s, err := strconv.Unquote(lit.Value)
			if err != nil {
				return true
			}
			m := routeLiteral.FindStringSubmatch(s)
			if m == nil || m[1] != "GET" {
				return true
			}
			req := httptest.NewRequest("GET", sampleRoutePath(m[2]), nil)
			if _, got := mux.Handler(req); got == s {
				seen[s] = true
			}
			return true
		})
	}
	var out []string
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

var wildcard = regexp.MustCompile(`\{[^}]*\}`)

func sampleRoutePath(pattern string) string {
	return wildcard.ReplaceAllString(pattern, "x1")
}

// A web page can send a blind GET to the loopback daemon (`<audio src=http://127.0.0.1:PORT/v1/...>`), and
// http.CrossOriginProtection lets GET through. Guard refuses a read the browser marks cross-site or same-site on
// EVERY route, not on a list of prefixes: the routes are derived from the registration, so a new read is covered
// the day it is added. The app (no Sec-Fetch-Site), a typed address (none) and the daemon's own pages
// (same-origin) still pass.
// Mutation: internal/daemon/guard.go crossSiteRead, restore the `/v1/meetings` prefix test -> RED on a voices route.
func TestGuardRefusesCrossSiteReadOnEveryRegisteredRoute(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	h := servedFor(t, d)
	patterns := registeredGETPatterns(t, d)
	// the derivation itself must see the families it is meant to cover
	for _, want := range []string{"GET /v1/audio/voices", "GET /v1/audio/voices/{name}", "GET /v1/produce/{id}", "GET /v1/meetings/{id}/audio", "GET /status"} {
		found := false
		for _, p := range patterns {
			found = found || p == want
		}
		if !found {
			t.Fatalf("route derivation missed %q (got %v)", want, patterns)
		}
	}
	for _, p := range patterns {
		path := sampleRoutePath(strings.TrimPrefix(p, "GET "))
		for _, method := range []string{"GET", "HEAD"} {
			for _, site := range []string{"cross-site", "same-site"} {
				req := httptest.NewRequest(method, "http://127.0.0.1:8094"+path, nil)
				req.Header.Set("Sec-Fetch-Site", site)
				if rec := serve(h, req); rec.Code != http.StatusForbidden {
					t.Errorf("%s %s with Sec-Fetch-Site %s = %d, want 403", method, path, site, rec.Code)
				}
			}
		}
		for _, site := range []string{"", "none", "same-origin"} {
			req := httptest.NewRequest("GET", "http://127.0.0.1:8094"+path, nil)
			if site != "" {
				req.Header.Set("Sec-Fetch-Site", site)
			}
			if rec := serve(h, req); rec.Code == http.StatusForbidden {
				t.Errorf("GET %s with Sec-Fetch-Site %q = 403: %s", path, site, rec.Body)
			}
		}
	}
}

// /health carries nothing of the user's and stays readable for a liveness probe whatever the browser says.
func TestGuardLeavesHealthReadable(t *testing.T) {
	h := Guard(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) }))
	req := httptest.NewRequest("GET", "http://127.0.0.1:8094/health", nil)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	if rec := serve(h, req); rec.Code != http.StatusOK {
		t.Errorf("/health cross-site = %d, want 200", rec.Code)
	}
}
