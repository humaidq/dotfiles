package main

import (
	"bufio"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"flag"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type pageData struct {
	PPPInterface         string
	PPPState             string
	PPPStartedAt         string
	PPPSessionUptime     string
	IPv4                 string
	IPv6                 string
	LANInterface         string
	LANAddress           string
	LocalDomain          string
	DHCPRangeStart       string
	DHCPRangeEnd         string
	DHCPLeaseTime        string
	DHCPRouter           string
	DHCPDNS              string
	DHCPLeasesFile       string
	DHCPHostsFile        string
	DHCPLeaseCount       string
	LANClientCount       string
	DHCPLeaseFileUpdated string
	DHCPStaticHosts      string
	WANRxBytes           string
	WANTxBytes           string
	LANRxBytes           string
	LANTxBytes           string
	Hostname             string
	CurrentTime          string
	LoadAverage          string
	Uptime               string
	UpdatedAt            string
	// Nil on a router with no uplink probing configured, which is what keeps
	// the band out of the template there rather than rendering a row of em
	// dashes that looks like a fault.
	Uplink *uplinkBand
	// The access points, one lamp each. Empty on a router with no list
	// configured, which keeps the section out of the page entirely — the same
	// reason Uplink is a pointer.
	AccessPoints []apReport
	// Whether each access point carries a reboot button. True only when
	// credentials are configured and only on the mesh listener, which is the
	// only one that registers the route behind it — the button and the handler
	// are turned on by the same condition so the page cannot offer an action the
	// mux does not serve.
	APRebootEnabled bool
	// Whether to offer the link to the peers list. True only on the mesh
	// listener, which is the only one that serves it.
	ShowPeers bool
	// The shared navigation strip. Every page carries one under this name, so
	// nav.html can be invoked the same way from all four templates.
	Nav navData
}

//go:embed style.css
var stylesheet string

// The embedded stylesheet's cache validator, derived from its own bytes.
//
// Conditional requests need a validator that is stable across restarts and
// identical on every router serving the same build, which rules out the process
// start time. This was a hand-written date, and a hand-written date is a trap:
// editing style.css without also bumping it serves 304 to every browser holding
// the previous copy, which renders the new markup against the old rules and
// looks like broken CSS rather than a stale cache. That happened. Deriving the
// validator from the content means it cannot disagree with what is served.
//
// Truncated to 16 hex characters: this is a cache key, not a signature.
var stylesheetETag = func() string {
	sum := sha256.Sum256([]byte(stylesheet))
	return `"` + hex.EncodeToString(sum[:8]) + `"`
}()

func getenvDefault(key string, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}

	return value
}

func formatUptime(totalSeconds int64) string {
	days := totalSeconds / 86400
	totalSeconds %= 86400
	hours := totalSeconds / 3600
	totalSeconds %= 3600
	minutes := totalSeconds / 60

	parts := make([]string, 0, 3)
	if days > 0 {
		parts = append(parts, fmt.Sprintf("%dd", days))
	}
	if hours > 0 || days > 0 {
		parts = append(parts, fmt.Sprintf("%dh", hours))
	}
	parts = append(parts, fmt.Sprintf("%dm", minutes))

	return strings.Join(parts, " ")
}

func formatBytes(value uint64) string {
	units := []string{"B", "KiB", "MiB", "GiB", "TiB"}
	size := float64(value)
	unit := units[0]

	for _, next := range units[1:] {
		if size < 1024 {
			break
		}
		size /= 1024
		unit = next
	}

	if unit == "B" {
		return fmt.Sprintf("%d %s", value, unit)
	}

	return fmt.Sprintf("%.1f %s", size, unit)
}

func readFileTrimmed(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}

	return strings.TrimSpace(string(data)), nil
}

