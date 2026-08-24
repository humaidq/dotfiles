package main

import (
	"fmt"
	"net"
	"strconv"
	"time"

	"golang.org/x/crypto/ssh"
)

// Rebooting an access point over SSH.
//
// The two IP-COM firmware families in aps.go are rebooted by logging into their
// web UI, because that is the only interface they offer. UniFi hardware is the
// other way round: there is no local web UI to log into at all — the controller
// owns that — but the device runs a full SSH server whose login the controller
// sets. So this is a second protocol rather than a third variant of the first,
// and it lives in its own file for that reason.
//
// Done in Go rather than by shelling out to ssh, matching how the HTTP reboots
// already work. A subprocess would mean either a password on the command line,
// visible in the process table to every user on the router, or a temporary file
// holding one; the library takes it as a string and neither happens.

// How long the whole dial-authenticate-run exchange gets. Shorter than the HTTP
// path's budget because there is no login page to render and no redirect to
// follow: an AP that has not answered the key exchange in this long is not
// going to.
const apSSHTimeout = 12 * time.Second

// rebootOverSSH logs in and runs reboot.
//
// The interesting part is what counts as success. A box asked to reboot tears
// the connection down while doing it, so the command frequently never returns
// an exit status at all — the session just ends. Treating that as a failure
// would report every successful reboot as an error, so a lost connection after
// the command was accepted is read as the reboot having started, which is the
// only thing that could have caused it.
func rebootOverSSH(point accessPoint) error {
	config := &ssh.ClientConfig{
		User: point.Username,
		Auth: []ssh.AuthMethod{ssh.Password(point.Password)},
		// Not pinned, and deliberately so. These are devices on this router's
		// own LAN, identified by an address this router hands out and reaches
		// over a switch it owns; there is no position from which to interpose
		// that does not already have the LAN. Pinning would also mean carrying
		// a key per AP that changes whenever the controller re-provisions one,
		// and failing the reboot when it does.
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         apSSHTimeout,
	}

	addr := net.JoinHostPort(point.Addr.String(), strconv.Itoa(22))
	client, err := ssh.Dial("tcp", addr, config)
	if err != nil {
		return fmt.Errorf("ssh %s: %w", point.Name, err)
	}
	defer client.Close()

	session, err := client.NewSession()
	if err != nil {
		return fmt.Errorf("ssh %s: session: %w", point.Name, err)
	}
	defer session.Close()

	// Run rather than Start-and-wait: the error is inspected below, and the
	// output is discarded because a rebooting box has nothing useful to say.
	err = session.Run("reboot")
	switch err.(type) {
	case nil:
		return nil
	case *ssh.ExitMissingError:
		// The connection went away before an exit status arrived, which is
		// what a successful reboot looks like from here.
		return nil
	}
	// Same for a channel or connection that closed under us.
	if isConnectionClosed(err) {
		return nil
	}
	return fmt.Errorf("ssh %s: reboot: %w", point.Name, err)
}

// isConnectionClosed reports whether an error is the transport going away
// rather than the command being rejected.
//
// Matched on the error text because x/crypto/ssh returns a plain error for a
// closed transport rather than a typed one, and the alternative — treating any
// error as success — would turn a wrong password into a silent no-op that
// reports the AP as rebooted.
func isConnectionClosed(err error) bool {
	if err == nil {
		return false
	}
	switch err.Error() {
	case "EOF", "ssh: unexpected packet in response to channel open: <nil>":
		return true
	}
	return false
}
