package main

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// The on-router history of uplink quality.
//
// SQLite rather than another Prometheus series, because of what this data is
// for. The o11y stack keeps 30 days and lives on oreamnos, which is reachable
// from the LAN but is not the thing you want to depend on while arguing that
// the uplink is broken. A file on the router itself is readable during the
// outage it recorded, keeps 90 days without touching global retention, and can
// be queried by hand over SSH:
//
//	sqlite3 /var/lib/private/router-web/uplink.db \
//	  "select date(ts,'unixepoch'), target, sum(sent)-sum(received) from minute group by 1,2"
//
// That last property is the reason this is real SQLite and not a compact
// append-only format of our own: the evidence for a support ticket gets
// assembled ad hoc, and a format only this binary can read would mean writing
// a query tool before writing the complaint.
//
// Prometheus still gets the same numbers through /metrics. This store is the
// long memory, not a replacement for the dashboard.

// One minute of probing against one target. RTT fields are milliseconds and
// are meaningless when Received is zero.
type minuteRow struct {
	TS       time.Time
	Target   string
	Role     string
	Address  string
	Sent     int
	Received int
	RTTMin   float64
	RTTP50   float64
	RTTP95   float64
	RTTMax   float64
	// Mean absolute difference between successive successful RTTs, rather than
	// standard deviation. A single 300 ms cold-path punt moves stddev far more
	// than it moves this, and the punts are an artifact of the access node
	// rather than a property of the line — see the warmup handling in
	// uplink.go.
	Jitter float64
	// Peak WAN throughput seen during the minute, bits/second, sampled
	// alongside the probes. Present so that latency can be read against load:
	// a p95 of 80 ms means something different at 2 Mbit/s than at line rate.
	DownPeak uint64
	UpPeak   uint64
}

// Loss returns the fraction of probes lost in the minute, 0 to 1.
func (r minuteRow) Loss() float64 {
	if r.Sent == 0 {
		return 0
	}
	return float64(r.Sent-r.Received) / float64(r.Sent)
}

// A discrete thing that happened to the uplink, as opposed to a measurement of
// it. Events never expire: a PPP flap from four months ago is exactly the kind
// of thing worth citing, and the whole table is a few kilobytes.
type uplinkEvent struct {
	ID     int64
	TS     time.Time
	Kind   string
	Target string
	Detail string
	// Zero while the event is still ongoing.
	Ended time.Time
}

// Event kinds. Kept as constants because the health band and the metrics
// endpoint both count by kind, and a typo in either would silently report zero
// rather than fail.
const (
	eventPPPDown     = "ppp_down"
	eventPeerChanged = "peer_changed"
	eventOutage      = "outage"
	eventDegraded    = "degraded"
)

type uplinkStore struct {
	db *sql.DB
}

const uplinkSchema = `
CREATE TABLE IF NOT EXISTS minute (
  ts        INTEGER NOT NULL,
  target    TEXT    NOT NULL,
  role      TEXT    NOT NULL,
  address   TEXT    NOT NULL,
  sent      INTEGER NOT NULL,
  received  INTEGER NOT NULL,
  rtt_min   REAL    NOT NULL,
  rtt_p50   REAL    NOT NULL,
  rtt_p95   REAL    NOT NULL,
  rtt_max   REAL    NOT NULL,
  jitter    REAL    NOT NULL,
  down_peak INTEGER NOT NULL,
  up_peak   INTEGER NOT NULL,
  PRIMARY KEY (ts, target)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS event (
  id     INTEGER PRIMARY KEY,
  ts     INTEGER NOT NULL,
  kind   TEXT    NOT NULL,
  target TEXT    NOT NULL,
  detail TEXT    NOT NULL,
  ended  INTEGER
);

CREATE TABLE IF NOT EXISTS optical (
  ts     INTEGER PRIMARY KEY,
  rx     REAL    NOT NULL,
  tx     REAL    NOT NULL,
  temp   REAL    NOT NULL,
  volt   REAL    NOT NULL,
  bias   REAL    NOT NULL,
  pon_up INTEGER NOT NULL
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS event_ts ON event(ts);
CREATE INDEX IF NOT EXISTS event_open ON event(kind, target) WHERE ended IS NULL;
`