func readInterfaceCounters(name string) (string, string) {
	if strings.TrimSpace(name) == "" {
		return "unavailable", "unavailable"
	}

	rxText, err := readFileTrimmed(filepath.Join("/sys/class/net", name, "statistics", "rx_bytes"))
	if err != nil {
		return "unavailable", "unavailable"
	}
	txText, err := readFileTrimmed(filepath.Join("/sys/class/net", name, "statistics", "tx_bytes"))
	if err != nil {
		return "unavailable", "unavailable"
	}

	rxValue, err := strconv.ParseUint(rxText, 10, 64)
	if err != nil {
		return "unavailable", "unavailable"
	}
	txValue, err := strconv.ParseUint(txText, 10, 64)
	if err != nil {
		return "unavailable", "unavailable"
	}

	return formatBytes(rxValue), formatBytes(txValue)
}

func countFileEntries(path string) (int, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer file.Close()

	count := 0
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		count++
	}

	if err := scanner.Err(); err != nil {
		return 0, err
	}

	return count, nil
}

func readPPPSession() (string, string) {
	psPath, err := exec.LookPath("ps")
	if err != nil {
		return "unavailable", "unavailable"
	}

	output, err := exec.Command(psPath, "-C", "pppd", "-o", "lstart=,etime=,cmd=").Output()
	if err != nil {
		return "unavailable", "unavailable"
	}

	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || len(line) < 25 {
			continue
		}

		startedAt := strings.TrimSpace(line[:24])
		remainder := strings.TrimSpace(line[24:])
		fields := strings.Fields(remainder)
		if len(fields) < 2 {
			continue
		}

		return startedAt, fields[0]
	}

	return "unavailable", "unavailable"
}

func countLANClients() string {
	ipPath, err := exec.LookPath("ip")
	if err != nil {
		return "unavailable"
	}

	output, err := exec.Command(ipPath, "-4", "neigh", "show").Output()
	if err != nil {
		return "unavailable"
	}

	count := 0
	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		if strings.TrimSpace(line) != "" {
			count++
		}
	}

	return strconv.Itoa(count)
}

func readLeaseSummary(data pageData) pageData {
	data.DHCPLeaseCount = "unavailable"
	data.LANClientCount = countLANClients()
	data.DHCPLeaseFileUpdated = "unavailable"
	data.DHCPStaticHosts = "none"

	if info, err := os.Stat(data.DHCPLeasesFile); err == nil {
		data.DHCPLeaseFileUpdated = info.ModTime().Format(time.RFC1123)
	}

	if count, err := countFileEntries(data.DHCPLeasesFile); err == nil {
		data.DHCPLeaseCount = strconv.Itoa(count)
	}

	if data.DHCPHostsFile == "" {
		return data
	}

	if count, err := countFileEntries(data.DHCPHostsFile); err == nil {
		data.DHCPStaticHosts = strconv.Itoa(count)
		return data
	}

	data.DHCPStaticHosts = "configured"
	return data
}

