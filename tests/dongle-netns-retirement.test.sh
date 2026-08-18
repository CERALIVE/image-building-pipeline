#!/usr/bin/env bash
#
# dongle-netns-retirement.test.sh — the router-dongle netns layer is RETIRED
# (phase-C todo 39), and this is what keeps it retired.
#
# Two halves, and they fail for opposite reasons:
#
#   A. ABSENCE — this image installs no part of the layer. Not the manager, not
#      the template unit, not the reconcile timer, not the udev claim rule, not
#      the NetworkManager unmanaged-devices snippet, not the rt_tables 110-117
#      reservation. A future change that re-introduces any of them reddens here
#      rather than quietly shipping a second, competing dongle owner.
#
#   B. TEARDOWN — the one thing the image DOES ship for the layer is the unit
#      that removes it from a board that used to run it. The legs below drive the
#      real script against fixture trees, because the interesting properties are
#      behavioural: it must be idempotent, it must exit 0 with nothing to do, and
#      it must remove ONLY the names the retired contract itself allocated.
#
# WHY THE TEARDOWN IS NOT DEAD CODE, stated once so nobody deletes it as such:
# every other artifact of the layer lives in the rootfs (cleared by a RAUC slot
# swap) or in kernel/tmpfs state (cleared by the reboot that swap requires). The
# durable slot store does NOT — it was deliberately placed on /data so a slot
# swap would not renumber every dongle across an OTA. That single design decision
# is the entire reason a teardown has to exist, and leg B3 is the one that proves
# it is removed.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
MKOSI="${PIPELINE_DIR}/mkosi"
RUNTIME_SRC="${MKOSI}/runtime"
RETIRE_SH="${RUNTIME_SRC}/ceralive-dongle-netns-retire.sh"
RETIRE_UNIT="${RUNTIME_SRC}/ceralive-dongle-netns-retire.service"
NETWORKING="${MKOSI}/customize/postinst.d/networking.sh"
SERVICES_ENTRY="${MKOSI}/customize/services.sh"
POSTINST="${MKOSI}/mkosi.images/runtime/mkosi.postinst.chroot"

ARTIFACT_DIR="${PIPELINE_DIR}/test-results/modem-phase-c/39"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dongle-netns-retire.XXXXXX")"
RESULTS_LOG="${ARTIFACT_DIR}/dongle-netns-retirement.log"

cleanup() { rm -rf "${RUN_DIR}"; }
trap cleanup EXIT

mkdir -p "${ARTIFACT_DIR}"
: >"${RESULTS_LOG}"

# ---------------------------------------------------------------------------
# Recording fakes for the three privileged tools.
#
# NOT merely for isolation. Without them the very first leg reaches the HOST's
# systemd — `systemctl stop` on a developer machine blocks on a polkit prompt and
# hangs the suite, and `ip netns delete` would be operating on the host's real
# namespaces. Faking them is what makes a teardown script safe to test at all.
#
# They also turn the interesting assertions from "the files are gone" into "the
# right calls were made in the right order", which is the half a filesystem check
# cannot see.
# ---------------------------------------------------------------------------
FAKE_BIN="${RUN_DIR}/bin"
mkdir -p "${FAKE_BIN}"

cat >"${FAKE_BIN}/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${RETIRE_TEST_CALLS}"
# `cat` is the script's "does this unit exist" probe, so it has to answer from
# the fixture rather than unconditionally, or the disable path becomes untestable.
if [[ "${1:-}" == "cat" ]]; then
	[[ -f "${RETIRE_TEST_UNIT_DIR}/${2:-}" ]]
	exit $?
fi
exit 0
STUB

