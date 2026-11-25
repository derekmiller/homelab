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
- `openwebui.roadkill.lan` → `openwebui:8080`, the stack in `openwebui/`.
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

Reload needs the admin endpoint, which the global block binds to
`127.0.0.1:2019` inside the container. That is deliberate and safe: it is not
published, and binding loopback keeps it off the container's own interfaces. If
someone sets `admin off`, reload fails with `dial tcp [::1]:2019: connect:
connection refused` and the only way in is `docker compose restart caddy` —
which is also what you need **once** after changing the `admin` line itself,
because the old config has to be replaced before the new API exists.

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

## Open WebUI

`openwebui/` is the chat front-end. It needs no GPU, so it runs here while
Ollama stays on the PC, where the GPU is. That split is the stack's one runtime
dependency this host does not own: if the PC is asleep, chat stops. The
upstream is `http://pc.lan:11434`, set in `openwebui/compose.yaml`.

```bash
cd /opt/homelab/hosts/roadkill/openwebui
docker compose up -d
docker compose ps
```

It publishes no port. Caddy reaches it as `openwebui:8080` over `edge`.

State lives in the `open-webui` volume, declared with that exact name rather
than the project-prefixed default, so a project rename cannot orphan it.

**Auth is on.** The first account created at the sign-in page becomes the admin.
Chats made while auth was off belong to the built-in anonymous user, so they may
not appear under that account — the rows are still in `webui.db`, and reassigning
them is a deliberate SQL change against a verified backup, not a default.

### Backups

`openwebui-backup.timer` takes a nightly snapshot at 03:45. It stops the
container for a few seconds, because SQLite cannot be trusted to a filesystem
copy while it is being written, then verifies the archive and restarts it.

```bash
sudo cp /opt/homelab/hosts/roadkill/openwebui/openwebui-backup.service \
        /opt/homelab/hosts/roadkill/openwebui/openwebui-backup.timer \
        /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now openwebui-backup.timer
systemctl list-timers openwebui-backup.timer
sudo systemctl start openwebui-backup     # once, now
```

Archives land in `/var/lib/openwebui-backup`, root-owned and mode 0700: every
chat is in there. A failed run never rotates away the last good copy, and an
archive without `./webui.db` is treated as a failure rather than a small backup.