// Closes rows left open by a process that stopped mid-event, in the one case
// where the end time is knowable rather than invented: a later event of the
// same kind and target exists, so this one demonstrably did not continue past
// where that one began.
//
// Two defects put such rows in the database. peer_changed was appended and
// never closed, so every daily redial since the feature landed was still
// "ongoing" — a column of them, each claiming to be the current session. And
// a restart mid-episode orphaned the open degraded row, then opened a second
// one three bad minutes later, so an anchor that stayed degraded across a
// deploy showed two overlapping episodes that could never end. Both are fixed
// where they were caused; this repairs what they already wrote.
//
// Deliberately does not touch the newest open row for a kind and target. That
// one is either the session currently in use or an episode still running, and
// inventing an end for it is the failure this is fixing, not the fix.
//
// Idempotent: once a row has an end it no longer matches. Cheap enough to run
// on every open — the table is a few thousand rows at most.
const uplinkCloseSuperseded = `
UPDATE event
SET ended = (
  SELECT MIN(later.ts) FROM event AS later
  WHERE later.kind = event.kind AND later.target = event.target AND later.ts > event.ts
)
WHERE ended IS NULL
  AND EXISTS (
    SELECT 1 FROM event AS later
    WHERE later.kind = event.kind AND later.target = event.target AND later.ts > event.ts
  );
`

// openUplinkStore opens (creating if absent) the history database.
//
// WAL because the writer holds the connection for the life of the process and
// the page handlers read on every request; without it a render during a flush
// would block on the write lock. synchronous=NORMAL because losing the last
// few seconds of probe history to a power cut is not worth an fsync per
// minute on the router's flash.
func openUplinkStore(path string) (*uplinkStore, error) {
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, fmt.Errorf("create %s: %w", dir, err)
		}
	}

	dsn := "file:" + path + "?_journal_mode=WAL&_synchronous=NORMAL&_busy_timeout=5000"
	db, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	if _, err := db.Exec(uplinkSchema); err != nil {
		db.Close()
		return nil, fmt.Errorf("create schema in %s: %w", path, err)
	}
	if _, err := db.Exec(uplinkCloseSuperseded); err != nil {
		db.Close()
		return nil, fmt.Errorf("repair open events in %s: %w", path, err)
	}

	return &uplinkStore{db: db}, nil
}

func (s *uplinkStore) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