func readSystemState(data pageData) pageData {
	data.PPPState = "missing"
	data.PPPStartedAt = "unavailable"
	data.PPPSessionUptime = "unavailable"
	data.IPv4 = "not assigned"
	data.IPv6 = "not assigned"
	data.LoadAverage = "unavailable"
	data.Uptime = "unavailable"
	data.Hostname = "unavailable"
	data.UpdatedAt = time.Now().Format(time.RFC1123)
	data.CurrentTime = time.Now().Format("2006-01-02 15:04:05 MST")
	data.WANRxBytes = "unavailable"
	data.WANTxBytes = "unavailable"
	data.LANRxBytes = "unavailable"
	data.LANTxBytes = "unavailable"

	if loadAverage, err := os.ReadFile("/proc/loadavg"); err == nil {
		fields := strings.Fields(string(loadAverage))
		if len(fields) >= 3 {
			data.LoadAverage = strings.Join(fields[:3], " ")
		}
	}

	if uptimeText, err := readFileTrimmed("/proc/uptime"); err == nil {
		fields := strings.Fields(uptimeText)
		if len(fields) >= 1 {
			if uptimeSeconds, err := strconv.ParseFloat(fields[0], 64); err == nil {
				data.Uptime = formatUptime(int64(uptimeSeconds))
			}
		}
	}

	if hostname, err := os.Hostname(); err == nil && strings.TrimSpace(hostname) != "" {
		data.Hostname = hostname
	}

	data.PPPStartedAt, data.PPPSessionUptime = readPPPSession()

	data.WANRxBytes, data.WANTxBytes = readInterfaceCounters(data.PPPInterface)
	data.LANRxBytes, data.LANTxBytes = readInterfaceCounters(data.LANInterface)

	operstatePath := filepath.Join("/sys/class/net", data.PPPInterface, "operstate")
	if state, err := os.ReadFile(operstatePath); err == nil {
		if trimmed := strings.TrimSpace(string(state)); trimmed != "" {
			data.PPPState = trimmed
		}
	}

	iface, err := net.InterfaceByName(data.PPPInterface)
	if err != nil {
		return readLeaseSummary(data)
	}

	if data.PPPState == "missing" || data.PPPState == "unknown" {
		if iface.Flags&net.FlagUp != 0 {
			data.PPPState = "up"
		} else {
			data.PPPState = "down"
		}
	}

	addrs, err := iface.Addrs()
	if err != nil {
		return readLeaseSummary(data)
	}

	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}

		ip := ipNet.IP
		if ip == nil {
			continue
		}

		if ip4 := ip.To4(); ip4 != nil {
			data.IPv4 = ip4.String()
			if data.PPPState == "unknown" {
				data.PPPState = "up"
			}
			continue
		}

		if data.IPv6 == "not assigned" {
			data.IPv6 = ip.String()
			if data.PPPState == "unknown" {
				data.PPPState = "up"
			}
		}
	}

	return readLeaseSummary(data)
}

func loadConfig() pageData {
	return pageData{
		PPPInterface:   getenvDefault("ROUTER_PPP_INTERFACE", "ppp0"),
		LANInterface:   getenvDefault("ROUTER_LAN_INTERFACE", "enp2s0"),
		LANAddress:     getenvDefault("ROUTER_LAN_ADDRESS", "192.168.1.1/24"),
		LocalDomain:    getenvDefault("ROUTER_LOCAL_DOMAIN", "home.arpa"),
		DHCPRangeStart: getenvDefault("ROUTER_DHCP_RANGE_START", "192.168.1.100"),
		DHCPRangeEnd:   getenvDefault("ROUTER_DHCP_RANGE_END", "192.168.1.200"),
		DHCPLeaseTime:  getenvDefault("ROUTER_DHCP_LEASE_TIME", "12h"),
		DHCPRouter:     getenvDefault("ROUTER_DHCP_ROUTER", "192.168.1.1"),
		DHCPDNS:        getenvDefault("ROUTER_DHCP_DNS", "192.168.1.1"),
		DHCPLeasesFile: getenvDefault("ROUTER_DHCP_LEASES_FILE", "/var/lib/misc/dnsmasq.leases"),
		DHCPHostsFile:  strings.TrimSpace(os.Getenv("ROUTER_DHCP_HOSTS_FILE")),
	}
}

