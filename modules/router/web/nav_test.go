package main

import (
	"html/template"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// The stylesheet is linked by every page, and the mesh listener is what answers
// when the LAN is the thing that is broken — so it has to be on both.
func TestStylesheetIsServedOnBothListeners(t *testing.T) {
	tmpl := template.Must(template.New("index").Parse("landing"))
	muxes := map[string]http.Handler{
		"lan":  landingMux(pageData{}, tmpl, nil, navSource{}),
		"mesh": meshMux(pageData{}, tmpl, nil, testPeersServer(t), navSource{}),
	}
	for name, mux := range muxes {
		t.Run(name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/style.css", nil))
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200", rec.Code)
			}
			if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/css") {
				t.Fatalf("content type = %q, want text/css", ct)
			}
			if !strings.Contains(rec.Body.String(), "--accent") {
				t.Fatal("body does not look like the stylesheet")
			}
		})
	}
}

// The stylesheet is embedded rather than read from the static root, so it
// cannot go missing on a router where the install dropped a file.
func TestStylesheetIsEmbeddedNotReadFromDisk(t *testing.T) {
	if !strings.Contains(stylesheet, ".topbar") {
		t.Fatal("the embedded stylesheet is empty or wrong")
	}
}

func renderNav(t *testing.T, nav navData) string {
	t.Helper()
	tmpl, err := template.ParseFiles("nav.html")
	if err != nil {
		t.Fatalf("parse nav.html: %v", err)
	}
	var out strings.Builder
	if err := tmpl.ExecuteTemplate(&out, "nav", nav); err != nil {
		t.Fatalf("execute nav: %v", err)
	}
	return out.String()
}

func TestNavOnlyLinksSectionsThatExist(t *testing.T) {
	// A link that 404s is worse than one that is absent: a gap reads as a
	// feature this router does not have, a 404 reads as a broken router.
	bare := renderNav(t, navData{Host: "bingo", State: stateUnknown, Active: "status"})
	if strings.Contains(bare, `href="/uplink"`) {
		t.Fatal("offered /uplink with no probing configured")
	}
	if strings.Contains(bare, `href="/peers"`) {
		t.Fatal("offered /peers on a listener that does not serve it")
	}

	full := renderNav(t, navData{
		Host: "bingo", State: stateOK, Active: "devices",
		ShowUplink: true, ShowPeers: true,
	})
	for _, want := range []string{`href="/uplink"`, `href="/peers"`} {
		if !strings.Contains(full, want) {
			t.Fatalf("missing %s", want)
		}
	}
}

func TestNavMarksExactlyOneCurrentSection(t *testing.T) {
	for _, active := range []string{"status", "uplink", "devices"} {
		body := renderNav(t, navData{
			Host: "bingo", State: stateOK, Active: active,
			ShowUplink: true, ShowPeers: true,
		})
		if got := strings.Count(body, `aria-current="page"`); got != 1 {
			t.Fatalf("active %q marked %d entries current, want 1", active, got)
		}
	}
}

func TestNavLampCarriesTheUplinkState(t *testing.T) {
	body := renderNav(t, navData{Host: "bingo", State: stateDown, StateText: "link down"})
	if !strings.Contains(body, "lamp lamp-down") {
		t.Fatalf("lamp does not carry the state:\n%s", body)
	}
	// The lamp is a colour, so the state is also stated in text for a reader
	// who cannot see it.
	if !strings.Contains(body, `<span class="sr-only">Uplink: link down.</span>`) {
		t.Fatalf("state is not available as text:\n%s", body)
	}
}

func TestNavSourceReportsUnknownWithoutProbing(t *testing.T) {
	nav := navSource{host: "bingo"}.data("status", false)
	if nav.State != stateUnknown || nav.ShowUplink {
		t.Fatalf("nav = %+v, want unknown state and no uplink entry", nav)
	}
	if nav.Host != "bingo" {
		t.Fatalf("host = %q", nav.Host)
	}
}

// Every page template must invoke the shared strip, or the section it belongs
// to loses its navigation the moment someone lands on it directly.
func TestEveryPageTemplateInvokesTheNav(t *testing.T) {
	for _, page := range []string{"index.html", "uplink.html", "peers.html", "peers-index.html"} {
		body, err := readFileString(page)
		if err != nil {
			t.Fatalf("read %s: %v", page, err)
		}
		if !strings.Contains(body, `{{ template "nav" .Nav }}`) {
			t.Fatalf("%s does not invoke the shared nav", page)
		}
		if !strings.Contains(body, `href="/style.css"`) {
			t.Fatalf("%s does not link the shared stylesheet", page)
		}
		if strings.Contains(body, "<style>") {
			t.Fatalf("%s still carries an inline stylesheet", page)
		}
	}
}

func readFileString(path string) (string, error) {
	raw, err := os.ReadFile(path)
	return string(raw), err
}
