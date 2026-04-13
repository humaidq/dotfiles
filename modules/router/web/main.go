package main

import (
	"bufio"
	"flag"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
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
}

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

	tmpl, err := template.ParseFiles(indexPath)
	if err != nil {
		log.Fatalf("parse template %s: %v", indexPath, err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := tmpl.Execute(w, readSystemState(config)); err != nil {
			log.Printf("render template: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
		}
	})

	server := &http.Server{
		Addr:    *addr,
		Handler: mux,
	}

	log.Printf("serving %s on http://%s", staticRoot, *addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server failed: %v", err)
	}
}
