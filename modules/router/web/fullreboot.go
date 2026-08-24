package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The whole-estate reboot: the fibre terminal, then this router, then every
// access point that can be rebooted.
//
// The sequence exists because the parts have to go in that order and each
// waits on the one before it. Rebooting the router first would only race the
// ONT's re-ranging; rebooting the access points first would have them come up
// against a LAN whose router is about to disappear.
//
// WHAT THIS FILE DOES NOT DO IS THE REBOOTING. router-web runs under
// DynamicUser and holds no credential for the ONT — that separation is the
// point of ont.go and is not worth spending here. All this does is write a
// request file into its own state directory. A systemd path unit watches for
// it and starts a root service that does the work. The privilege boundary is
// therefore a file, and the web process never gains the ability to reboot
// anything by itself.

// fullRebootService is the request side. Nil when the feature is not
// configured, which keeps the section off the page entirely.
type fullRebootService struct {
	// The file whose appearance starts the sequence. Written into the state
	// directory rather than /run so that a request cannot be silently lost to
	// a tmpfs remount between the write and the path unit noticing.
	requestPath string
	// Shown in the confirmation dialog and typed nowhere: this is the one
	// control on the page whose blast radius is the whole house, and these
	// routers come in near-identical pairs.
	host string
	// What previous runs did, written by the root scripts on either side of
	// the reboot. Read-only here, and empty until the first run: the section
	// renders its control with no timeline rather than an empty one.
	historyPath string
}

func newFullRebootService(requestPath, historyPath, host string) *fullRebootService {
	requestPath = strings.TrimSpace(requestPath)
	if requestPath == "" {
		return nil
	}
	return &fullRebootService{
		requestPath: requestPath,
		historyPath: strings.TrimSpace(historyPath),
		host:        host,
	}
}

// One recorded step of one run.
type fullRebootStep struct {
	When   string
	Phase  string
	Detail string
	// meterOK or meterBad, reused as the CSS suffix so a failed step is
	// coloured the same way a failed reading is everywhere else on this page.
	State string
}

// fullRebootRun groups the steps of one sequence, including the ones recorded
// on the far side of the router's own reboot.
type fullRebootRun struct {
	Started string
	Outcome string
	State   string
	Steps   []fullRebootStep
}

// view is what the template renders. Nil service, no section.
type fullRebootView struct {
	Host string
	// Newest first, so the run someone just started is the one they see when
	// they open the timeline.
	Runs []fullRebootRun
}

func (s *fullRebootService) view() *fullRebootView {
	if s == nil {
		return nil
	}
	return &fullRebootView{Host: s.host, Runs: s.runs()}
}

// How many past runs the timeline offers. The file is trimmed on the writing
// side too; this is the display bound rather than the storage one.
const fullRebootRunsShown = 12

// runs parses the timeline file into runs, newest first.
//
// Every kind of malformed line is skipped rather than being an error. This is
// a status page, and one bad row from a half-written append during a power cut
// must not cost the reader the rest of the history.
func (s *fullRebootService) runs() []fullRebootRun {
	if s.historyPath == "" {
		return nil
	}
	body, err := os.ReadFile(s.historyPath)
	if err != nil {
		return nil
	}

	order := []string{}
	byRun := map[string][]fullRebootStep{}
	for _, line := range strings.Split(string(body), "\n") {
		fields := strings.Split(strings.TrimRight(line, "\r"), "\t")
		if len(fields) != 5 {
			continue
		}
		run, whenRaw, phase, outcome, detail := fields[0], fields[1], fields[2], fields[3], fields[4]
		seconds, err := strconv.ParseInt(whenRaw, 10, 64)
		if err != nil {
			continue
		}
		if _, seen := byRun[run]; !seen {
			order = append(order, run)
		}
		state := meterOK
		if outcome == "failed" {
			state = meterBad
		}
		byRun[run] = append(byRun[run], fullRebootStep{
			When:   time.Unix(seconds, 0).Format("15:04:05"),
			Phase:  phase,
			Detail: detail,
			State:  state,
		})
	}

	var runs []fullRebootRun
	for i := len(order) - 1; i >= 0 && len(runs) < fullRebootRunsShown; i-- {
		id := order[i]
		steps := byRun[id]
		started, err := strconv.ParseInt(id, 10, 64)
		if err != nil {
			continue
		}
		run := fullRebootRun{
			Started: time.Unix(started, 0).Format("2006-01-02 15:04"),
			Steps:   steps,
			State:   meterOK,
			Outcome: "completed",
		}
		for _, step := range steps {
			if step.State == meterBad {
				run.State, run.Outcome = meterBad, "stopped at "+step.Phase
				break
			}
		}
		// A run whose last recorded step is the router going down never came
		// back to write the rest. Saying so is the point of the timeline: it is
		// the one outcome the reader cannot otherwise distinguish from success.
		if run.State == meterOK && steps[len(steps)-1].Phase == "router" &&
			steps[len(steps)-1].Detail == "rebooting this router" {
			run.State, run.Outcome = meterBad, "did not finish"
		}
		runs = append(runs, run)
	}
	return runs
}

// handleStart records the request and hands back to the status page.
//
// Deliberately does not wait for anything. The first thing the sequence does
// is take the ONT down, and a handler that blocked on that would be answering
// a request over a network it had just started dismantling.
func (s *fullRebootService) handleStart(w http.ResponseWriter, r *http.Request) {
	if !sameOrigin(w, r) {
		return
	}

	// The timestamp is for the log, not for the state machine: the path unit
	// triggers on the file existing at all. Written through a temporary file
	// and renamed so the unit cannot observe a half-written request.
	body := fmt.Sprintf("requested %s\n", time.Now().Format(time.RFC3339))
	dir := filepath.Dir(s.requestPath)
	tmp, err := os.CreateTemp(dir, "full-reboot-*.tmp")
	if err == nil {
		_, err = tmp.WriteString(body)
		tmp.Close()
		if err == nil {
			err = os.Rename(tmp.Name(), s.requestPath)
		}
		if err != nil {
			os.Remove(tmp.Name())
		}
	}
	if err != nil {
		log.Printf("full-reboot result=%q", err.Error())
		http.Error(w, "could not start the reboot sequence", http.StatusInternalServerError)
		return
	}

	log.Printf("full-reboot result=\"requested\"")
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// rebootAllAccessPoints is the last phase, run from a root unit on the boot
// after the router restarts itself. Returns the number rebooted.
//
// Failures are logged and counted rather than fatal. One access point that has
// not finished booting, or has been unplugged, must not stop the others from
// being brought round — the whole point of the sequence is that it completes
// unattended.
func rebootAllAccessPoints(monitor *apMonitor) (done, total int) {
	if monitor == nil || !monitor.canReboot() {
		log.Printf("full-reboot phase=aps result=\"no access points with credentials\"")
		return 0, 0
	}

	for _, report := range monitor.reports() {
		total++
		if err := monitor.rebootByName(report.Name); err != nil {
			log.Printf("full-reboot phase=aps ap=%q result=%q", report.Name, err.Error())
			continue
		}
		log.Printf("full-reboot phase=aps ap=%q result=\"ok\"", report.Name)
		done++
	}
	return done, total
}
