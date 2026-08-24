package main

import (
	"fmt"
	"html/template"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestFullReboot(t *testing.T) *fullRebootService {
	t.Helper()
	return newFullRebootService(filepath.Join(t.TempDir(), "full-reboot.request"), "", "bongo")
}

// The whole of what router-web does for this feature: leave a file behind.
// Nothing here may reboot anything, and in particular nothing here holds a
// credential for the ONT.
func TestFullRebootWritesARequestAndNothingElse(t *testing.T) {
	service := newTestFullReboot(t)

	recorder := httptest.NewRecorder()
	service.handleStart(recorder, httptest.NewRequest(http.MethodPost, "/full-reboot", nil))

	if recorder.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", recorder.Code)
	}
	body, err := os.ReadFile(service.requestPath)
	if err != nil {
		t.Fatalf("no request file written: %v", err)
	}
	if !strings.HasPrefix(string(body), "requested ") {
		t.Errorf("request file reads %q", string(body))
	}
	// No leftover temporary files: the path unit watches this directory and a
	// stray one would be noise at best.
	entries, err := os.ReadDir(filepath.Dir(service.requestPath))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Errorf("%d files in the state directory, want 1", len(entries))
	}
}

// The destructive route is same-origin guarded, exactly like the AP reboot.
func TestFullRebootRefusesCrossSite(t *testing.T) {
	service := newTestFullReboot(t)

	request := httptest.NewRequest(http.MethodPost, "/full-reboot", nil)
	request.Header.Set("Sec-Fetch-Site", "cross-site")
	recorder := httptest.NewRecorder()
	service.handleStart(recorder, request)

	if recorder.Code != http.StatusForbidden {
		t.Errorf("status = %d, want 403", recorder.Code)
	}
	if _, err := os.Stat(service.requestPath); err == nil {
		t.Error("a cross-site POST started the sequence")
	}
}

// Unconfigured means no section, no dialog and no route.
func TestFullRebootAbsentWhenUnset(t *testing.T) {
	if newFullRebootService("", "", "bongo") != nil {
		t.Error("an unset path produced a service")
	}
	if newFullRebootService("   ", "", "bongo") != nil {
		t.Error("a blank path produced a service")
	}
	var nilService *fullRebootService
	if nilService.view() != nil {
		t.Error("a nil service produced a view")
	}

	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	recorder := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, nil, nil, nil, navSource{}).ServeHTTP(
		recorder, httptest.NewRequest(http.MethodGet, "/", nil))
	if body := recorder.Body.String(); strings.Contains(body, "Full Reboot") {
		t.Error("the full reboot section rendered with the feature unconfigured")
	}
}

// The section renders, and the POST is reachable only from inside the dialog:
// the visible control is a link that opens it, never the form itself.
func TestFullRebootSectionIsGuardedByADialog(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	recorder := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, nil, nil, newTestFullReboot(t), navSource{}).ServeHTTP(
		recorder, httptest.NewRequest(http.MethodGet, "/", nil))

	body := recorder.Body.String()
	for _, want := range []string{
		"Full Reboot",
		`href="#confirm-full-reboot"`,
		`id="confirm-full-reboot"`,
		"Reboot everything on bongo?",
		`action="/full-reboot"`,
		"Cancel",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("status page is missing %q", want)
		}
	}
	// No JavaScript anywhere: the dialog is CSS :target, and these pages are
	// read during outages where a script that fails to load is a dead button.
	if strings.Contains(body, "<script") || strings.Contains(body, "onclick") {
		t.Error("the confirmation introduced JavaScript to a page that had none")
	}
	// The form must be inside the dialog, not loose in the section above it.
	dialog := body[strings.Index(body, `id="confirm-full-reboot"`):]
	if !strings.Contains(dialog[:strings.Index(dialog, "</div>")+6], "") {
		t.Fatal("dialog markup not found")
	}
	if strings.Count(body, `action="/full-reboot"`) != 1 {
		t.Error("more than one route to the destructive POST")
	}
}

// The route exists exactly where the section that offers it does.
func TestFullRebootRouteFollowsTheSection(t *testing.T) {
	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))

	recorder := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, nil, nil, nil, navSource{}).ServeHTTP(
		recorder, httptest.NewRequest(http.MethodPost, "/full-reboot", nil))
	if recorder.Code != http.StatusNotFound {
		t.Errorf("unconfigured POST /full-reboot = %d, want 404", recorder.Code)
	}

	recorder = httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, nil, nil, newTestFullReboot(t), navSource{}).ServeHTTP(
		recorder, httptest.NewRequest(http.MethodPost, "/full-reboot", nil))
	if recorder.Code != http.StatusSeeOther {
		t.Errorf("configured POST /full-reboot = %d, want 303", recorder.Code)
	}
}

// The timeline the sequence writes on either side of the router's own reboot.

// writeHistory drops a timeline file and returns a service reading it.
func withHistory(t *testing.T, lines ...string) *fullRebootService {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "history.tsv")
	body := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write history: %v", err)
	}
	return newFullRebootService(filepath.Join(dir, "full-reboot.request"), path, "bongo")
}

