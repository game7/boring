#!/usr/bin/env bash
# boring: forward a remote host's listening TCP ports to the same ports on this machine's
# localhost, and keep the forwards in step as servers start and stop.
# Inspired by mole (https://github.com/Luqueee/mole, MIT licence).
set -o pipefail

VERSION=0.1.0
interval=5
max_port=32767
exclude=(22 25 53 111 631)

usage() {
  cat <<EOF
Usage: boring.sh [options] [user@]host

Forward every TCP port listening on the remote host's loopback or wildcard address to the same
port on this machine's localhost. Rescans every few seconds and restarts one ssh tunnel when the
set changes. Uses your ssh client, so ~/.ssh/config, keys, agent and known_hosts all apply;
key-based authentication is required.

Options:
  -i SECONDS      Rescan interval (default: $interval)
  -x PORT[,PORT]  Exclude more remote ports (always excluded: ${exclude[*]})
  -m PORT         Ignore remote ports above this (default: $max_port, below Linux's ephemeral range)
  -h              Show this help
  -V              Show the version
EOF
}

while getopts ":i:x:m:hV" opt; do
  case $opt in
    i) interval=$OPTARG ;;
    x) IFS=, read -ra extra <<<"$OPTARG" && exclude+=("${extra[@]}") ;;
    m) max_port=$OPTARG ;;
    h) usage && exit 0 ;;
    V) echo "boring $VERSION" && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

host=$1
ssh_options=(-n -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
# Runs in the remote login shell: Linux ss, then Linux netstat, then BSD/macOS netstat.
listeners='ss -Hltn 2>/dev/null || netstat -ltn 2>/dev/null || netstat -an -p tcp'
tunnel_pid=
forwarded=
warned=

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# Prints the remote's forwardable listening ports, one per line, or fails if unreachable.
remote_ports() {
  local output

  # shellcheck disable=SC2029 # $listeners is meant to be sent as-is to the remote shell.
  output=$(ssh "${ssh_options[@]}" "$host" "$listeners") || return 1
  awk -v max="$max_port" -v skip=" ${exclude[*]} " '
    /LISTEN/ {
      address = $4
      if (!match(address, /[:.][0-9]+$/)) next
      port = substr(address, RSTART + 1) + 0
      ip = substr(address, 1, RSTART - 1)
      gsub(/[][]/, "", ip)
      sub(/%.*/, "", ip)
      if (port < 1 || port > max || index(skip, " " port " ")) next
      if (ip == "*" || ip == "0.0.0.0" || ip == "::" || ip == "::1" || ip ~ /^127\./ || ip ~ /^::ffff:127\./)
        print port
    }' <<<"$output" | sort -n | uniq
}

local_port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

contains() { [[ " $1 " == *" $2 "* ]]; }

stop_tunnel() {
  [[ -n $tunnel_pid ]] || return 0
  kill "$tunnel_pid" 2>/dev/null
  wait "$tunnel_pid" 2>/dev/null
  tunnel_pid=
}

start_tunnel() {
  local arguments=() port

  for port in "$@"; do arguments+=(-L "$port:localhost:$port"); done
  ssh "${ssh_options[@]}" -N -o ExitOnForwardFailure=yes -o LogLevel=ERROR "${arguments[@]}" "$host" &
  tunnel_pid=$!
}

trap 'stop_tunnel; exit 0' INT TERM
trap stop_tunnel EXIT

log "boring $VERSION: watching $host every ${interval}s (Ctrl-C to stop)"

while :; do
  if ! discovered=$(remote_ports); then
    log "cannot list ports on $host; retrying"
    sleep "$interval"
    continue
  fi

  tunnel_alive=false
  [[ -n $tunnel_pid ]] && kill -0 "$tunnel_pid" 2>/dev/null && tunnel_alive=true
  # Ports held by a live tunnel are ours; after it exits, every port is checked again.
  owned=
  $tunnel_alive && owned=$forwarded

  wanted=
  for port in $discovered; do
    if contains "$owned" "$port" || ! local_port_busy "$port"; then
      wanted+="${wanted:+ }$port"
    elif ! contains "$warned" "$port"; then
      log "skipping $port: already in use on this machine"
      warned+=" $port"
    fi
  done

  for port in $warned; do
    contains "$discovered" "$port" && local_port_busy "$port" || warned=${warned/ $port/}
  done

  if [[ $wanted != "$forwarded" ]] || { [[ -n $forwarded ]] && ! $tunnel_alive; }; then
    for port in $wanted; do contains "$forwarded" "$port" || log "+ localhost:$port"; done
    for port in $forwarded; do contains "$wanted" "$port" || log "- localhost:$port"; done
    [[ $wanted == "$forwarded" ]] && log "tunnel to $host exited; reconnecting"

    stop_tunnel
    forwarded=$wanted
    # shellcheck disable=SC2086 # deliberate word splitting of the port list
    [[ -n $wanted ]] && start_tunnel $wanted
  fi

  sleep "$interval"
done
