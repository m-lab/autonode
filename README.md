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

The component binaries are built from source at build time, at the same
upstream release tags the pinned M-Lab container images were built from (see
`.build/build-binaries.sh`).

## File layout

| Path | Contents |
|---|---|
| `/usr/lib/mlab/` | component binaries and helper scripts |
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

Requires `dpkg-buildpackage`, debhelper, `git`, `go`, and a C toolchain
(`gcc`, `make`) for scamper:

```sh
dpkg-buildpackage -us -uc -b
```

The build clones each component repository at its pinned release tag, compiles
the Go binaries with `CGO_ENABLED=0` (static, glibc-independent) using a pinned
Go toolchain, builds the scamper snapshot vendored by traceroute-caller, and
stages everything under `binaries/`.

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