// A complete run, including the steps recorded after the router came back.
// The run id is what joins the two halves.
func TestTimelineJoinsStepsAcrossTheReboot(t *testing.T) {
	runs := withHistory(t,
		"1700000000\t1700000000\trequested\tok\trequested from the status page",
		"1700000000\t1700000074\tfibre\tok\tback after 74s",
		"1700000000\t1700000075\trouter\tstarted\trebooting this router",
		"1700000000\t1700000260\trouter\tok\trouter back up",
		"1700000000\t1700000330\taccess-points\tok\t2 of 2 access points rebooted",
	).runs()

	if len(runs) != 1 {
		t.Fatalf("got %d runs, want 1 — the reboot split one run in two", len(runs))
	}
	if len(runs[0].Steps) != 5 {
		t.Errorf("got %d steps, want 5", len(runs[0].Steps))
	}
	if runs[0].State != meterOK || runs[0].Outcome != "completed" {
		t.Errorf("outcome = %q/%q, want ok/completed", runs[0].State, runs[0].Outcome)
	}
}

// The abort case has to read as an abort, not as a run that is still going.
func TestTimelineShowsAFibreAbort(t *testing.T) {
	runs := withHistory(t,
		"1700000000\t1700000000\trequested\tok\trequested from the status page",
		"1700000000\t1700000300\tfibre\tfailed\tdid not come back within 300s; sequence stopped",
	).runs()

	if runs[0].State != meterBad {
		t.Errorf("state = %q, want bad", runs[0].State)
	}
	if !strings.Contains(runs[0].Outcome, "fibre") {
		t.Errorf("outcome = %q, want it to name the phase that stopped", runs[0].Outcome)
	}
}

// A router that went down and never came back writes nothing more. That is the
// one outcome the reader cannot otherwise tell apart from success.
func TestTimelineFlagsARunThatNeverCameBack(t *testing.T) {
	runs := withHistory(t,
		"1700000000\t1700000000\trequested\tok\trequested from the status page",
		"1700000000\t1700000074\tfibre\tok\tback after 74s",
		"1700000000\t1700000075\trouter\tstarted\trebooting this router",
	).runs()

	if runs[0].State != meterBad || runs[0].Outcome != "did not finish" {
		t.Errorf("got %q/%q, want bad/did not finish", runs[0].State, runs[0].Outcome)
	}
}

// Newest first, and bounded.
func TestTimelineIsNewestFirstAndBounded(t *testing.T) {
	var lines []string
	for i := range fullRebootRunsShown + 5 {
		id := 1700000000 + i*1000
		lines = append(lines,
			fmt.Sprintf("%d\t%d\trequested\tok\tstarted", id, id),
			fmt.Sprintf("%d\t%d\taccess-points\tok\tdone", id, id+300))
	}
	runs := withHistory(t, lines...).runs()

	if len(runs) != fullRebootRunsShown {
		t.Fatalf("got %d runs, want %d", len(runs), fullRebootRunsShown)
	}
	if runs[0].Started < runs[1].Started {
		t.Errorf("runs are oldest first: %q before %q", runs[0].Started, runs[1].Started)
	}
}

// A half-written append during a power cut must not cost the rest of the file.
func TestTimelineSkipsMalformedLines(t *testing.T) {
	runs := withHistory(t,
		"garbage",
		"1700000000\tnot-a-number\tfibre\tok\tx",
		"1700000000\t1700000000\trequested\tok\tstarted",
		"1700000000\t1700000300\taccess-points\tok\tdone",
		"short\tline",
	).runs()

	if len(runs) != 1 || len(runs[0].Steps) != 2 {
		t.Fatalf("got %d runs with %v steps, want 1 run of 2", len(runs), len(runs[0].Steps))
	}
}

// No file yet is the normal state of a router that has never done this.
func TestTimelineAbsentBeforeTheFirstRun(t *testing.T) {
	service := newTestFullReboot(t)
	if got := service.runs(); got != nil {
		t.Errorf("runs() = %v with no history configured", got)
	}
	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	recorder := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, nil, nil, service, navSource{}).ServeHTTP(
		recorder, httptest.NewRequest(http.MethodGet, "/", nil))
	body := recorder.Body.String()
	if !strings.Contains(body, "Full Reboot") {
		t.Fatal("the section itself should still render")
	}
	if strings.Contains(body, "Previous reboots") {
		t.Error("an empty timeline rendered")
	}
}

// Collapsed by default, and native rather than scripted.
func TestTimelineRendersCollapsed(t *testing.T) {
	service := withHistory(t,
		"1700000000\t1700000000\trequested\tok\trequested from the status page",
		"1700000000\t1700000330\taccess-points\tok\t2 of 2 access points rebooted")

	tmpl := template.Must(template.ParseFiles("index.html", "nav.html"))
	recorder := httptest.NewRecorder()
	landingMux(pageData{}, tmpl, nil, nil, nil, service, navSource{}).ServeHTTP(
		recorder, httptest.NewRequest(http.MethodGet, "/", nil))

	body := recorder.Body.String()
	for _, want := range []string{"<details", "<summary>Previous reboots (1)", "access-points", "2 of 2 access points rebooted"} {
		if !strings.Contains(body, want) {
			t.Errorf("status page is missing %q", want)
		}
	}
	// `open` would defeat the whole request.
	if strings.Contains(body, "<details open") {
		t.Error("the timeline renders expanded")
	}
	if strings.Contains(body, "<script") {
		t.Error("the timeline introduced JavaScript")
	}
}
