# IPv4 service on IPv6-only cellular links

Some SIMs, including T-Mobile US, provide no native IPv4 address. IPv4-only
stream receivers and IPv4 hotspot clients then need translation on the box.
`ceralive-clat.service` supplies this using Debian's packaged tayga. It does not
change modem profiles, reconnect a modem, or use NetworkManager dispatchers.

The image service reads NetworkManager D-Bus device state (activated modem
interfaces only). A native global IPv4 address excludes the link. A stable,
non-temporary IPv6 source, default route (with or without a gateway), and per-link DNS
servers are required. IPv6 DNS comes from `IP6Config.Nameservers` (`aay`),
as specified by the [NM 1.52 introspection XML](https://github.com/NetworkManager/NetworkManager/blob/1.52.0/introspection/org.freedesktop.NetworkManager.IP6Config.xml)
and [NM 1.58 XML](https://github.com/NetworkManager/NetworkManager/blob/1.58.0/introspection/org.freedesktop.NetworkManager.IP6Config.xml).
Link-local resolver scope stays bound to that interface. D-Bus changes
trigger reconciliation, with a ten-second retry for failed discovery or a dead
translator. Manager disappearance withdraws all grants.

The service sends an interface/source-bound AAAA query for `ipv4only.arpa` to
that link's IPv6 DNS servers. Both RFC 7050 sentinel addresses must confirm one
RFC 6052 prefix (/32, /40, /48, /56, /64 or /96). Missing, truncated, ambiguous
or inconsistent responses fail closed. `64:ff9b::/96` is used only when that
same discovery confirms it; there is no guessed fallback. DNS64 is evidence
from the network, not authenticated proof of an operator's identity. Prefixes
are revalidated every 60 seconds and when the address/gateway/DNS grant
changes. A changed prefix withdraws translation until the next retry; existing
flows are not migrated. A failed refresh retains the current translation; three
consecutive failures, spaced 60 seconds apart, withdraw it. A successful refresh
resets the failure count. Each reconciliation repairs owned routes, including
after an interface down/up with an unchanged grant. A route repair error withdraws
only that link and leaves other links reconciling. Unexpected synchronization
errors are logged and the ten-second retry remains scheduled. Status-write
faults are logged without withdrawing a working translator. Teardown continues
after cleanup command timeouts and keeps the recovery journal. Before retrying a
still-wanted link, startup replays that journal ahead of discovery and ownership
checks. An interrupted replay keeps the journal for the next retry; only a
completed replay removes it.
Snapshots refresh on each reconciliation (at most ten seconds apart while
discovery is healthy).

Each link gets `clat<ifindex>`, an IPv4 /32 in reserved service space
`10.254.0.0/19`, and a private IPv6 mapping in `fd46:4:4::/112`.
Reserve these ranges for this service; overlap with a local IPv4 subnet fails
closed. Indexes above 8191 fail closed.
Tayga translates IPv4 into the discovered prefix. IPv6 SNAT uses the actual
uplink address, allowing raw-IP /128 grants without assuming an extra routed
IPv6 address or SLAAC /64. Reply conntrack restores the private mapping and
routes it to that link's TUN. Each translator drops to nobody:nogroup after
opening its TUN. The controller retains only network administration/raw socket
and identity-drop capabilities plus CAP_KILL (to signal its tracked child
after that child drops UID), with systemd filesystem/device restrictions.

Source rules (priority 10000+index) select tables 46000+index for IPv4 sources
and private IPv6 mappings. An IPv4 fallback default of metric 46000+index
lets hotspot clients use an available translator; ordinary lower-metric native
routes take precedence. This is availability/failover, not hotspot bonding.
NAT44 on each TUN supports forwarded IPv4 clients. Existing hotspot ownership,
IPv4 forwarding, firewall and client admission remain with NetworkManager and
the sharing service. This service owns its `inet clat_<index>` NAT/filter table.
Its IPv6 forward filter permits only the mapped source toward the discovered
prefix and established replies on that translator. If IPv6 forwarding was
previously disabled, unrelated IPv6 forwarding is dropped while CLAT is active;
existing IPv4 hotspot admission remains with its owner. The shared IPv4/IPv6
TUN keeps the uplink MTU so full-size incoming IPv6 packets fit. Both IPv4
default routes through it use plain `mtu` at uplink MTU minus 20 bytes for
translation overhead (minimum IPv4 MTU 1280; smaller uplinks fail with a
diagnostic). The route MTU stays unlocked so default local sockets retain DF
and path-MTU discovery; locking it clears DF and makes tayga fragment ordinary
stream-sized UDP and TCP packets into IPv6 fragments. TCP SYN and SYN-ACK MSS
is capped at that IPv4 MTU minus 40, for hotspot forwarding in both directions
and locally originated traffic.
Smaller advertised MSS values are preserved. This avoids an extra path-MTU
discovery round for full-sized TCP traffic; non-TCP traffic remains subject
to the IPv4 route MTU.
It never flushes another owner's rules or tables.

IPv6 forwarding is needed for translation. The controller enables the global
switch while preserving devices' forwarding values. It does not change
`accept_ra` or per-interface forwarding on NM-managed links: NetworkManager
continues processing router advertisements in userspace. Owned
routes/rules/firewall/TUNs are removed on withdrawal. A root-only runtime cleanup
journal, written before each resource creation, and
ExecStopPost handle service failure/restart. The previous global forwarding
switch is restored when no translators remain and on service shutdown. The stock single-instance tayga service
is masked; the image installs no replacement translator build.

## Read-only CeraUI contract

`/run/ceralive/clat/<ifindex>.json` is an atomic, world-readable snapshot in a
root-writable directory. Readers never write it or control the service.

```json
{"schema_version":1,"interface":"wwan0","tun":"clat3","prefix":"64:ff9b::/96","ipv4":"10.254.0.3","state":"up","last_error":null,"updated_at":1794614400}
```

`state` is `starting`, `up`, `down` or `error`; `prefix` can be null before
successful discovery. `last_error` is null or a diagnostic string. Missing
service/file, unknown schema, stale timestamp or any state other than `up`
means unavailable. Readers must also check the service is running and TUN
exists; a snapshot alone is not a liveness lease. Use `ipv4` as the sender bind
source, and `tun` if specifying an IPv4 bind device; the cellular interface has
no IPv4 address. Withdraw that source when unavailable. This change supplies
the image contract only; CeraUI consumption is a separate change.

## Tests

`bats tests/cellular-clat.bats` runs offline discovery/admission tests.
`CERALIVE_RUN_CLAT_CONTRACT=required ./run-tests` runs the complete network
contract. CI uses `CERALIVE_RUN_CLAT_CONTRACT=service` to run its service and UDP
transport coverage without requiring first-party sender/receiver binaries; the
complete mode additionally checks SRTLA. Missing dependencies fail the enabled
gate.

`tests/clat-netns.py` needs root, iproute2, nftables, tayga, Python with
dnspython, dbus-python and PyGObject, and real
`srtla_send` / `srtla_rec` binaries. Run it only inside fresh PID, mount and
network namespaces, with a shell as PID 1. Set `CLAT_TEST_TAYGA`,
`CLAT_TEST_SENDER` and `CLAT_TEST_RECEIVER` to installed test binary paths.
It uses synthetic veths and a local DNS64/NAT64 peer with no external uplink.
It checks two simultaneously active translators, source-bound IPv4 transport,
a real sender/IPv4 receiver, hotspot forwarding, native-IPv4 exclusion,
link withdrawal with a surviving second link, teardown, and absent/bad prefixes.
A private D-Bus fixture also runs the actual service through dual-stack, two
IPv6-only grants and link-loss states. Foreign-table refusal, crash-journal
cleanup and restoration of the global forwarding switch are also exercised.
It also checks route repair after a flap, preserved NM sysctls, TUN MTU and
DF-forced full-size datagrams without extra PTB responses, default-socket UDP
(1332, 1372 and 1452-byte payloads) and TCP bulk sends with zero IPv6 fragments
from both the box and hotspot, TCP MSS (including smaller advertised values),
and the scoped IPv6 filter with forwarding initially disabled or already
enabled by another owner. Tayga runs in foreground mode without debug output.
The real service lifecycle runs with the unit's restricted capability set and
no-new-privileges.
This proves packet forwarding, not encrypted SRT/video or carrier hardware.