// writeMinute records one aggregated minute. Replaces rather than fails on a
// duplicate key: a flush that runs twice for the same minute (a restart
// straddling a boundary) should leave the later, more complete row.
func (s *uplinkStore) writeMinute(row minuteRow) error {
	_, err := s.db.Exec(`
		INSERT OR REPLACE INTO minute
		  (ts, target, role, address, sent, received,
		   rtt_min, rtt_p50, rtt_p95, rtt_max, jitter, down_peak, up_peak)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		row.TS.Unix(), row.Target, row.Role, row.Address, row.Sent, row.Received,
		row.RTTMin, row.RTTP50, row.RTTP95, row.RTTMax, row.Jitter,
		int64(row.DownPeak), int64(row.UpPeak))
	if err != nil {
		return fmt.Errorf("write minute %s/%s: %w", row.Target, row.TS.Format(time.RFC3339), err)
	}
	return nil
}

func scanMinutes(rows *sql.Rows) ([]minuteRow, error) {
	defer rows.Close()

	var out []minuteRow
	for rows.Next() {
		var row minuteRow
		var ts int64
		var down, up int64
		if err := rows.Scan(&ts, &row.Target, &row.Role, &row.Address, &row.Sent, &row.Received,
			&row.RTTMin, &row.RTTP50, &row.RTTP95, &row.RTTMax, &row.Jitter, &down, &up); err != nil {
			return nil, err
		}
		row.TS = time.Unix(ts, 0)
		row.DownPeak = uint64(down)
		row.UpPeak = uint64(up)
		out = append(out, row)
	}
	return out, rows.Err()
}

const minuteColumns = `ts, target, role, address, sent, received,
	rtt_min, rtt_p50, rtt_p95, rtt_max, jitter, down_peak, up_peak`

// since returns every minute for one target at or after a time, oldest first.
func (s *uplinkStore) since(target string, from time.Time) ([]minuteRow, error) {
	rows, err := s.db.Query(`SELECT `+minuteColumns+`
		FROM minute WHERE target = ? AND ts >= ? ORDER BY ts`, target, from.Unix())
	if err != nil {
		return nil, err
	}
	return scanMinutes(rows)
}

// latest returns the most recent minute for one target.
func (s *uplinkStore) latest(target string) (minuteRow, bool, error) {
	rows, err := s.db.Query(`SELECT `+minuteColumns+`
		FROM minute WHERE target = ? ORDER BY ts DESC LIMIT 1`, target)
	if err != nil {
		return minuteRow{}, false, err
	}
	found, err := scanMinutes(rows)
	if err != nil || len(found) == 0 {
		return minuteRow{}, false, err
	}
	return found[0], true, nil
}

// lossSince totals probes sent and received for one target over a window.
func (s *uplinkStore) lossSince(target string, from time.Time) (sent int, received int, err error) {
	row := s.db.QueryRow(`
		SELECT COALESCE(SUM(sent), 0), COALESCE(SUM(received), 0)
		FROM minute WHERE target = ? AND ts >= ?`, target, from.Unix())
	err = row.Scan(&sent, &received)
	return sent, received, err
}

// baseline is what this target's latency looks like on a good day: the 10th
// percentile of the per-minute medians over a window.
//
// A percentile rather than a minimum, because the minimum is one lucky packet
// and drifts to the floor over a long window. A low percentile rather than the
// median, because the median of a week that contained a bad day encodes the
// bad day, and the question this answers is "compared to when it works".
//
// Minutes with no successful probe are excluded; a zero there is absence, not
// a fast reply.
func (s *uplinkStore) baseline(target string, from time.Time) (float64, bool, error) {
	var count int
	if err := s.db.QueryRow(`
		SELECT COUNT(*) FROM minute
		WHERE target = ? AND ts >= ? AND received > 0`, target, from.Unix()).Scan(&count); err != nil {
		return 0, false, err
	}
	if count == 0 {
		return 0, false, nil
	}

	offset := count / 10
	var value float64
	err := s.db.QueryRow(`
		SELECT rtt_p50 FROM minute
		WHERE target = ? AND ts >= ? AND received > 0
		ORDER BY rtt_p50 LIMIT 1 OFFSET ?`, target, from.Unix(), offset).Scan(&value)
	if err != nil {
		return 0, false, err
	}
	return value, true, nil
}

// appendEvent records a new event and returns its id.
func (s *uplinkStore) appendEvent(ev uplinkEvent) (int64, error) {
	result, err := s.db.Exec(`INSERT INTO event (ts, kind, target, detail, ended) VALUES (?, ?, ?, ?, NULL)`,
		ev.TS.Unix(), ev.Kind, ev.Target, ev.Detail)
	if err != nil {
		return 0, fmt.Errorf("append %s event: %w", ev.Kind, err)
	}
	return result.LastInsertId()
}

// closeEvent marks an ongoing event as finished. Closing an event that is
// already closed, or that does not exist, is not an error: the callers are
// state machines that can be restarted mid-episode.
func (s *uplinkStore) closeEvent(id int64, at time.Time) error {
	_, err := s.db.Exec(`UPDATE event SET ended = ? WHERE id = ? AND ended IS NULL`, at.Unix(), id)
	return err
}

// closeOpenEvents closes every unfinished event of a kind for a target.
//
// Plural because the caller cannot assume there is only one: a process that
// stopped mid-episode leaves a row open, and until the resume in
// newUplinkProber existed every restart added another.
func (s *uplinkStore) closeOpenEvents(kind, target string, at time.Time) error {
	_, err := s.db.Exec(`UPDATE event SET ended = ? WHERE kind = ? AND target = ? AND ended IS NULL`,
		at.Unix(), kind, target)
	if err != nil {
		return fmt.Errorf("close open %s events: %w", kind, err)
	}
	return nil
}

// openTargets lists the targets with an unfinished event of a kind, so a
// caller can notice one it is no longer measuring.
func (s *uplinkStore) openTargets(kind string) ([]string, error) {
	rows, err := s.db.Query(
		`SELECT DISTINCT target FROM event WHERE kind = ? AND ended IS NULL`, kind)
	if err != nil {
		return nil, fmt.Errorf("list open %s targets: %w", kind, err)
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var target string
		if err := rows.Scan(&target); err != nil {
			return nil, fmt.Errorf("list open %s targets: %w", kind, err)
		}
		out = append(out, target)
	}
	return out, rows.Err()
}

// openEvent finds an unfinished event of a kind for a target, so that a
// restart mid-episode resumes it rather than opening a second one that
// overlaps the first.
func (s *uplinkStore) openEvent(kind, target string) (uplinkEvent, bool, error) {
	var ev uplinkEvent
	var ts int64
	err := s.db.QueryRow(`SELECT id, ts, kind, target, detail FROM event
		WHERE kind = ? AND target = ? AND ended IS NULL ORDER BY ts DESC LIMIT 1`, kind, target).
		Scan(&ev.ID, &ts, &ev.Kind, &ev.Target, &ev.Detail)
	if errors.Is(err, sql.ErrNoRows) {
		return uplinkEvent{}, false, nil
	}
	if err != nil {
		return uplinkEvent{}, false, err
	}
	ev.TS = time.Unix(ts, 0)
	return ev, true, nil
}

// events returns events at or after a time, newest first.
func (s *uplinkStore) events(from time.Time, limit int) ([]uplinkEvent, error) {
	rows, err := s.db.Query(`SELECT id, ts, kind, target, detail, COALESCE(ended, 0)
		FROM event WHERE ts >= ? ORDER BY ts DESC LIMIT ?`, from.Unix(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []uplinkEvent
	for rows.Next() {
		var ev uplinkEvent
		var ts, ended int64
		if err := rows.Scan(&ev.ID, &ts, &ev.Kind, &ev.Target, &ev.Detail, &ended); err != nil {
			return nil, err
		}
		ev.TS = time.Unix(ts, 0)
		if ended > 0 {
			ev.Ended = time.Unix(ended, 0)
		}
		out = append(out, ev)
	}
	return out, rows.Err()
}

// countEvents counts events of a kind that started at or after a time.
func (s *uplinkStore) countEvents(kind string, from time.Time) (int, error) {
	var count int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM event WHERE kind = ? AND ts >= ?`,
		kind, from.Unix()).Scan(&count)
	return count, err
}

