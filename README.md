# homelab

Host configuration for the machines on this LAN: what runs, how it is reached,
and what has to be true for it to keep working.

This repo is the **source of truth for the hosts**, not for the applications they
run. Application repositories stay separate and own their own Compose projects;
this one owns the shared substrate — DNS names, TLS, the reverse proxy, and the
networks that let separate projects find each other.

```
hosts/
  roadkill/            # the always-on Linux box
    compose.yaml       # Caddy: TLS termination and routing
    Caddyfile          # every site served from this host
    compose.tinfoil.yaml
    README.md          # what runs here, and the addresses it answers on
scripts/
  check.sh             # validate every Caddyfile and Compose file, start nothing
```

## Adding a host

Create `hosts/<name>/` with its own `compose.yaml` and `Caddyfile`. Nothing here
is shared between hosts except the conventions, so a second host is a directory
rather than a refactor.

Every `compose.yaml` in this repo must declare a top-level `name:`. That name
decides the Docker volume names, and for the proxy it holds the local CA — the
root certificate every device on the LAN trusts. Losing it means re-trusting a
new CA on every browser and phone. `scripts/check.sh` fails when the pin is
missing.

## Deploying

This repo is public, and the host only ever reads it, so deploy over HTTPS and
give the host no GitHub credentials at all. Pushing stays a workstation concern.

On the host:

```bash
sudo mkdir -p /opt/homelab && sudo chown "$USER": /opt/homelab
git clone https://github.com/derekmiller/homelab.git /opt/homelab
cd /opt/homelab/hosts/roadkill
docker compose up -d
```

Updating:

```bash
cd /opt/homelab && git pull && cd hosts/roadkill && docker compose up -d
```

## Moving from an ad-hoc `/opt/edge`

If Caddy already runs from a directory that is not this clone, the project name
— not the path — is what preserves the CA. The old directory derived `edge` from
its name; `compose.yaml` here declares it, so `edge_caddy_data` is adopted rather
than replaced:

```bash
cd /path/to/old/stack
docker compose down                               # never -v
docker volume ls | grep caddy_data                # edge_caddy_data
git clone https://github.com/derekmiller/homelab.git /opt/homelab
cd /opt/homelab/hosts/roadkill && docker compose up -d
docker volume ls | grep caddy_data                # same volume, new directory
```

`docker compose down` before the move stops the old containers from holding
ports 80/443. If the new stack starts and browsers still trust the certificate,
the volume was adopted correctly; if they warn, check that the volume name is
still `edge_caddy_data` — a different name means a different CA.

## Checking before you deploy

```bash
./scripts/check.sh
```

It renders each Compose file and runs `caddy validate` against each Caddyfile in
the same image the host uses. A broken Caddyfile takes down every site at once,
so this runs in CI on every push as well.

## Two rules that are easy to break

1. **Never `docker compose down -v` here.** The `-v` discards `caddy_data`, the
   local CA, and every device's trust in it. A restart or `up -d` is safe; a
   volume removal is not.
2. **`tls internal` requires installing the CA on each client.** Extract it from
   the running container and add it to the trust store:

   ```bash
   docker compose exec caddy cat /data/caddy/pki/authorities/local/root.crt > caddy-root.crt
   ```

   macOS: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain caddy-root.crt`
   and use `/usr/bin/curl` to test, because Homebrew's curl uses its own bundle.