// landingMux serves the LAN landing page and nothing else. Kept separate from
// the peers mux so that a route added here cannot become mesh-only by
// accident, and a peers route cannot become LAN-reachable by forgetting a
// check.
// registerStatusRoutes adds the read-only status routes: the landing page, the
// uplink history and the metrics endpoint.
//
// Registered on both listeners, which is the one place the two overlap. They
// are read-only and describe the router rather than any device on it, so there
// is nothing here that the LAN should not see — and the uplink history in
// particular is most wanted from the LAN, during the outage it is recording.
//
// showPeers is set only by the mesh mux, so the link to the peers list appears
// exactly where the link works.
func registerStatusRoutes(mux *http.ServeMux, config pageData, tmpl *template.Template, uplink *uplinkService, aps *apMonitor, nav navSource, showPeers bool) {
	// The stylesheet every page links. Registered here because this function is
	// the one thing both listeners run, and a page served over the mesh with no
	// stylesheet is what the LAN-only alternative would produce.
	mux.HandleFunc("GET /style.css", serveStylesheet)

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		state := readSystemState(config)
		state.ShowPeers = showPeers
		state.Nav = nav.data("status", showPeers)
		if uplink != nil {
			state.Uplink = uplink.band()
		}
		// Read from the last cycle rather than probed here: a page that pings
		// three access points before it renders is a page that takes seconds to
		// load, and takes longest exactly when one of them is off.
		if aps != nil {
			state.AccessPoints = aps.reports()
			// On both listeners, unlike every other mutation: the reboot button
			// is wanted from the LAN too, so it and its route below are the one
			// deliberate exception to the read-only split. The same-origin guard
			// on the handler is what stands in for the listener split here.
			state.APRebootEnabled = aps.canReboot()
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := tmpl.Execute(w, state); err != nil {
			log.Printf("render template: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
		}
	})

	// The AP reboot action, on both listeners. This is the one mutation the LAN
	// listener carries: the button is wanted without the mesh, e.g. from a phone
	// on the wifi the AP serves. Registered here rather than in meshMux so the
	// button the page renders always has a route behind it. Guarded by the same
	// origin check the peer and tunnel actions use.
	if aps.canReboot() {
		mux.HandleFunc("POST /ap/reboot", aps.handleReboot)
	}

	// These exist only when probing is configured. A router without it serves
	// exactly the pages it served before the feature, and in particular does
	// not answer /metrics with an empty body that a scrape would happily
	// record as zero.
	if uplink != nil {
		mux.HandleFunc("/uplink", uplink.pageHandler(nav, showPeers))
		mux.HandleFunc("/uplink/", uplink.pageHandler(nav, showPeers))
		mux.HandleFunc("/metrics", uplink.handleMetrics)
	}
}

// landingMux is what the LAN listener serves: the status page, and the AP
// reboot action that goes with it. It carries no route that can see or change a
// LAN device — the peers list and the per-device pages stay on the mesh.
//
// The AP reboot is the one mutation here, added deliberately because it is
// wanted from the LAN the AP serves; it is guarded by an origin check rather
// than by the listener split. The split between this and meshMux is still the
// enforcement for everything else: a peers route is registered in exactly one
// function, called from exactly one mux, so making a peers page LAN-reachable
// takes a deliberate edit rather than a forgotten check inside a handler.
func landingMux(config pageData, tmpl *template.Template, uplink *uplinkService, aps *apMonitor, nav navSource) *http.ServeMux {
	mux := http.NewServeMux()
	registerStatusRoutes(mux, config, tmpl, uplink, aps, nav, false)
	return mux
}

// meshMux is what the mesh listener serves: everything the LAN gets, plus the
// peers list and the per-device pages.
//
// The status routes are duplicated here rather than the mesh being a redirect
// to the LAN address, because the mesh is reachable when the LAN is not — from
// another site, or from a phone on the tunnel — and a status page that only
// answers on the LAN is unavailable in most of the situations that send you
// looking for it.
func meshMux(config pageData, tmpl *template.Template, uplink *uplinkService, aps *apMonitor, peers *peersServer, nav navSource) *http.ServeMux {
	mux := http.NewServeMux()
	registerStatusRoutes(mux, config, tmpl, uplink, aps, nav, true)
	peers.registerRoutes(mux)
	// The tunnel switch, on this listener only. Taken from the nav source
	// rather than passed in beside it so that the entry in the strip and the
	// routes behind it are decided by one field: a router where the strip
	// offers /vpn and the mux does not serve it would be a 404 on the one page
	// that changes what the WAN can reach.
	if nav.vpn != nil {
		nav.vpn.registerRoutes(mux)
	}
	return mux
}

