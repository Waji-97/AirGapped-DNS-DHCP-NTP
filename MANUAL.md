# Air-Gapped DNS + DHCP + NTP Installation Manual

Install **DNS + DHCP** (via `dnsmasq`) and **NTP** (via `chrony`) on an offline
Ubuntu server, using packages downloaded on a separate online machine.

The workflow has two halves:

1. **Build** — on an online Ubuntu box, `build-bundle.sh` downloads the packages
   and their dependency delta and produces a single `.tar.gz`.
2. **Install** — on the offline server, `install.sh` (shipped *inside* the
   bundle) verifies and installs those packages with no network access.

This procedure was tested end to end on **Ubuntu 24.04.4 LTS (amd64)** with the
network physically blocked during installation. The verified results are in
[Appendix B](#appendix-b--verified-test-results).

---

## 1. Requirements

| | Build host (online) | Target server (offline) |
|---|---|---|
| OS | Ubuntu | Ubuntu, **same release** |
| Arch | e.g. amd64 | **same arch** as build host |
| Tools | `apt-get`, `dpkg`, `tar` (all stock) | `dpkg`, `systemctl` (all stock) |
| Access | internet + package mirror | none required |

Two things **must match** between the build host and the target:

- **Release and architecture.** `apt` only fetches packages for the build host's
  own release/arch. Build on 24.04/amd64 for a 24.04/amd64 target.
- **A standard base install.** The bundle contains only the packages the target
  is *missing* — the delta over what a normal Ubuntu install already has. Build
  on a normal install of that release, not a heavily customised one. Core
  packages (`libc6`, `apt`, `perl`, …) are deliberately **not** shipped, so
  installing the bundle can never downgrade the target's base system.

Check the target's release and arch:

```bash
. /etc/os-release && echo "$VERSION_ID"   # e.g. 24.04
dpkg --print-architecture                 # e.g. amd64
```

---

## 2. Files

```
build-bundle.sh                 # run on the ONLINE build host
install.sh                      # runs on the OFFLINE target (packed into the bundle)
examples/
  dnsmasq-airgap.conf           # starting DNS + DHCP config
  chrony-airgap.conf            # starting NTP config (local time authority)
```

---

## 3. Build the bundle (online host)

From the directory containing the scripts:

```bash
./build-bundle.sh
```

Options:

| Flag | Meaning |
|---|---|
| `-o DIR` | Write the bundle to `DIR` (default: current directory) |
| `-n` | Exclude Recommends (smaller bundle, fewer extras) |
| `-U` | Skip `apt-get update` (use if your index is already current) |
| `-h` | Help |

`apt-get update` needs root, so the script uses `sudo` for that step if you are
not already root; the rest runs as your user.

Output is a single file named for the target it fits, e.g.:

```
dns-dhcp-ntp-ubuntu24.04-amd64.tar.gz     # ~1.1 MB, 6 packages
```

The bundle contains the `.deb` files, `install.sh`, the example configs, a
`MANIFEST` (release/arch it targets), `PACKAGES.txt`, and `SHA256SUMS`.

---

## 4. Transfer to the offline server

Copy the `.tar.gz` by whatever path your air-gap allows — USB, one-way file
drop, `scp` over a management link, etc. Only the single file is needed:

```bash
scp dns-dhcp-ntp-ubuntu24.04-amd64.tar.gz user@offline-server:~/
```

---

## 5. Install on the offline server

```bash
tar -xzf dns-dhcp-ntp-ubuntu24.04-amd64.tar.gz
sudo ./dns-dhcp-ntp-ubuntu24.04-amd64/install.sh --free-port-53
```

Options:

| Flag | Meaning |
|---|---|
| `--free-port-53` | Disable the `systemd-resolved` stub listener so dnsmasq can bind port 53. **Needed on a stock Ubuntu server** (see note below). |
| `--force` | Install even if the host's release/arch differs from the bundle. |
| `-h` | Help |

What `install.sh` does, in order:

1. Checks the bundle's `MANIFEST` matches this host's release/arch (refuses on
   mismatch unless `--force`).
2. Verifies every `.deb` against `SHA256SUMS`.
3. With `--free-port-53`: turns off the `systemd-resolved` DNS stub on
   `127.0.0.53:53` and repoints `/etc/resolv.conf`.
4. Removes `systemd-timesyncd` (it conflicts with chrony — both are time
   daemons; chrony replaces it).
5. Installs the bundled `.deb`s with `dpkg`, with service auto-start suppressed
   during unpack.
6. Enables and starts `chrony` and `dnsmasq`, then prints a status summary.

> **Why `--free-port-53`?** Stock Ubuntu runs `systemd-resolved`, which already
> listens on port 53. Without this flag dnsmasq installs fine but **fails to
> start** because the port is taken. The installer detects that case and tells
> you to re-run with the flag. If you have a specific reason to keep
> `systemd-resolved`, configure dnsmasq to bind a different address instead.

At this point both services are **running on their stock configuration**:
dnsmasq is a DNS forwarder with DHCP off, and chrony is pointed at the public
NTP pool (unreachable while air-gapped). Section 6 makes them do real work.

---

## 6. Configure for real use

The example files in the bundle's `examples/` directory are starting points.
**Every value in them is a placeholder — edit before deploying.**

### 6.1 DNS + DHCP (dnsmasq)

Copy the example into place and edit it:

```bash
sudo cp dns-dhcp-ntp-ubuntu24.04-amd64/examples/dnsmasq-airgap.conf \
        /etc/dnsmasq.d/10-airgap.conf
sudo nano /etc/dnsmasq.d/10-airgap.conf
```

Key things to set (find your LAN interface with `ip -br link`):

```ini
interface=eth0                 # your LAN NIC
domain=lab.local
dhcp-range=10.0.0.100,10.0.0.200,12h
dhcp-option=option:router,10.0.0.1
dhcp-option=option:dns-server,10.0.0.10
dhcp-option=option:ntp-server,10.0.0.10   # point clients at this box for time
address=/ns1.lab.local/10.0.0.10          # static DNS records
```

Validate the config, then restart:

```bash
sudo dnsmasq --test                        # syntax check
sudo systemctl restart dnsmasq
```

### 6.2 NTP (chrony)

In an air-gapped network there is no upstream time server, so this host becomes
the authority. Back up the stock config and install the example:

```bash
sudo cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.orig
sudo cp dns-dhcp-ntp-ubuntu24.04-amd64/examples/chrony-airgap.conf \
        /etc/chrony/chrony.conf
sudo nano /etc/chrony/chrony.conf
```

The important lines:

```ini
local stratum 10          # trust this host's own clock as the reference
allow 10.0.0.0/24         # serve time to your LAN (set your subnet)
```

Restart and confirm it is serving:

```bash
sudo systemctl restart chrony
chronyc tracking          # Reference ID should show the local clock, not 00000000
```

> If the server has a real reference (GPS/PPS, or a PTP source), add a
> `refclock` line and remove `local stratum 10` — a real clock always beats a
> free-running one. See the comments in `examples/chrony-airgap.conf`.

---

## 7. Verify

```bash
# Services up?
systemctl is-active chrony dnsmasq

# DNS: resolve a record you defined
nslookup ns1.lab.local 127.0.0.1     # or: dig @127.0.0.1 ns1.lab.local

# DHCP + DNS listeners present?
sudo ss -lntup | grep -E ':53 |:67 '

# NTP: is chrony serving / synced?
chronyc tracking
chronyc clients                       # once clients start requesting time
```

`nslookup`/`dig` come from the `dnsutils`/`bind9-dnsutils` package, which is not
in this bundle. On the air-gapped box you can instead confirm DNS by pointing a
client at the server, or by reading `journalctl -u dnsmasq`.

---

## 8. Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `install.sh` refuses: "bundle does not match this host" | Built for a different release/arch. Rebuild on a matching host, or override with `--force` if you are certain. |
| `dnsmasq` fails to start; port 53 in use | `systemd-resolved` holds the port. Re-run the installer with `--free-port-53`, or stop the other resolver. |
| `checksum mismatch` | Bundle corrupted in transfer. Re-copy the `.tar.gz`. |
| `dpkg: conflict … systemd-timesyncd` | You installed by hand without the installer. Run `sudo dpkg --remove systemd-timesyncd` first, or use `install.sh`. |
| `chronyc tracking` shows Stratum 0 / Ref ID `00000000` | chrony has no reachable source. Expected until you apply the `local stratum 10` config (Section 6.2). |
| Clients get no DHCP lease | Check `interface=` matches the LAN NIC, the firewall allows UDP 67, and `dhcp-range` is on the client subnet. |

---

## Appendix A — What's in the bundle

Downloaded for `dnsmasq` + `chrony` on Ubuntu 24.04/amd64 (6 packages, ~1.1 MB):

| Package | Role |
|---|---|
| `dnsmasq`, `dnsmasq-base` | DNS forwarder + DHCP server |
| `dns-root-data` | DNSSEC root trust anchors used by dnsmasq |
| `chrony` | NTP daemon |
| `tzdata`, `tzdata-legacy` | timezone database (chrony dependency) |

The exact set depends on what the build host already has installed; the bundle's
`PACKAGES.txt` lists the precise versions for a given build.

---

## Appendix B — Verified test results

Tested on Ubuntu 24.04.4 LTS (amd64), with outbound network blocked at the
firewall for the entire install (loopback + the existing SSH session were the
only connectivity). Abridged output:

```
########## 1. Cut the network (simulate air-gap) ##########
  OK: outbound HTTP to the package mirror is blocked.

########## 2. Extract + install the bundle OFFLINE ##########
>> Verifying checksums ...
>> Disabling the systemd-resolved stub listener ...
>> Removing systemd-timesyncd (chrony replaces it) ...
>> Installing 6 packages ...
=== Status ===
  chrony  : active
  dnsmasq : active

########## 3. Functional verification (still offline) ##########
-- services --
   chrony   : active
   dnsmasq  : active
-- DNS query to dnsmasq (test.lab.local -> expect 10.9.9.9) --
   ANSWERS=1  A=10.9.9.9  PASS
-- dnsmasq DHCP init (journal) --
   dnsmasq-dhcp[5582]: DHCP, IP range 10.9.9.100 -- 10.9.9.200, lease time 1h

########## 4. Restore network ##########
  OK: outbound restored.
```

Confirmed: checksum verification, `systemd-timesyncd` removal, port-53 handling,
offline `dpkg` install of all 6 packages, both services active, live DNS
resolution, and DHCP range initialization — all with no network access.