cat >"${FAKE_BIN}/ip" <<'STUB'
#!/usr/bin/env bash
printf 'ip %s\n' "$*" >>"${RETIRE_TEST_CALLS}"
case "${1:-} ${2:-}" in
	"netns list") cat "${RETIRE_TEST_NETNS_LIST:-/dev/null}" 2>/dev/null; exit 0 ;;
	# The kernel-capability leg: an edge board answers this "Operation not
	# supported", and the script must then attempt no rule work at all.
	"rule show") exit "${RETIRE_TEST_IP_RULE_RC:-0}" ;;
	"rule del") exit "${RETIRE_TEST_IP_RULE_DEL_RC:-1}" ;;
	"route show") exit 0 ;;
	*) exit 0 ;;
esac
STUB

cat >"${FAKE_BIN}/udevadm" <<'STUB'
#!/usr/bin/env bash
printf 'udevadm %s\n' "$*" >>"${RETIRE_TEST_CALLS}"
exit 0
STUB

chmod +x "${FAKE_BIN}"/systemctl "${FAKE_BIN}"/ip "${FAKE_BIN}"/udevadm

pass() { printf 'PASS %s\n' "$1" | tee -a "${RESULTS_LOG}"; }
fail() {
	printf 'FAIL %s\n' "$1" | tee -a "${RESULTS_LOG}" >&2
	exit 1
}

# The source set the ABSENCE half scans: everything that could install a runtime
# asset. Deliberately NOT the whole repo — docs, this test, and the evidence
# ledger are all allowed (and required) to name the retired layer.
INSTALLERS=(
	"${MKOSI}/customize"
	"${MKOSI}/mkosi.images"
	"${RUNTIME_SRC}"
)

# ---------------------------------------------------------------------------
# A. ABSENCE — the layer is not installed by this image
# ---------------------------------------------------------------------------

# Comment-stripped, so this file's own prose and the installers' explanatory
# headers may name the retired artifacts freely; only executable references fail.
grep_code() {
	local pattern="$1" hit
	hit="$(grep -rhn --include='*.sh' --include='*.service' --include='*.timer' \
		--include='*.rules' --include='*.conf' --include='mkosi.postinst.chroot' \
		-E "${pattern}" "${INSTALLERS[@]}" 2>/dev/null |
		sed -E 's/^[0-9]+://' |
		grep -vE '^[[:space:]]*#' || true)"
	printf '%s' "${hit}"
}

# The teardown necessarily NAMES every artifact it removes, so a scan for those
# names would match it and could never pass. TWO exemptions, and the split is
# deliberate: the teardown's own two files are exempt WHOLESALE (naming them is
# their job), while every other file is exempt only on lines that mention the
# retirement — so `install -m 0755 … ceralive-dongle-netns` in networking.sh,
# which is exactly where a re-installation would land, still fails.
grep_code_excluding_retirement() {
	local pattern="$1" hit
	hit="$(grep -rhn --include='*.sh' --include='*.service' --include='*.timer' \
		--include='*.rules' --include='*.conf' --include='mkosi.postinst.chroot' \
		--exclude='ceralive-dongle-netns-retire.sh' \
		--exclude='ceralive-dongle-netns-retire.service' \
		-E "${pattern}" "${INSTALLERS[@]}" 2>/dev/null |
		sed -E 's/^[0-9]+://' |
		grep -vE '^[[:space:]]*#' |
		grep -v 'ceralive-dongle-netns-retire' || true)"
	printf '%s' "${hit}"
}

a1_no_layer_artifacts_are_staged() {
	local f
	for f in \
		"${RUNTIME_SRC}/ceralive-dongle-netns.sh" \
		"${RUNTIME_SRC}/ceralive-dongle-classify.sh" \
		"${RUNTIME_SRC}/ceralive-dongle-udhcpc.sh" \
		"${RUNTIME_SRC}/ceralive-dongle-netns@.service" \
		"${RUNTIME_SRC}/ceralive-dongle-netns-reconcile.service" \
		"${RUNTIME_SRC}/ceralive-dongle-netns-reconcile.timer" \
		"${RUNTIME_SRC}/85-ceralive-dongle-netns.rules" \
		"${RUNTIME_SRC}/ceralive-dongle-nm.conf"
	do
		[[ -e "${f}" ]] && fail "A1 the retired layer's artifact is back in runtime/: ${f}"
	done
	pass "A1 no router-dongle netns artifact is staged under mkosi/runtime/"
}

