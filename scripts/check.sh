#!/usr/bin/env bash
# Validate every Compose file and every Caddyfile in this repo. Starts nothing,
# writes nothing, needs no network beyond pulling the images pinned here.
#
#   ./scripts/check.sh
#
# Per host directory:
#   1. Every compose*.yaml under it renders (docker compose config). App stacks
#      live in subdirectories of the host that runs them, so this is recursive.
#   2. Every compose file declares a top-level `name:` literally, and Compose
#      agrees with it. Compose derives a name from the directory when none is
#      given, which is why the file is read directly: the derived value would
#      make a missing pin invisible. The project name decides volume names, and
#      for the proxy that volume is the local CA — losing the explicit name
#      means a new CA and a new trust ceremony on every device.
#   3. No two projects in this repo claim the same name.
#   4. `caddy validate` accepts the host's Caddyfile, in the image the host
#      pins. A broken Caddyfile takes down every site on the host at once, so
#      this is the check worth having before `up -d`.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
declare -A seen_names=()

json_field() {
  # json_field <python-expression over `d`> — read from stdin.
  python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

for dir in hosts/*/; do
  dir=${dir%/}
  host=$(basename "$dir")

  if [ ! -f "$dir/Caddyfile" ]; then
    echo "FAIL $host: no Caddyfile"
    fail=1
  fi

  # Sorted so the output is stable across filesystems; nested stacks included.
  while IFS= read -r file; do
    if ! rendered=$(docker compose -f "$file" config --format json 2>&1); then
      echo "FAIL $file: does not render"
      echo "$rendered" | sed 's/^/    /'
      fail=1
      continue
    fi

    declared=$(sed -n "s/^name:[[:space:]]*//p" "$file" | head -n1 | sed "s/^[\"']//; s/[\"']\$//")
    effective=$(printf '%s' "$rendered" | json_field "d.get('name') or ''")

    if [ -z "$declared" ]; then
      echo "FAIL $file: no top-level 'name:' (Compose would derive '$effective' from the path)"
      fail=1
    elif [ "$declared" != "$effective" ]; then
      echo "FAIL $file: declared name '$declared' disagrees with '$effective'"
      fail=1
    elif [ -n "${seen_names[$declared]:-}" ]; then
      echo "FAIL $file: project name '$declared' already used by ${seen_names[$declared]}"
      fail=1
    else
      seen_names[$declared]=$file
    fi
  done < <(find "$dir" -name 'compose*.yaml' -type f | sort)

  # Validate the Caddyfile with the caddy image this host actually pins, so the
  # check cannot pass on a version the host does not run.
  caddy_image=$(printf '%s' "$(docker compose -f "$dir/compose.yaml" config --format json)" \
    | json_field "next(s['image'] for s in d['services'].values() if 'caddy' in s.get('image',''))" 2>/dev/null || true)
  if [ -z "$caddy_image" ]; then
    echo "FAIL $host: no service using a caddy image in compose.yaml"
    fail=1
  elif docker run --rm -v "$PWD/$dir/Caddyfile:/etc/caddy/Caddyfile:ro" "$caddy_image" \
      caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    echo "ok   $host: Caddyfile valid ($caddy_image)"
  else
    echo "FAIL $host: Caddyfile rejected by $caddy_image"
    docker run --rm -v "$PWD/$dir/Caddyfile:/etc/caddy/Caddyfile:ro" "$caddy_image" \
      caddy validate --config /etc/caddy/Caddyfile || true
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "check failed"
  exit 1
fi
echo
echo "check passed"
