# roadkill

The always-on Linux box on the LAN: 192.168.0.231, Ubuntu 26.04. It runs the
reverse proxy for every service on the LAN, and whichever applications are
deployed to it — those are cloned and run from their own repositories, not from
here.

## What runs here

| Compose project | File              | Address                             |
| --------------- | ----------------- | ----------------------------------- |
| `edge`          | `compose.yaml`    | 80, 443 (and 443/udp for HTTP/3)    |
| `tinfoil`       | `compose.tinfoil.yaml` | 127.0.0.1:3301 only            |

Application containers are not listed here because they are not deployed from
this repo. They join the external `edge` network and are reached by name.

## Names and TLS

Every site name is an A record in Pi-hole's *Local DNS Records*, all pointing at
192.168.0.231. Caddy uses `tls internal`, so each client needs Caddy's root
certificate installed once — see the repository README. Without that step names
resolve and browsers still warn.

Current sites:

- `barkeep.roadkill.lan` → `metabase:3000`, from the barkeep pipeline.
- `openwebui.roadkill.lan` → `pc.lan:8080` for now. This is deliberately staged:
  the name and its certificate arrive before the app moves here, so the cutover
  is one upstream line, `openwebui:8080`, not a DNS change and a move at once.
- `roadkill.lan` → redirect to `barkeep.roadkill.lan`.

To add a service: attach its container to the `edge` network (an external
network in its own Compose file), add a site block to `Caddyfile`, then reload:

```bash
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

The image runs `caddy run` **without `--watch`**, so editing the Caddyfile
changes nothing until that command runs — `docker compose up -d` will not
recreate a container because a bind-mounted file changed. `reload` is graceful
and drops no connections; `restart` does.

An application stack this host runs lives in a subdirectory (`hosts/roadkill/`
`<app>/`), with its own `name:` and its own Compose project. An application owned
by another repository — barkeep — is cloned and run from its own checkout, and
this directory only needs the name it answers on.

## Deploying and updating

```bash
sudo mkdir -p /opt/homelab && sudo chown "$USER": /opt/homelab
git clone https://github.com/derekmiller/homelab.git /opt/homelab
cd /opt/homelab/hosts/roadkill
docker compose up -d
```

`/opt` is root-owned. This directory has to belong to the user who runs Compose:
the Caddyfile is bind-mounted from this checkout, and a root-owned tree means
running Compose with `sudo` from then on.

The clone is HTTPS on purpose: the repo is public and this host only pulls, so
it needs no SSH key. `git pull` here works unauthenticated too.

```bash
cd /opt/homelab && git pull && cd hosts/roadkill && docker compose up -d
```

Run `../../scripts/check.sh` first; CI runs the same script on every push.

## The one irreversible mistake

`docker compose down -v` deletes `edge_caddy_data`. That volume holds Caddy's
local CA — the root certificate every device on this LAN has trusted — so the
next start generates a new one and every browser shows
`ERR_CERT_AUTHORITY_INVALID` until the new root is installed everywhere.

`docker compose down` without `-v` is fine. `up -d` is fine.

## Metabase AI

Metabase reaches the Tinfoil proxy at `http://tinfoil:3301/v1` because both join
`edge`. Because the address is private, Metabase requires
`MB_LLM_ALLOWED_NETWORKS` to include it — set in the barkeep repository's
`.env`, not here, since that is where Metabase is configured.