// startUplink brings up probing if it is configured.
//
// Opt-in on the database path, the same idiom as ROUTER_CAPTURE_DIR: unset
// means no socket, no goroutines, no file and no routes. Every failure here is
// logged and returns nil rather than being fatal — the landing page is the
// service's job, and losing it because a raw socket could not be opened would
// turn a missing capability into a full outage.
func startUplink(staticRoot string, pppIface string) *uplinkService {
	dbPath := strings.TrimSpace(os.Getenv("ROUTER_UPLINK_DB"))
	if dbPath == "" {
		return nil
	}

	anchors, err := parseAnchors(os.Getenv("ROUTER_UPLINK_ANCHORS"))
	if err != nil {
		log.Printf("uplink probing disabled: %v", err)
		return nil
	}

	retention := 90 * 24 * time.Hour
	if raw := strings.TrimSpace(os.Getenv("ROUTER_UPLINK_RETENTION_DAYS")); raw != "" {
		days, err := strconv.Atoi(raw)
		if err != nil || days <= 0 {
			log.Printf("uplink probing disabled: ROUTER_UPLINK_RETENTION_DAYS %q is not a positive number", raw)
			return nil
		}
		retention = time.Duration(days) * 24 * time.Hour
	}

	tmpl, err := template.ParseFiles(filepath.Join(staticRoot, "uplink.html"), filepath.Join(staticRoot, "nav.html"))
	if err != nil {
		log.Printf("uplink probing disabled: parse uplink template: %v", err)
		return nil
	}

	store, err := openUplinkStore(dbPath)
	if err != nil {
		log.Printf("uplink probing disabled: %v", err)
		return nil
	}

	prober, err := newUplinkProber(store, pppIface, anchors, retention)
	if err != nil {
		log.Printf("uplink probing disabled: %v", err)
		store.Close()
		return nil
	}

	// One prune at start rather than waiting an hour, so a router that has
	// been off for a month does not serve a page built from expired rows.
	if err := store.prune(time.Now().Add(-retention)); err != nil {
		log.Printf("uplink: %v", err)
	}

	prober.run()
	log.Printf("uplink probing %d anchors plus the PPP peer, keeping %d days in %s",
		len(anchors), int(retention.Hours()/24), dbPath)

	return &uplinkService{store: store, prober: prober, tmpl: tmpl, retention: retention}
}

// meshListenAddr validates that the mesh listen address names a specific
// interface address. A wildcard bind would accept connections on every
// interface including the LAN, which would defeat the entire reason the peers
// routes live on a separate listener.
func meshListenAddr(raw string) (string, error) {
	host, port, err := net.SplitHostPort(raw)
	if err != nil {
		return "", fmt.Errorf("not host:port: %w", err)
	}
	if host == "" {
		return "", fmt.Errorf("wildcard address: the peers routes must bind one interface address, not every interface")
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return "", fmt.Errorf("host %q is not an IP address: %w", host, err)
	}
	if addr.IsUnspecified() {
		return "", fmt.Errorf("wildcard address %q: the peers routes must bind one interface address, not every interface", host)
	}
	if port == "" {
		return "", fmt.Errorf("missing port")
	}
	return raw, nil
}

