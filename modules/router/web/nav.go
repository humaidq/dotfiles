package main

// The navigation strip's data, and the one thing every page has in common.
//
// It is deliberately small. Anything that needs a per-request read to fill in
// would be paid on every page rather than on the one page that shows it, and
// the strip is meant to be the cheapest part of any render.
type navData struct {
	// The router's own name. On the strip because these routers come in pairs
	// with near-identical pages, and reading the wrong one is a mistake that
	// costs real time — the page should answer "which box is this" without
	// being asked.
	Host string
	// The uplink lamp: one of stateOK, stateDegraded, stateDown, stateUnknown,
	// with StateText the same words the band uses. Unknown on a router with no
	// probing, which renders a grey lamp rather than a missing one — a strip
	// whose left end changes shape between pages is not a strip.
	State     string
	StateText string
	// Which entry to mark current: "status", "uplink" or "devices".
	Active string
	// Whether each section is reachable from the listener serving this page.
	// See nav.html for why a link that 404s is worse than a link that is absent.
	ShowUplink bool
	ShowPeers  bool
}

// navSource builds a navData per request from the two things that vary: the
// hostname, which is read once at startup because it cannot change under a
// running process, and the uplink state, which is read live.
//
// Both fields are usable at their zero value: no uplink service means an
// unknown lamp and no /uplink entry, which is exactly a router without probing.
type navSource struct {
	host   string
	uplink *uplinkService
}

func (n navSource) data(active string, showPeers bool) navData {
	nav := navData{
		Host:       n.host,
		State:      stateUnknown,
		StateText:  "unknown",
		Active:     active,
		ShowUplink: n.uplink != nil,
		ShowPeers:  showPeers,
	}
	if n.uplink != nil {
		if band := n.uplink.band(); band != nil {
			nav.State, nav.StateText = band.State, band.StateText
		}
	}
	return nav
}
