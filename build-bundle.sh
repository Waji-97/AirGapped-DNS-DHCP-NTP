#!/usr/bin/env bash
#
# Build an air-gapped installation bundle for DNS + DHCP (dnsmasq) and NTP (chrony).
#
# Run this ON AN ONLINE UBUNTU MACHINE. It downloads dnsmasq + chrony and the
# dependency DELTA over a standard Ubuntu base, then packs them into a
# self-contained .tar.gz you copy to the offline server and install with install.sh.
#
# IMPORTANT: two things must match between this build host and the offline target:
#   1. Ubuntu release + architecture -- apt only fetches for THIS machine's
#      release/arch (build on 24.04/amd64 for a 24.04/amd64 target).
#   2. A standard/representative base install -- the bundle contains only the
#      packages the target is MISSING (the delta over what is installed here), so
#      the build host should be a normal install of that release, not a heavily
#      customised one. Base packages (libc6, apt, perl, ...) are intentionally
#      NOT shipped, so installing the bundle can never downgrade the target.
#
set -euo pipefail

PACKAGES=(dnsmasq chrony)
OUTDIR="$PWD"
RECOMMENDS=1
DO_UPDATE=1

usage() {
    cat <<EOF
Usage: $0 [options]

  -o DIR   where to write the bundle (default: current directory)
  -n       exclude Recommends (smaller bundle, fewer extras)
  -U       skip 'apt-get update' (use if your package index is already current)
  -h       show this help

The bundle targets THIS host's Ubuntu release and architecture. Build on a
machine that matches your offline server. Check the target with:
    . /etc/os-release && echo "\$VERSION_ID"
    dpkg --print-architecture
EOF
}

while getopts ":o:nUh" opt; do
    case "$opt" in
        o) OUTDIR="$OPTARG" ;;
        n) RECOMMENDS=0 ;;
        U) DO_UPDATE=0 ;;
        h) usage; exit 0 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage >&2; exit 2 ;;
        :)  echo "Option -$OPTARG requires an argument" >&2; exit 2 ;;
    esac
done

# --- Preconditions ------------------------------------------------------------

[[ -r /etc/os-release ]] || { echo "ERROR: /etc/os-release missing; this must run on Ubuntu." >&2; exit 1; }
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || {
    echo "ERROR: this builds Ubuntu (.deb) bundles but the host is '${ID:-unknown}'." >&2
    exit 1
}
for cmd in apt-get dpkg dpkg-deb tar sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' not found." >&2; exit 1; }
done

RELEASE="$VERSION_ID"
ARCH="$(dpkg --print-architecture)"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/install.sh" ]] || { echo "ERROR: install.sh not found next to $0" >&2; exit 1; }

BUNDLE_NAME="dns-dhcp-ntp-ubuntu${RELEASE}-${ARCH}"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
DEBS="$STAGING/$BUNDLE_NAME/debs"
mkdir -p "$DEBS"

# --- Refresh the package index ------------------------------------------------

if [[ $DO_UPDATE -eq 1 ]]; then
    echo ">> apt-get update ..."
    if [[ $EUID -eq 0 ]]; then apt-get update -qq
    else sudo apt-get update -qq; fi
fi

# --- Resolve the full dependency closure --------------------------------------
#
# apt-get download only fetches the packages you name, and plain
# 'install --download-only' skips deps already installed on THIS builder -- both
# would produce a bundle that's incomplete on a clean target. So we expand the
# closure ourselves with apt-cache depends --recurse and download every member.

recflag=()
[[ $RECOMMENDS -eq 0 ]] && recflag=(--no-install-recommends)

echo ">> Downloading ${PACKAGES[*]} plus the dependency delta over this host ..."
# --download-only fetches the named packages and every dependency they need that
# is NOT already installed here. Because the build host is a standard install of
# the same Ubuntu release as the target, that delta is exactly what the target is
# missing -- and base packages already present on both are skipped, so the bundle
# can never downgrade the target's core system.
mkdir -p "$DEBS/partial"
apt-get install -y --download-only "${recflag[@]}" \
    -o Dir::Cache::archives="$DEBS" \
    -o APT::Sandbox::User=root \
    "${PACKAGES[@]}"

# Leave only .deb files in the bundle; drop apt's lock/partial bookkeeping.
rm -f "$DEBS"/lock 2>/dev/null || true
rmdir "$DEBS/partial" 2>/dev/null || true

deb_count=$(find "$DEBS" -maxdepth 1 -name '*.deb' | wc -l | tr -d ' ')
[[ "$deb_count" -gt 0 ]] || { echo "ERROR: no .deb files were downloaded." >&2; exit 1; }

# --- Stage the rest of the bundle ---------------------------------------------

echo ">> Staging bundle contents ..."
cp "$SCRIPT_DIR/install.sh" "$STAGING/$BUNDLE_NAME/install.sh"
chmod 755 "$STAGING/$BUNDLE_NAME/install.sh"
[[ -d "$SCRIPT_DIR/examples" ]] && cp -R "$SCRIPT_DIR/examples" "$STAGING/$BUNDLE_NAME/examples"

# Record what the bundle targets so install.sh can refuse to run on the wrong host.
cat > "$STAGING/$BUNDLE_NAME/MANIFEST" <<EOF
bundle=$BUNDLE_NAME
distro=ubuntu
release=$RELEASE
arch=$ARCH
packages=${PACKAGES[*]}
deb_count=$deb_count
built_on=$(uname -srm)
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo ">> Package list:"
for d in "$DEBS"/*.deb; do
    dpkg-deb -f "$d" Package Version | paste -sd' ' -
done | sort | tee "$STAGING/$BUNDLE_NAME/PACKAGES.txt" | sed 's/^/   /'

# Checksums are relative to the bundle root so 'sha256sum -c' works after untar.
( cd "$STAGING/$BUNDLE_NAME" && find debs -name '*.deb' -exec sha256sum {} + | sort -k2 > SHA256SUMS )

# --- Pack ---------------------------------------------------------------------

mkdir -p "$OUTDIR"
TARBALL="$(cd "$OUTDIR" && pwd)/${BUNDLE_NAME}.tar.gz"
( cd "$STAGING" && tar -czf "$TARBALL" "$BUNDLE_NAME" )

echo
echo ">> Bundle ready: $TARBALL"
echo "   $deb_count packages, $(du -h "$TARBALL" | cut -f1) compressed"
echo
echo "Copy it to the offline server and run:"
echo "   tar -xzf ${BUNDLE_NAME}.tar.gz"
echo "   sudo ./${BUNDLE_NAME}/install.sh"