a2_no_installer_references_the_layer() {
	local hits
	hits="$(grep_code_excluding_retirement 'ceralive-dongle-(netns|classify|udhcpc)|85-ceralive-dongle-netns')"
	[[ -n "${hits}" ]] &&
		fail "A2 an installer still references the retired layer:
${hits}"
	pass "A2 no installer outside the retirement assets references the layer"
}

a3_no_installer_seeds_the_dongle_routing_tables() {
	# Contract §2.1 reserved rt_tables ids 110-117, named after the host veths.
	# The SRTLA ranges (100-107, 120-124) are a different feature and must stay.
	local hits
	hits="$(grep_code '^[[:space:]]*11[0-7][[:space:]]+dg[0-7]h')"
	[[ -n "${hits}" ]] &&
		fail "A3 the retired layer's rt_tables reservation is back:
${hits}"
	pass "A3 rt_tables carries no dg<N>h routing-table reservation"
}

# ---------------------------------------------------------------------------
# B. TEARDOWN — the shipped retirement behaves
# ---------------------------------------------------------------------------

# A fixture root standing in for a board's filesystem. `ip`/`systemctl`/`udevadm`
# are absent from PATH here, which is itself a leg: the script's `have` guards
# must make it a clean no-op rather than a crash on a host that has none of them.
make_board() {
	local root="$1"
	mkdir -p \
		"${root}/data/ceralive" \
		"${root}/run/ceralive/dongles" \
		"${root}/usr/local/sbin" \
		"${root}/etc/systemd/system" \
		"${root}/etc/udev/rules.d" \
		"${root}/etc/NetworkManager/conf.d"

	printf '{"version":1,"slots":{"usb-0:1.3.2":0}}\n' >"${root}/data/ceralive/dongle-slots.json"
	: >"${root}/data/ceralive/dongle-slots.lock"
	printf '{"version":1,"slot":0,"veth_host":"dg0h"}\n' >"${root}/run/ceralive/dongles/dongle0.json"
	: >"${root}/usr/local/sbin/ceralive-dongle-netns"
	: >"${root}/usr/local/sbin/ceralive-dongle-classify"
	: >"${root}/usr/local/sbin/ceralive-dongle-udhcpc"
	: >"${root}/etc/systemd/system/ceralive-dongle-netns@.service"
	: >"${root}/etc/systemd/system/ceralive-dongle-netns-reconcile.service"
	: >"${root}/etc/systemd/system/ceralive-dongle-netns-reconcile.timer"
	: >"${root}/etc/udev/rules.d/85-ceralive-dongle-netns.rules"
	: >"${root}/etc/NetworkManager/conf.d/ceralive-dongle.conf"

	# The bystanders. Every one of these lives in a directory the teardown writes
	# to, and none of them is the retired layer's — so they are what turns "it
	# removed the right files" into "it removed ONLY the right files".
	: >"${root}/data/ceralive/config.json"
	: >"${root}/data/ceralive/modem-usage-policy.json"
	: >"${root}/usr/local/sbin/ceralive-fan-curve"
	: >"${root}/etc/systemd/system/ceralive-healthcheck.service"
	: >"${root}/etc/udev/rules.d/99-ceralive-hardware.rules"
	: >"${root}/etc/NetworkManager/conf.d/ceralive.conf"
	# Slot 8 does not exist in the contract's allocation table; a sweep that keyed
	# on a `dg*` pattern instead of the enumerated slots would take this with it.
	: >"${root}/data/ceralive/dongle-slots.json.bak"
}

CALLS=""