// startMeshServer validates configuration and starts the mesh listener in its
// own goroutine. Failures are returned rather than fatal: no mesh listener
// means no firewall mutations, which already fails closed in the way that
// matters, and taking the LAN status page down over a mesh misconfiguration
// would turn a bind mistake into a full outage.
//
// The mesh serves the status routes as well as the peers routes, so the
// landing config and templates are threaded through here too.
func startMeshServer(meshAddr, lanCIDR, asnPath, staticRoot string, config pageData, tmpl *template.Template, uplink *uplinkService, aps *apMonitor, nav navSource) error {
	validAddr, err := meshListenAddr(meshAddr)
	if err != nil {
		return fmt.Errorf("invalid ROUTER_LISTEN_MESH %q: %w", meshAddr, err)
	}
	prefix, err := netip.ParsePrefix(lanCIDR)
	if err != nil {
		return fmt.Errorf("ROUTER_LAN_CIDR %q: %w", lanCIDR, err)
	}
	// Both attribution tables, loaded now and re-read whenever geoip-update
	// replaces either file. Degrade rather than fail: attribution is the
	// nice-to-have, the peer list is the point, and a router that has not
	// downloaded them yet gets empty columns rather than wrong ones.
	tables := newTableWatcher(asnPath, strings.TrimSpace(os.Getenv("ROUTER_GEOIP_FILE")))
	go tables.watch(tableWatchInterval)
	peersTmpl, err := template.ParseFiles(filepath.Join(staticRoot, "peers.html"), filepath.Join(staticRoot, "nav.html"))
	if err != nil {
		return fmt.Errorf("parse peers template: %w", err)
	}
	indexTmpl, err := template.ParseFiles(filepath.Join(staticRoot, "peers-index.html"), filepath.Join(staticRoot, "nav.html"))
	if err != nil {
		return fmt.Errorf("parse peers index template: %w", err)
	}
	leasesPath := os.Getenv("ROUTER_DHCP_LEASES_FILE")
	peers := newPeersServer(prefix, tables, peersTmpl, indexTmpl, leasesPath)
	peers.namer = newNamerFromEnv()
	// Set unconditionally, unlike lowTrust below. The neighbour table is no
	// longer just the low-trust pool's way of finding a MAC — it is what tells
	// the page which IPv6 addresses belong to the device whose page it is, so
	// without it every device is IPv4-only again.
	peers.neighbours = newNeighbourCache(readNeighbours(getenvDefault("ROUTER_LAN_INTERFACE", "enp2s0")))
	// Captures are opt-in on the directory: a router without one keeps every
	// route and every pixel it had before this feature.
	if dir := strings.TrimSpace(os.Getenv("ROUTER_CAPTURE_DIR")); dir != "" {
		peers.captures = newCaptureManager(dir, getenvDefault("ROUTER_LAN_INTERFACE", "enp2s0"))
		go peers.captures.sweepEvery(captureSweepEvery)
	}
	// The low-trust pool is opt-in the same way, and for a stronger reason: the
	// nft sets, the drop chains and the `lowtrust` tool are all gated on one
	// NixOS option, so on a router without it these lookups can only fail and
	// the buttons can only promise drops nothing implements. Unset leaves both
	// fields nil, which mux() and the template read as "no such feature".
	if strings.TrimSpace(os.Getenv("ROUTER_LOWTRUST")) != "" {
		peers.lowTrust = lowTrustMembership
	}
	peers.nav = nav
	go serveMeshWithRetry(validAddr, meshMux(config, tmpl, uplink, aps, peers, nav))
	return nil
}

const (
	// The mesh address lives on sifr0, assigned asynchronously by nebula.
	// At boot the bind can fail with "cannot assign requested address"
	// before nebula has finished bringing the interface up, even though
	// router-web is already ordered after the nebula unit — "started" does
	// not mean "address assigned". These bound retries give that race a
	// minute to resolve itself instead of leaving the peers page dead until
	// someone restarts the unit by hand.
	meshListenAttempts   = 6
	meshListenRetryDelay = 10 * time.Second
)

// serveMeshWithRetry binds the mesh listener, retrying a bounded number of
// times when the bind itself fails. It runs in its own goroutine and never
// exits the process and never touches the LAN listener: a mesh bind that
// never succeeds just leaves the peers page disabled, logged once, at the
// end.
func serveMeshWithRetry(addr string, handler http.Handler) {
	var listener net.Listener
	var err error
	for attempt := 1; attempt <= meshListenAttempts; attempt++ {
		listener, err = net.Listen("tcp", addr)
		if err == nil {
			break
		}
		log.Printf("peers page: bind %s attempt %d/%d: %v", addr, attempt, meshListenAttempts, err)
		if attempt < meshListenAttempts {
			time.Sleep(meshListenRetryDelay)
		}
	}
	if err != nil {
		log.Printf("peers page disabled: %v", err)
		return
	}

	log.Printf("serving peers page on http://%s", addr)
	server := &http.Server{Handler: handler}
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		log.Printf("peers page disabled: %v", err)
	}
}

