package daemon

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// http.CrossOriginProtection lets GET through, so a web page could ask the loopback daemon about a meeting (an
// <audio> element on /v1/meetings/<id>/audio tells whether it exists and how long it is, and makes the daemon work).
// Guard refuses a meetings read the browser marks cross-site or same-site; the app's URLSession, AVPlayer and the MCP
// clients send no Sec-Fetch-Site, a page of the daemon's own origin sends same-origin, and a typed address sends none.
// Mutation: internal/daemon/guard.go Guard, delete the `crossSiteRead(r)` branch -> RED.
func TestGuardRefusesCrossSiteMeetingReads(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	h := servedFor(t, d)
	m, _ := audioMeeting(t, d, []int16{1, 2}, []int16{3, 4})
	paths := []string{
		"/v1/meetings", "/v1/meetings/" + m.ID, "/v1/meetings/search?q=audio", "/v1/meetings/" + m.ID + "/audio",
		"/v1/meetings/" + m.ID + "/speakers", "/v1/meetings/settings",
	}
	get := func(path, site string) *httptest.ResponseRecorder {
		req := httptest.NewRequest("GET", "http://127.0.0.1:8094"+path, nil)
		if site != "" {
			req.Header.Set("Sec-Fetch-Site", site)
		}
		return serve(h, req)
	}
	for _, p := range paths {
		for _, site := range []string{"cross-site", "same-site"} {
			if rec := get(p, site); rec.Code != http.StatusForbidden {
				t.Errorf("GET %s with Sec-Fetch-Site %s = %d, want 403", p, site, rec.Code)
			}
		}
		for _, site := range []string{"", "none", "same-origin"} {
			if rec := get(p, site); rec.Code == http.StatusForbidden {
				t.Errorf("GET %s with Sec-Fetch-Site %q = 403: %s", p, site, rec.Body)
			}
		}
	}
	// the audio itself still plays for the app
	if rec := get(paths[3], "none"); rec.Code != http.StatusOK || rec.Body.Len() == 0 {
		t.Errorf("audio with none = %d", rec.Code)
	}
	// HEAD asks the same question as GET
	req := httptest.NewRequest("HEAD", "http://127.0.0.1:8094"+paths[3], nil)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	if rec := serve(h, req); rec.Code != http.StatusForbidden {
		t.Errorf("HEAD cross-site = %d", rec.Code)
	}
}