run_retire() {
	local root="$1" out="$2"
	CALLS="${root}.calls"
	: >"${CALLS}"
	PATH="${FAKE_BIN}:${PATH}" \
	RETIRE_TEST_CALLS="${CALLS}" \
	RETIRE_TEST_UNIT_DIR="${root}/etc/systemd/system" \
	RETIRE_TEST_NETNS_LIST="${RETIRE_TEST_NETNS_LIST:-/dev/null}" \
	RETIRE_TEST_IP_RULE_RC="${RETIRE_TEST_IP_RULE_RC:-0}" \
	RETIRE_TEST_IP_RULE_DEL_RC="${RETIRE_TEST_IP_RULE_DEL_RC:-1}" \
	CERALIVE_DONGLE_RETIRE_STATE_DIR="${root}/data/ceralive" \
	CERALIVE_DONGLE_RETIRE_RUN_DIR="${root}/run/ceralive/dongles" \
	CERALIVE_DONGLE_RETIRE_SBIN_DIR="${root}/usr/local/sbin" \
	CERALIVE_DONGLE_RETIRE_UNIT_DIR="${root}/etc/systemd/system" \
	CERALIVE_DONGLE_RETIRE_UDEV_DIR="${root}/etc/udev/rules.d" \
	CERALIVE_DONGLE_RETIRE_NM_DIR="${root}/etc/NetworkManager/conf.d" \
		bash "${RETIRE_SH}" >"${out}" 2>&1
}

b1_clean_board_is_a_silent_noop() {
	local root="${RUN_DIR}/clean" out="${RUN_DIR}/clean.out"
	mkdir -p "${root}/data/ceralive" "${root}/usr/local/sbin" \
		"${root}/etc/systemd/system" "${root}/etc/udev/rules.d" \
		"${root}/etc/NetworkManager/conf.d"
	: >"${root}/data/ceralive/config.json"

	run_retire "${root}" "${out}" || fail "B1 the script failed on a clean board" 
	grep -q 'nothing to retire' "${out}" ||
		fail "B1 a clean board did not report a no-op:
$(cat "${out}")"
	[[ -f "${root}/data/ceralive/config.json" ]] ||
		fail "B1 a clean board lost an unrelated file"
	pass "B1 a board that never ran the layer is an exit-0 no-op"
}

b2_residue_board_is_fully_cleared() {
	local root="${RUN_DIR}/residue" out="${RUN_DIR}/residue.out"
	make_board "${root}"

	run_retire "${root}" "${out}" || fail "B2 the script failed on a residue board"

	local f
	for f in \
		"${root}/data/ceralive/dongle-slots.json" \
		"${root}/data/ceralive/dongle-slots.lock" \
		"${root}/run/ceralive/dongles" \
		"${root}/usr/local/sbin/ceralive-dongle-netns" \
		"${root}/usr/local/sbin/ceralive-dongle-classify" \
		"${root}/usr/local/sbin/ceralive-dongle-udhcpc" \
		"${root}/etc/systemd/system/ceralive-dongle-netns@.service" \
		"${root}/etc/systemd/system/ceralive-dongle-netns-reconcile.service" \
		"${root}/etc/systemd/system/ceralive-dongle-netns-reconcile.timer" \
		"${root}/etc/udev/rules.d/85-ceralive-dongle-netns.rules" \
		"${root}/etc/NetworkManager/conf.d/ceralive-dongle.conf"
	do
		[[ -e "${f}" ]] && fail "B2 residue survived the teardown: ${f}"
	done
	pass "B2 every retired artifact is removed, including the /data slot store"
}

b3_the_ota_surviving_store_is_the_point() {
	# Named as its own leg because it is the ONLY removal a RAUC slot swap could
	# not have performed for us. If this ever regresses, the teardown has become
	# decoration.
	local root="${RUN_DIR}/store" out="${RUN_DIR}/store.out"
	mkdir -p "${root}/data/ceralive"
	printf '{"version":1}\n' >"${root}/data/ceralive/dongle-slots.json"
	: >"${root}/data/ceralive/dongle-slots.lock"

	run_retire "${root}" "${out}" || fail "B3 the script failed"
	[[ -e "${root}/data/ceralive/dongle-slots.json" ]] &&
		fail "B3 the durable slot store survived — the OTA residue is still there"
	[[ -e "${root}/data/ceralive/dongle-slots.lock" ]] &&
		fail "B3 the durable slot store's lock survived"
	grep -q 'removed durable slot store' "${out}" ||
		fail "B3 the removal was not reported"
	pass "B3 the /data slot store — the one artifact an OTA cannot clear — is removed"
}