func main() {
	root := flag.String("root", ".", "directory containing static files")
	addr := flag.String("addr", ":80", "listen address")
	flag.Parse()
	config := loadConfig()

	staticRoot, err := filepath.Abs(*root)
	if err != nil {
		log.Fatalf("resolve static root: %v", err)
	}

	indexPath := filepath.Join(staticRoot, "index.html")
	if _, err := os.Stat(indexPath); err != nil {
		log.Fatalf("missing index.html in %s: %v", staticRoot, err)
	}

	// nav.html defines the strip every page invokes; parsed alongside each page
	// so one file is the only place a section is added.
	tmpl, err := template.ParseFiles(indexPath, filepath.Join(staticRoot, "nav.html"))
	if err != nil {
		log.Fatalf("parse template %s: %v", indexPath, err)
	}

	lanAddr := getenvDefault("ROUTER_LISTEN_LAN", *addr)
	meshAddr := os.Getenv("ROUTER_LISTEN_MESH")
	asnPath := os.Getenv("ROUTER_IP2ASN_FILE")
	lanCIDR := os.Getenv("ROUTER_LAN_CIDR")

	uplink := startUplink(staticRoot, config.PPPInterface)
	aps := startAccessPoints()
	vpn := startVPN(staticRoot)
	// Read once rather than per render: the hostname cannot change under a
	// running process, and the nav strip is on every page. Not taken from
	// config, which carries the env-supplied settings and never has it —
	// readSystemState fills that field from os.Hostname on the status page
	// alone, which is exactly the page that needed it before the strip existed.
	navHost := "router"
	if hostname, err := os.Hostname(); err == nil && strings.TrimSpace(hostname) != "" {
		navHost = hostname
	}
	nav := navSource{host: navHost, uplink: uplink, vpn: vpn}
	// The page renders the strip like every other, so it needs the same source.
	// Set after nav is built rather than inside startVPN, which runs before the
	// strip exists.
	if vpn != nil {
		vpn.nav = nav
	}

	lanServer := &http.Server{Addr: lanAddr, Handler: landingMux(config, tmpl, uplink, aps, nav)}

	lanErrs := make(chan error, 1)
	go func() {
		log.Printf("serving landing page on http://%s", lanAddr)
		lanErrs <- lanServer.ListenAndServe()
	}()

	// The peers routes exist only when a mesh address is configured. A router
	// without one behaves exactly as it did before this feature. A mesh
	// startup failure is logged, never fatal: see startMeshServer.
	if meshAddr != "" && lanCIDR != "" {
		if err := startMeshServer(meshAddr, lanCIDR, asnPath, staticRoot, config, tmpl, uplink, aps, nav); err != nil {
			log.Printf("peers page disabled: %v", err)
		}
	}

	if err := <-lanErrs; err != nil && err != http.ErrServerClosed {
		log.Fatalf("server failed: %v", err)
	}
}

// serveStylesheet answers /style.css from the binary rather than from the
// static root.
//
// Embedded because a stylesheet that can go missing is a page that can render
// unstyled, and the failure would show up only on a router where the install
// dropped a file — which is to say, in production and not in a test. The
// templates are read from disk because they are per-router content; this is
// part of the program.
func serveStylesheet(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/css; charset=utf-8")
	// Short rather than long: the pages behind it are live status, someone
	// looking at them during an outage will reload hard, and an hour of stale
	// CSS after a router upgrade is a worse trade than re-sending 8 KB.
	w.Header().Set("Cache-Control", "max-age=300")
	w.Header().Set("ETag", stylesheetETag)
	// A zero modification time deliberately: it suppresses Last-Modified and
	// with it If-Modified-Since handling, so the ETag is the only validator.
	// A client still holding the old date-based copy has no ETag to send, gets
	// a full 200 back, and is on the content-derived validator from then on.
	http.ServeContent(w, r, "style.css", time.Time{}, strings.NewReader(stylesheet))
}