// One target's totals for one local day, for the long table on the detail
// page. Computed in SQL rather than held in a rollup table: 90 days of minutes
// is a few hundred thousand rows, which SQLite groups in milliseconds, and a
// second table would be a second thing that can disagree with the first.
type dayRow struct {
	Day      time.Time
	Target   string
	Sent     int
	Received int
	RTTMin   float64
	RTTP50   float64
	RTTP95   float64
	RTTMax   float64
}

func (r dayRow) Loss() float64 {
	if r.Sent == 0 {
		return 0
	}
	return float64(r.Sent-r.Received) / float64(r.Sent)
}

// daily groups minutes into local days. The offset is applied inside the
// query so that a day boundary matches the clock on the wall rather than UTC,
// which matters here because the ISP's own maintenance windows are local and
// the 05:00 redial sits four hours from the UTC boundary.
//
// p50 and p95 are averages of the per-minute percentiles, not true daily
// percentiles. Rendered as such on the page: a real p95 over a day would need
// the raw samples, which are deliberately not kept.
func (s *uplinkStore) daily(from time.Time, offsetSeconds int) ([]dayRow, error) {
	rows, err := s.db.Query(`
		SELECT (ts + ?) / 86400 AS day, target,
		       SUM(sent), SUM(received),
		       COALESCE(MIN(NULLIF(rtt_min, 0)), 0),
		       COALESCE(AVG(NULLIF(rtt_p50, 0)), 0),
		       COALESCE(AVG(NULLIF(rtt_p95, 0)), 0),
		       MAX(rtt_max)
		FROM minute WHERE ts >= ?
		GROUP BY day, target ORDER BY day DESC, target`, offsetSeconds, from.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []dayRow
	for rows.Next() {
		var row dayRow
		var day int64
		if err := rows.Scan(&day, &row.Target, &row.Sent, &row.Received,
			&row.RTTMin, &row.RTTP50, &row.RTTP95, &row.RTTMax); err != nil {
			return nil, err
		}
		row.Day = time.Unix(day*86400-int64(offsetSeconds), 0)
		out = append(out, row)
	}
	return out, rows.Err()
}

// prune drops minutes older than the retention window. Events are untouched
// on purpose — see uplinkEvent.
func (s *uplinkStore) prune(before time.Time) error {
	if _, err := s.db.Exec(`DELETE FROM minute WHERE ts < ?`, before.Unix()); err != nil {
		return fmt.Errorf("prune minutes: %w", err)
	}
	if _, err := s.db.Exec(`DELETE FROM optical WHERE ts < ?`, before.Unix()); err != nil {
		return fmt.Errorf("prune optical: %w", err)
	}
	return nil
}

// opticalSample is one reading of the fibre terminal's transceiver.
//
// Kept here beside the line history rather than in a store of its own because
// it answers the same question from the other end: the anchors say what the
// path is delivering, this says what the glass is doing. Reading them off one
// page during a fault is the whole point, and that means one database.
type opticalSample struct {
	TS    time.Time
	Rx    float64
	Tx    float64
	Temp  float64
	Volt  float64
	Bias  float64
	PONUp bool
}

// appendOptical records a reading, keyed on the moment the collector produced
// it rather than the moment this process read the file.
//
// That choice is what makes the sampler safe to run more often than the
// collector: re-reading an unchanged file yields the same timestamp, the
// primary key collides, and OR IGNORE drops it. Sampling faster than the
// collector writes therefore costs a file read and nothing else, and a
// collector that stalls leaves a visible gap instead of a flat line of
// duplicated readings.
func (s *uplinkStore) appendOptical(sample opticalSample) error {
	pon := 0
	if sample.PONUp {
		pon = 1
	}
	_, err := s.db.Exec(
		`INSERT OR IGNORE INTO optical (ts, rx, tx, temp, volt, bias, pon_up) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		sample.TS.Unix(), sample.Rx, sample.Tx, sample.Temp, sample.Volt, sample.Bias, pon)
	if err != nil {
		return fmt.Errorf("append optical sample: %w", err)
	}
	return nil
}

// opticalSince returns readings at or after a time, oldest first.
func (s *uplinkStore) opticalSince(from time.Time) ([]opticalSample, error) {
	rows, err := s.db.Query(
		`SELECT ts, rx, tx, temp, volt, bias, pon_up FROM optical WHERE ts >= ? ORDER BY ts`, from.Unix())
	if err != nil {
		return nil, fmt.Errorf("read optical history: %w", err)
	}
	defer rows.Close()

	var out []opticalSample
	for rows.Next() {
		var sample opticalSample
		var ts int64
		var pon int
		if err := rows.Scan(&ts, &sample.Rx, &sample.Tx, &sample.Temp, &sample.Volt, &sample.Bias, &pon); err != nil {
			return nil, fmt.Errorf("read optical history: %w", err)
		}
		sample.TS = time.Unix(ts, 0)
		sample.PONUp = pon != 0
		out = append(out, sample)
	}
	return out, rows.Err()
}

// targets lists the target names that have any history, so the detail page can
// render a target whose anchor has since been removed from the configuration
// rather than pretending its history does not exist.
func (s *uplinkStore) targets() ([]string, error) {
	rows, err := s.db.Query(`SELECT DISTINCT target FROM minute ORDER BY target`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		out = append(out, name)
	}
	return out, rows.Err()
}

// percentile returns the nearest-rank percentile of a sample set, in the units
// the samples are in. The input is sorted in place.
//
// Nearest-rank rather than interpolated: with sixty samples a minute the
// difference is under a millisecond, and a value that appears in the data is
// easier to defend than one computed between two that do.
func percentile(values []float64, fraction float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sort.Float64s(values)

	rank := int(fraction*float64(len(values)) + 0.5)
	if rank < 1 {
		rank = 1
	}
	if rank > len(values) {
		rank = len(values)
	}
	return values[rank-1]
}

// meanAbsoluteDifference is the jitter figure: the mean gap between successive
// samples. Callers pass RTTs in the order they were measured, which is why
// this cannot share percentile's sorted slice.
func meanAbsoluteDifference(values []float64) float64 {
	if len(values) < 2 {
		return 0
	}

	var total float64
	for i := 1; i < len(values); i++ {
		delta := values[i] - values[i-1]
		if delta < 0 {
			delta = -delta
		}
		total += delta
	}
	return total / float64(len(values)-1)
}
