#!/usr/bin/env bash
# Runs a Docker Compose stack for a Namespace macOS runner on a separate Namespace Linux
# instance. macOS runners are VMs without nested virtualization, so Docker cannot run on them.
#
#   namespace-stack.sh up <compose-dir>   create the instance, point docker at it, copy <compose-dir> over
#   namespace-stack.sh forward <port>...  expose instance ports on the runner's 127.0.0.1 under the same numbers
#   namespace-stack.sh down               destroy the instance
set -euo pipefail

state_dir=/tmp/namespace-stack
instance_file="$state_dir/instance"

install_compose() {
  docker compose version >/dev/null 2>&1 && return
  mkdir -p ~/.docker/cli-plugins
  curl -fsSL -o ~/.docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/latest/download/docker-compose-darwin-aarch64
  chmod +x ~/.docker/cli-plugins/docker-compose
}

up() {
  local compose_dir
  compose_dir="$(cd "$1" && pwd)"
  mkdir -p "$state_dir/docker"
  install_compose

  # The runner sets DOCKER_DEFAULT_PLATFORM=linux/arm64, so the instance must be arm64.
  nsc create --bare --machine_type linux/arm64:8x16 --duration 4h --cidfile "$instance_file"

  # `attach-context --background` times out before its socket appears; the foreground form works.
  nohup nsc docker attach-context --to "$(cat "$instance_file")" --name namespace-stack \
    --state "$state_dir/docker" --use > "$state_dir/attach.log" 2>&1 &

  local deadline=$((SECONDS + 300))
  until docker info >/dev/null 2>&1; do
    if ((SECONDS > deadline)); then
      cat "$state_dir/attach.log" >&2
      exit 1
    fi
    sleep 5
  done

  # Bind mounts resolve on the instance, so the compose directory has to exist there at the same path.
  docker create --name namespace-stack-seed -v "$compose_dir:/seed" alpine:3 true >/dev/null
  docker cp "$compose_dir/." namespace-stack-seed:/seed/
  docker rm namespace-stack-seed >/dev/null
  docker run --rm -v "$compose_dir:/seed" alpine:3 chmod -R a+rwX /seed
}

forward() {
  local port
  for port in "$@"; do
    nohup nsc instance port-forward "$(cat "$instance_file")" --target_port "$port" \
      > "$state_dir/forward-$port.log" 2>&1 &
  done

  local deadline=$((SECONDS + 300))
  for port in "$@"; do
    until nc -z 127.0.0.1 "$port" 2>/dev/null; do
      if ((SECONDS > deadline)); then
        cat "$state_dir/forward-$port.log" >&2
        exit 1
      fi
      sleep 3
    done
  done
}

down() {
  pkill -f "nsc instance port-forward" || true
  pkill -f "nsc docker attach-context" || true
  docker context use default >/dev/null 2>&1 || true
  if [[ -s "$instance_file" ]]; then
    nsc destroy "$(cat "$instance_file")" --force || true
  fi
}

"$@"
