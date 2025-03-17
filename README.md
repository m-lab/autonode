# autonode

## Basic operation

| Autonode Register and Measure |
| ----------------------------- |
| ![register-and-measure](static/autonode-register-and-measure.svg) |

Once the machine is up and running, these operations will be performed automatically:

1. Register with the [Autojoin API](https://github.com/m-lab/autojoin)
2. Distribute credentials & metadata to local services
3. Report node health to the [Locate API](https://github.com/m-lab/locate)
4. Clients run [NDT tests](https://github.com/m-lab/ndt-server) targeting this node
5. NDT measurements are archived
6. NDT measurements are published to BigQuery

## Setting up an host-managed autonode

"Autonode" is the term M-Lab gives to host-managed nodes, because once the
organization registers with M-Lab and gets an API key, the software services
deployed on the machine do everything else, and automatically become part of the
M-Lab platform without futher user intervention.

### Register with M-Lab

The first step in becoming an M-Lab site host is reading over [the various
hosting
options](https://www.measurementlab.net/contribute/#host-or-sponsor-an-m-lab-measurement-site)
and understanding the basic requirements. If you decide you would like to
contribute using the "host-managed" deployment model, then fill out the [the
infrastructure contribution
form](https://docs.google.com/forms/d/e/1FAIpQLSe1wXKfQ0VIt_hZFatCwCaoOeeDpRv3JZDM_eAmIaksMuwB4g/viewform),
selecting the "Host-Managed Deployment" option.

M-Lab will review your submission and decided whether you qualify to become an
M-Lab site host. If you do, M-Lab will provide you with an API key and other
necessary information.

### Setting up the machine

The machine can be either physical or virtual, but must run some distribution of
Linux. Which distribution shouldn't matter, as long as it is fairly modern, and
can load the "tcp_bbr" kernel module.

The machine can be behind a firewall, but must have these ports open:

* 80 (unecrypted NDT tests)
* 443 (encrypted NDT tests)
* 9990-9999 (monitoring)

### Deploying the software

The first step is cloning this repository to the machine. It doesn't matter
where on the machine the repository is located:

```shell
git clone github.com/m-lab/autonode
```

The software services run in Docker containers, which are deployed using Docker
Compose. This, of course, implies that the machine must have [Docker
installed](https://docs.docker.com/engine/install/). This repository contains
[the Docker Compose configuration
file](https://github.com/m-lab/autonode/blob/main/examples/ndt-fullstack.yml).

The Docker Compose file should *not* be modified. Any required, user-configurable
settings should be set in [the environment variable
file](https://github.com/m-lab/autonode/blob/main/examples/env). The file is
fairly well commented, but here is an outline of the variables and what sort of
values they should have:

* ORGANIZATION: an alphanumeric name that M-Lab assigns to you.
* API_KEY: the API key that M-Lab provides you after you register.
* IATA: the 3-character [IATA
  code](https://www.iata.org/en/publications/directories/code-search/) of the
  nearest airport. If the nearest airport doesn't have an IATA code, then find
  the nearest one that does. M-Lab will work with you on the proper value for
  this variable.
* PROBABILITY: this is the probability that M-Lab's load balancing service
  ([Locate Service](https://github.com/m-lab/locate)) will send a test to your
  server. The M-Lab platform gets many millions of tests per day. Depending on
  where your server is located, its resources, and the speed of the machine's
  uplink, the test volume could possible overwhelm the machine and/or your
  network. You can modify this to suit your needs, either increasing or
  decreasing the traffic load as necessary.
  * INTERFACE_NAME: the NDT server needs to know the name of the primary network
  interface on the machine (e.g., eth0, enp114s0, etc.)
  * INTERFACE_MAXRATE: when the bitrate on the interface exceeds this value the
  NDT server will start refusing connections. This is because we never want the
  uplink to become saturated, causing the network bottleneck of a test to become
  the server's own uplink, which generate bad data. The recommended values are
  150Mbit for 1Gbps uplinks and 7Gbps for 10Gbps uplinks.
  * IPV4: the public IPv4 address of the primary network interface.  IPV6: the
  * public IPv6 address of the primary network interface.  TYPE: the type of
  * this machine, either "physical" or "virtual".

Once you have filled in values for all of the environment variable is the env
file, these steps should be performed:

```shell
# Recommended: add "tcp_bbr" to /etc/modules so that it gets loaded on each reboot.
sudo modprobe tcp_bbr

# Verify environment and credentials are working, then manually shutdown with ctrl-C.
docker compose --profile check-config --env-file env --file ndt-fullstack.yml up

# Start the ndt service in background. This will restart automatically on reboot.
docker compose --profile ndt --env-file env --file ndt-fullstack.yml up -d
```

If there were no errors, then your machine should start receiving production
M-Lab tests within less than a minute.
