#!/usr/bin/env bash
#
# Install DNS + DHCP (dnsmasq) and NTP (chrony) on an offline Ubuntu server
# from the packages bundled alongside this script. Requires no network access.
#
set -euo pipefail

BUNDLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FREE_PORT_53=0
FORCE=0

usage() {
    cat <<EOF
Usage: sudo $0 [options]

  --free-port-53   Disable the systemd-resolved stub listener on 127.0.0.53:53
                   so dnsmasq can bind port 53. This rewrites resolved.conf.d
                   and /etc/resolv.conf. Skipped by default.
  --force          Install even if the host release/arch differs from the bundle.
  -h, --help       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --free-port-53) FREE_PORT_53=1 ;;
        --force)        FORCE=1 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root (use sudo)." >&2; exit 1; }

# --- 1. Verify the bundle matches this host -----------------------------------

for f in MANIFEST SHA256SUMS; do
    [[ -f "$BUNDLE_DIR/$f" ]] || { echo "ERROR: $f missing; bundle is incomplete." >&2; exit 1; }
done

# shellcheck disable=SC1090
bundle_release=$(sed -n 's/^release=//p' "$BUNDLE_DIR/MANIFEST")
bundle_arch=$(sed -n 's/^arch=//p' "$BUNDLE_DIR/MANIFEST")

. /etc/os-release
host_arch=$(dpkg --print-architecture)

mismatch=""
[[ "${ID:-}" == "ubuntu" ]]           || mismatch+=" distro(host=${ID:-unknown} bundle=ubuntu)"
[[ "${VERSION_ID:-}" == "$bundle_release" ]] || mismatch+=" release(host=${VERSION_ID:-unknown} bundle=$bundle_release)"
[[ "$host_arch" == "$bundle_arch" ]]  || mismatch+=" arch(host=$host_arch bundle=$bundle_arch)"

if [[ -n "$mismatch" ]]; then
    echo "WARNING: bundle does not match this host:$mismatch" >&2
    [[ $FORCE -eq 1 ]] || { echo "Refusing to install. Rebuild the bundle, or pass --force." >&2; exit 1; }
    echo "         --force given, continuing anyway." >&2
fi

# --- 2. Verify package integrity ----------------------------------------------

echo ">> Verifying checksums ..."
( cd "$BUNDLE_DIR" && sha256sum -c --quiet SHA256SUMS ) || {
    echo "ERROR: checksum mismatch; the bundle is corrupt or was tampered with." >&2
    exit 1
}

# --- 3. Optionally free port 53 before dnsmasq is configured ------------------

if [[ $FREE_PORT_53 -eq 1 ]]; then
    echo ">> Disabling the systemd-resolved stub listener ..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/10-disable-stub.conf <<'EOF'
# Frees 127.0.0.53:53 so dnsmasq can bind port 53.
[Resolve]
DNSStubListener=no
EOF
    # resolv.conf must stop pointing at the stub we just turned off.
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved || true
fi

# --- 4. Install the packages ---------------------------------------------------

# dnsmasq's postinst starts the daemon, which fails (and aborts dpkg) if port 53
# is busy. Block service startup during unpack; we start services deliberately below.
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 755 /usr/sbin/policy-rc.d
restore_policy() { rm -f /usr/sbin/policy-rc.d; }
trap restore_policy EXIT

# chrony conflicts with systemd-timesyncd (both provide the time-daemon role).
# apt would remove it automatically, but `dpkg -i` won't -- it aborts on the
# conflict -- so we remove it first. Its function is exactly what chrony replaces.
if dpkg -s systemd-timesyncd >/dev/null 2>&1; then
    echo ">> Removing systemd-timesyncd (chrony replaces it) ..."
    systemctl stop systemd-timesyncd 2>/dev/null || true
    dpkg --remove systemd-timesyncd
fi

echo ">> Installing $(find "$BUNDLE_DIR/debs" -name '*.deb' | wc -l | tr -d ' ') packages ..."
dpkg -i "$BUNDLE_DIR"/debs/*.deb
dpkg --configure -a

restore_policy
trap - EXIT

# --- 5. Start the services -----------------------------------------------------

echo ">> Enabling chrony (NTP) ..."
systemctl enable --now chrony

echo ">> Enabling dnsmasq (DNS + DHCP) ..."
systemctl enable dnsmasq
if systemctl start dnsmasq; then
    echo "   dnsmasq started."
else
    echo
    echo "WARNING: dnsmasq is installed but failed to start." >&2
    if ss -lntup 2>/dev/null | grep -q ':53 '; then
        echo "         Port 53 is already in use:" >&2
        ss -lntup 2>/dev/null | grep ':53 ' | sed 's/^/           /' >&2
        echo "         Re-run with --free-port-53, or stop the conflicting resolver." >&2
    else
        echo "         See: journalctl -u dnsmasq -n 30 --no-pager" >&2
    fi
fi

# --- 6. Report -----------------------------------------------------------------

echo
echo "=== Status ==="
systemctl is-active chrony  >/dev/null 2>&1 && echo "  chrony  : active" || echo "  chrony  : NOT active"
systemctl is-active dnsmasq >/dev/null 2>&1 && echo "  dnsmasq : active" || echo "  dnsmasq : NOT active"
echo
echo "dnsmasq is installed with its stock config (DNS forwarder only; DHCP off)."
echo "To serve DHCP and local DNS records, drop a config into /etc/dnsmasq.d/ and"
echo "restart dnsmasq. A starting point is in $BUNDLE_DIR/examples/."
echo
echo "chrony is running against its stock upstream pool, which is unreachable in an"
echo "air-gapped network. Edit /etc/chrony/chrony.conf to point at a local time"
echo "source, or configure this host as the local stratum-10 reference clock."
echo "See $BUNDLE_DIR/examples/chrony-airgap.conf."
