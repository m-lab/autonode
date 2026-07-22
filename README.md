# autonode (mlab-node)

Native Debian packaging of the M-Lab "autonode" Network Diagnostic Tool (NDT)
measurement stack. The components run as hardened **systemd** services, confined
with systemd's own sandboxing directives — there is no Docker at build or run
time.

This replaces the previous Docker Compose deployment. Documentation on
host-managed M-Lab servers is in the
[Wiki](https://github.com/m-lab/autonode/wiki/Host%E2%80%90managed-Deployments).

## What's in the package

The `mlab-node` package installs and runs, as systemd services:

| Service | Unit |
|---|---|
| Node registration (Autojoin API) | `mlab-node-register.service` |
| NDT7 measurement server | `mlab-node-ndt-server.service` |
| Heartbeat (Locate API) | `mlab-node-heartbeat.service` |
| UUID annotator | `mlab-node-uuid-annotator.service` |
| Jostler (GCS archival) | `mlab-node-jostler.service` |
| Traceroute caller (scamper) | `mlab-node-traceroute-caller.service` |
| Prometheus node exporter | `mlab-node-node-exporter.service` |

plus one-shot units for schema generation, the UUID prefix, BBR, and external-IP
metadata. The whole stack is controlled atomically through `mlab-node.target`;
`register-node` is the keystone — if it goes down, the entire stack is brought
down with it.

The component binaries are built from the pinned upstream sources at package
build time (see `.build/build-binaries.sh`) — the same version tags the
container images were built from.

## File layout

| Path | Contents |
|---|---|
| `/usr/lib/mlab/` | component binaries, helper scripts, package-owned constants (`static.env`) |
| `/etc/mlab/mlab-node.env` | configuration (non-secret) |
| `/etc/mlab/api-key.env` | M-Lab API key (`0640 root:mlab-node`) |
| `/etc/mlab/locate/verify.pub` | Locate token verification key |
| `/var/lib/mlab/node/` | registration data + service-account credential |
| `/var/lib/mlab/schemas/` | generated JSON schemas + uuid.prefix |
| `/var/lib/mlab/resultsdir/` | measurement results awaiting upload |
| `/var/lib/mlab/autocert/` | Let's Encrypt certificate cache |
| `/run/mlab/sockets/` | tcpinfo / ipservice unix sockets |
| `/usr/share/mlab/html/` | static content served by ndt-server |

## Building the package

**CI is the canonical build**: every push runs the
[`build-deb` workflow](.github/workflows/build-deb.yml), which builds the
package in a `debian:bookworm` container — bookworm's glibc sets the
package's `libc6` floor, so the .deb installs on Debian 12 and anything
newer — and uploads it as a workflow artifact. Pushing a `v*` tag creates a
GitHub Release with the .deb attached; Releases are what production machines
should install.

Local builds still work and use the same script. Requires
`dpkg-buildpackage`, debhelper, a recent Go, `git`, `file`, and a C toolchain
(for scamper and the cgo builds), plus network access to clone the pinned
sources and fetch Go modules:

```sh
dpkg-buildpackage -us -uc -b
```

(Add `-d` if Go is installed from upstream tarballs rather than the
`golang-go` package.) Note that a locally built .deb inherits the host's
glibc as its `libc6` dependency floor — a package built on a newer distro may
not install on bookworm; use the CI artifacts for anything that leaves your
machine.

The build clones each component's repository at its pinned tag, builds the
binaries (replicating the upstream image builds' flags, plus `-s -w`
stripping), and stages them under `binaries/`. No container images or Docker
are involved. Each component is cached with a recipe-keyed stamp under
`binaries/.stamps/`, so re-builds only recompile components whose version pin
or build flags changed; delete `binaries/` to force a full rebuild.

## Installing and configuring

```sh
sudo apt install ./mlab-node_1.0.0_amd64.deb

# Configure the node, then add the API key.
sudoedit /etc/mlab/mlab-node.env
sudoedit /etc/mlab/api-key.env

# Start the whole stack (it is also enabled to start on boot).
sudo systemctl start mlab-node.target
```

Required settings in `/etc/mlab/mlab-node.env`: `ORGANIZATION`, `IATA`,
`INTERFACE_NAME`, `INTERFACE_MAXRATE`, `UPLINK`, `IPV4`, `TYPE` (and `IPV6` if
the node is reachable over IPv6). `API_KEY` goes in `/etc/mlab/api-key.env`.

## Operating

```sh
systemctl status mlab-node.target
systemctl list-dependencies mlab-node.target
journalctl -u mlab-node-ndt-server -f

# Stop / restart the entire stack.
sudo systemctl stop mlab-node.target
sudo systemctl restart mlab-node.target
```

## Prometheus metrics

Exposed on the host (all `network_mode: host` equivalents are now native):
9990 ndt-server, 9991 jostler, 9992 uuid-annotator, 9993 heartbeat,
9994 traceroute-caller, 9995 node-exporter. ndt-server serves measurements on
80 (cleartext) and 443 (TLS).
