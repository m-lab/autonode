# Examples

## Local Stack Demo

The `ndt-localstack.yml` is a local version of the NDT server. This is suitable for demonstrations and has no external service dependencies.

```sh
docker-compose --file ndt-localstack.yml up
```

After startup, run a browser-based test by loading:

* [http://localhost:8080/ndt7.html](http://localhost:8080/ndt7.html)

If the localstack configuration runs on a publicly accessible IP, then others could target that address and port also.

See: [github.com/m-lab/ndt-server/README.md](https://github.com/m-lab/ndt-server?tab=readme-ov-file#clients) for other available clients.

## Full Stack (beta)

A fullstack deployment requires registration with M-Lab, an assigned
organization name, and API keys and several other locally determined parameters.
All settings should be populated in the `env` file before starting.

The `ndt-fullstack.yml` and `env` file are a complete configuration for an
autonode deployment. Please review the `env` file comments for hints about
correct configuration.

Requirements:

* version v2.28 or later of docker compose
* the bbr module must be loaded in the kernel

```sh
docker compose version

sudo modprobe tcp_bbr
# Recommended: add "tcp_bbr" to /etc/modules

# Verify environment and credentials are working, then manually shutdown with ctrl-C.
docker compose --profile check-config --env-file env --file ndt-fullstack.yml up

# Start ndt service in background. This will restart automatically on reboot.
docker compose --profile ndt --env-file env --file ndt-fullstack.yml up -d
```
