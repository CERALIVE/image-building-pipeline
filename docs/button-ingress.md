# Device-bound browser ingress

Companion CeraUI support consumes the connection-identity contract described
below. This builds on the power-button service. This front door owns the existing
HTTP/80 and HTTPS/443 origins. It replaces nginx for those origins, uses the
existing per-device TLS certificate, and passes static HTTP, preview and normal
RPC to TCP/18080. There is no browser origin or frontend discovery change.
Preview authentication and RPC authentication remain backend responsibilities.
The self-signed certificate still requires the existing browser trust decision.

## Trust boundary

Each current address gets an exact address + SO_BINDTODEVICE socket; IPv6 also
gets V6ONLY and scope index. There is no wildcard or SO_REUSEPORT listener.
Only IPv4 on an UP ARPHRD_ETHER link with a sysfs hardware device and no master
or virtual link kind is eligible. This includes physical wired and Wi-Fi/AP
interfaces, regardless of their names. Bridges, tunnels, VPNs, loopback, veth
and unknown links stay password-only. Incoming VPN packets addressed to a LAN
address cannot reach the device-bound LAN listener. Routed physical networks
outside the listener's subnet also remain password-only.

The netlink subscription precedes the initial snapshot. Every link/address
event, truncated read or overflow unconditionally closes listeners and both
sides of accepted connections, cancels handlers, and advances a generation.
On ENOBUFS, overflow, truncation, interrupted/inconsistent dumps or any loss
of event continuity, retire **all** trusted connections immediately. Rebuild
from a fresh netlink subscription established before a complete address dump;
withhold privileged forwarding until that dump is synchronized with events.
An identical address and mask after a lost remove/readd interval cannot prove
continuity and must never preserve or revive pre-loss evidence.
Only a drained, current snapshot enables trusted admission. A failed bind
withholds trusted admission globally and retries reconciliation. Address
removal/readdition, mask changes, renames and interface identity changes cannot
restore a prior connection's evidence. Events are checked again around async
upstream connection establishment. Restart closes every session.

Each accepted request is inspected. Only an exact GET /ws WebSocket upgrade
without a body or forwarding/reserved metadata can reach a fresh private Unix
connection. Forwarded, all X-Forwarded-* (including empty values), Via and
X-Ceralive-Button-Path route to the ordinary backend unchanged. Host and Origin
are preserved. CONNECT, absolute targets, folded/duplicate headers and ambiguous
framing are refused. Ordinary paths never acquire trusted metadata later.
There is no arbitrary destination or proxy CONNECT capability. CeraUI keeps
its relay sender-ID veto and independently checks interface/address evidence
at every button action. Headerless LAN proxies cannot be distinguished from
the local client itself; physical confirmation is still mandatory.

The helper supplies version, accepted peer, exact listener interface and
accepted destination in X-Ceralive-Button-Path only over the protected Unix
endpoint. The runtime directory belongs to the backend service, root:root 0700;
CeraUI #66 creates its socket 0600. ExecStartPre removes only a root-owned socket
from that verified directory, after systemd has stopped the old service.
Unexpected files/symlinks stop startup. Missing Unix ingress falls back to
ordinary password-only RPC; it cannot authorize button operations.

Limits: 128 admitted connections, 16 KiB handshake, 5 s public/header and TLS
handshakes, 3 s upstream connection, 5 s upstream handshake, 64 KiB copy blocks,
10 s write drain, 120 s idle read, service 128 MiB and 1024 descriptors. Ordinary
HTTP asks the backend to close after one response. WebSocket pumps terminate
both sides together. These limits need realistic preview/load qualification.

## Service ownership

The helper runs root to traverse the private Unix directory and read the TLS
key, with only CAP_NET_RAW (SO_BINDTODEVICE) and CAP_NET_BIND_SERVICE. It has
no network-administration capability. Its filesystem is read-only; home,
devices, privilege escalation, kernel mutation and control groups are protected.
A separate oneshot has only CAP_NET_ADMIN and owns one nft table, dropping
non-loopback TCP/18080 for IPv4 and IPv6. It never flushes another table.
The backend Requires this fence, receives PORT=18080, and cannot bind any of
its fallback TCP ports (80, 8080, 81). Thus backend port failure cannot steal
the public origin. Stop ordering stops the backend before removing the fence.
The fence is essential because the partner backend binds a wildcard address.
The existing nginx service is masked to avoid port conflicts. TLS first-boot
restart propagates to the helper so hostname/certificate changes take effect.

Older backends without the Unix endpoint remain password-only. No backend
package pin, image build or rollout is implied. Rollback must restore nginx,
remove the backend drop-in and stop the front door/fence together while the
backend is stopped; never remove the fence under a running wildcard backend.

## Qualification

`tests/button-ingress-contract.py` uses synthetic identities/socket failures
and real Unix/TCP transports. `tests/button-ingress-kernel.py` runs in disposable
network namespaces, accepts a direct veth path then refuses overlapping-address
packets arriving on a second veth. This verifies the real SO_BINDTODEVICE
operation; a veth is deliberately not production-eligible. The Bats wrapper
requires passwordless isolated namespaces when CERALIVE_RUN_BUTTON_NETNS=required.
It skips with a reason otherwise. No physical board is required.

Before release, on **both ROCK 5B+ and Orange Pi 5 Plus**:

- Verify root directory/socket ownership, firewall IPv4/IPv6 isolation of 18080,
  forbidden fallback ports, stop/start ordering and absence of nginx conflicts.
- Exercise ordinary HTTP, TLS, static assets, preview token enforcement, normal
  password sign-in and authenticated RPC; measure load and idle reconnects.
- Confirm direct Ethernet and Wi-Fi station/AP button admission, physical tap
  confirmation, cancellation and deadline handling. Repeat while live without
  permitting short shutdown. Verify the separate power-board/LED prerequisites.
- Try an overlapping-subnet VPN, bridge, IPv6-only client, relay, public reserved
  metadata and LAN proxy with empty/nonempty forwarding headers: no button
  admission. Keep headerless-LAN-proxy limitations explicit.
- Remove/readd the same address between polls; change mask, rename, disconnect,
  and re-enumerate interfaces; restart helper/backend. An old prompt must never
  finish or revive. Induce netlink overflow and bind failure: ordinary login
  should recover while privileged admission remains withheld during uncertainty.
- Observe actual logind/input timings and fallback separately; check image size
  and actual free-slot reserve on the next authorized image build.

English/Spanish release documentation and these measured checks remain release
prerequisites. Host contracts do not establish physical-button, preview load,
LED, image-size or board qualification.