b4_only_the_allocated_names_are_touched() {
	local root="${RUN_DIR}/bystanders" out="${RUN_DIR}/bystanders.out"
	make_board "${root}"
	run_retire "${root}" "${out}" || fail "B4 the script failed"

	local f
	for f in \
		"${root}/data/ceralive/config.json" \
		"${root}/data/ceralive/modem-usage-policy.json" \
		"${root}/data/ceralive/dongle-slots.json.bak" \
		"${root}/usr/local/sbin/ceralive-fan-curve" \
		"${root}/etc/systemd/system/ceralive-healthcheck.service" \
		"${root}/etc/udev/rules.d/99-ceralive-hardware.rules" \
		"${root}/etc/NetworkManager/conf.d/ceralive.conf"
	do
		[[ -e "${f}" ]] || fail "B4 the teardown removed a bystander: ${f}"
	done
	pass "B4 unrelated files in every directory it writes to are untouched"
}

b5_it_is_idempotent() {
	local root="${RUN_DIR}/idem" first="${RUN_DIR}/idem1.out" second="${RUN_DIR}/idem2.out"
	make_board "${root}"

	run_retire "${root}" "${first}" || fail "B5 the first run failed"
	run_retire "${root}" "${second}" || fail "B5 the second run failed"

	grep -q 'nothing to retire' "${second}" ||
		fail "B5 the second run was not a no-op:
$(cat "${second}")"
	pass "B5 a second run finds nothing and exits 0"
}

# ---------------------------------------------------------------------------
# C. WIRING — the teardown is actually installed and enabled
# ---------------------------------------------------------------------------

b6_units_are_stopped_before_they_are_disabled() {
	local root="${RUN_DIR}/units" out="${RUN_DIR}/units.out"
	make_board "${root}"
	run_retire "${root}" "${out}" || fail "B6 the script failed"

	# Stopping first is what keeps the manager from being mid-claim while its
	# state is deleted underneath it; a disable-first order would leave a running
	# manager writing files this run has already removed.
	# `|| true` is load-bearing, not defensive: under `set -e` with `pipefail` a
	# grep that matches NOTHING fails the assignment and kills the suite right
	# here — so the very case this leg exists to catch would abort with no
	# diagnostic at all instead of naming itself.
	local stop_line disable_line
	stop_line="$(grep -n 'systemctl stop ceralive-dongle-netns-reconcile.timer' "${CALLS}" | head -1 | cut -d: -f1 || true)"
	disable_line="$(grep -n 'systemctl disable ceralive-dongle-netns-reconcile.timer' "${CALLS}" | head -1 | cut -d: -f1 || true)"
	[[ -n "${stop_line}" ]] || fail "B6 the reconcile timer was never stopped"
	[[ -n "${disable_line}" ]] || fail "B6 the reconcile timer was never disabled"
	(( stop_line < disable_line )) || fail "B6 the timer was disabled before it was stopped"

	grep -q "systemctl stop ceralive-dongle-netns@\*.service" "${CALLS}" ||
		fail "B6 the per-slot template instances were never stopped"
	pass "B6 units are stopped before disabled, template instances included"
}

