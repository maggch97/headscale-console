#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch_file="$repo_root/patches/tailscale/0001-derphttp-websocket-and-netcheck-honor-derpport.patch"

if [[ "$(uname -s)" == "Darwin" ]]; then
  export TMPDIR=/private/tmp
fi

go mod download tailscale.com
module_dir="$(go list -m -f '{{.Dir}}' tailscale.com)"

derphttp_file="$module_dir/derp/derphttp/derphttp_client.go"
netcheck_file="$module_dir/net/netcheck/netcheck.go"

if grep -q "derpNodeURLHost" "$derphttp_file" &&
  grep -q "target := net.JoinHostPort(n.HostName, port)" "$derphttp_file" &&
  grep -q "derpProbeURL" "$netcheck_file"; then
  echo "tailscale.com module already has DERPPort URL patch"
  exit 0
fi

chmod u+w \
  "$module_dir/derp/derphttp" \
  "$module_dir/net/netcheck" \
  "$derphttp_file" \
  "$netcheck_file"
patch -p1 -d "$module_dir" < "$patch_file"