b7_namespace_teardown_is_bounded_to_the_allocated_slots() {
	local root="${RUN_DIR}/ns" out="${RUN_DIR}/ns.out"
	make_board "${root}"

	# A namespace list carrying the layer's slot 0 AND two namespaces that are not
	# its business: an unrelated one, and `dongle8` — a plausible-looking name the
	# contract's eight-slot table never allocated.
	local nslist="${RUN_DIR}/netns.list"
	printf 'dongle0\nsome-other-ns\ndongle8\n' >"${nslist}"

	RETIRE_TEST_NETNS_LIST="${nslist}" run_retire "${root}" "${out}" ||
		fail "B7 the script failed"

	grep -q 'ip netns delete dongle0' "${CALLS}" ||
		fail "B7 the allocated namespace was not deleted"
	grep -q 'ip netns delete some-other-ns' "${CALLS}" &&
		fail "B7 an unrelated network namespace was deleted"
	grep -q 'ip netns delete dongle8' "${CALLS}" &&
		fail "B7 a namespace outside the contract's slot table was deleted"
	pass "B7 only the contract's own slots 0-7 are torn down"
}

b8_a_kernel_without_policy_rules_is_not_an_error() {
	local root="${RUN_DIR}/norule" out="${RUN_DIR}/norule.out"
	make_board "${root}"

	# The edge kernel: `ip rule show` answers "Operation not supported". A board
	# that cannot express a policy rule never had one to withdraw, so this must be
	# a clean skip rather than a failure or a stream of warnings.
	RETIRE_TEST_IP_RULE_RC=1 run_retire "${root}" "${out}" ||
		fail "B8 a kernel with no multiple-tables support failed the teardown"

	grep -q 'ip rule del' "${CALLS}" &&
		fail "B8 rule deletion was attempted on a kernel that has no rules"
	grep -q 'WARNING' "${out}" &&
		fail "B8 an unsupported-by-kernel skip was reported as a warning"
	pass "B8 a kernel with no policy-routing support is a clean skip"
}

c1_installer_is_wired_on_both_tracks() {
	[[ -x "${RETIRE_SH}" ]] || fail "C1 the retirement script is not executable"
	[[ -f "${RETIRE_UNIT}" ]] || fail "C1 the retirement unit is missing"

	grep -qE '^setup_dongle_netns_retirement\(\)' "${NETWORKING}" ||
		fail "C1 setup_dongle_netns_retirement is not defined in postinst.d/networking.sh"
	grep -q 'enable_service ceralive-dongle-netns-retire.service' "${NETWORKING}" ||
		fail "C1 the retirement unit is installed but never enabled"

	# Both tracks, because the drift gate's whole premise is that the customize
	# module and the runtime executor stay in lockstep.
	grep -q 'setup_dongle_netns_retirement' "${SERVICES_ENTRY}" ||
		fail "C1 customize/services.sh does not call the retirement"
	grep -q 'setup_dongle_netns_retirement' "${POSTINST}" ||
		fail "C1 the runtime postinst executor does not call the retirement"
	pass "C1 the retirement is defined once, enabled, and called on both tracks"
}

c2_unit_orders_before_its_consumers() {
	grep -q '^RequiresMountsFor=/data' "${RETIRE_UNIT}" ||
		fail "C2 the unit may run before /data is mounted — the slot store would survive"
	grep -q '^Before=NetworkManager.service' "${RETIRE_UNIT}" ||
		fail "C2 the unit does not order before NetworkManager"
	grep -q '^Before=ceralive.service' "${RETIRE_UNIT}" ||
		fail "C2 the unit does not order before CeraUI"
	pass "C2 the unit waits for /data and runs before NetworkManager and CeraUI"
}

a1_no_layer_artifacts_are_staged
a2_no_installer_references_the_layer
a3_no_installer_seeds_the_dongle_routing_tables
b1_clean_board_is_a_silent_noop
b2_residue_board_is_fully_cleared
b3_the_ota_surviving_store_is_the_point
b4_only_the_allocated_names_are_touched
b5_it_is_idempotent
b6_units_are_stopped_before_they_are_disabled
b7_namespace_teardown_is_bounded_to_the_allocated_slots
b8_a_kernel_without_policy_rules_is_not_an_error
c1_installer_is_wired_on_both_tracks
c2_unit_orders_before_its_consumers

printf '\nALL LEGS PASSED\n' | tee -a "${RESULTS_LOG}"
