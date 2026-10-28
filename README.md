# boring

Auto-detected SSH port forwarding from a remote host to your `localhost`.

Start a dev server on your remote box, then open `http://localhost:<port>` in your local browser.
boring watches the remote host and forwards each listening port to the same port on your machine.
You don't need a port list, port ranges or editor integration.

```text
$ ./boring.sh my-dev-box
10:02:11 boring 0.1.0: watching my-dev-box every 5s (Ctrl-C to stop)
10:02:12 + localhost:3333
10:02:12 + localhost:24678
10:04:40 + localhost:3334
10:09:03 - localhost:3334
```

## Credit

boring is inspired by [mole](https://github.com/Luqueee/mole) by Luqueee (MIT licence), and its
forwarding rules come from mole. boring copies none of mole's code. It is a small script you can
read in a couple of minutes, so you can run it without installing a binary. If you want a polished
Go tool with a TUI, use mole.

## Rules

- **What is forwarded.** TCP ports listening on the remote's loopback (`127.*`, `::1`) or wildcard
  (`0.0.0.0`, `::`, `*`) addresses. A port bound only to one specific non-loopback IP is skipped.
- **Always excluded.** 22, 25, 53, 111 and 631. Add more with `-x` / `-Exclude`.
- **Ephemeral ports are ignored.** By default, ports above 32767 are skipped. Change this with
  `-m` / `-MaxPort`.
- **Same port locally.** Remote port N is forwarded to `localhost:N`, bound to loopback only.
- **Local ports are never taken over.** If something on your machine already listens on N, boring
  skips N and warns once.
- **One SSH connection.** When the set of ports changes, boring restarts the single `ssh -N -L …`
  tunnel. If the tunnel drops, boring reconnects on the next scan.

Discovery runs `ss -Hltn`, then falls back to `netstat`, so the remote can be Linux or macOS/BSD.

## Requirements

- The OpenSSH client on `PATH`. Windows 10/11 ships it; otherwise enable it under Settings →
  Optional features → OpenSSH Client.
- Key-based (or agent) authentication to the remote. boring runs ssh with `BatchMode=yes`, so it
  can't answer password prompts.
- The host already in `known_hosts`. Run `ssh <host>` once by hand first.

boring uses your normal ssh client, so `~/.ssh/config` aliases, `ProxyJump`, keys and the agent all
work.

## Usage

### Windows (PowerShell 5.1 or 7)

```powershell
.\boring.ps1 my-dev-box
.\boring.ps1 -Exclude 3773,3000 -Interval 3 user@devbox
Get-Help .\boring.ps1 -Detailed
```

### Linux / macOS (Bash 3.2+)

```bash
./boring.sh my-dev-box
./boring.sh -x 3773,3000 -i 3 user@devbox
./boring.sh -h
```

| Option         | PowerShell     | Bash     | Default |
| -------------- | -------------- | -------- | ------- |
| Scan seconds   | `-Interval`    | `-i`     | 5       |
| Extra excludes | `-Exclude 1,2` | `-x 1,2` | none    |
| Highest port   | `-MaxPort`     | `-m`     | 32767   |

Stop boring with Ctrl-C. This also closes the tunnel.

## Install

Download the script for your platform.

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/game7/boring/main/boring.ps1 -OutFile boring.ps1
Unblock-File .\boring.ps1
```

**Linux / macOS:**

```bash
curl -fsSLO https://raw.githubusercontent.com/game7/boring/main/boring.sh
chmod +x boring.sh
```

If PowerShell's execution policy blocks the script, run it with
`powershell -ExecutionPolicy Bypass -File .\boring.ps1 <host>`.

## Limitations

- When the port set changes, the tunnel restarts, which drops open connections such as WebSockets
  and HMR for a moment. Browsers and Vite reconnect automatically. A restart is needed because
  Windows OpenSSH has no `ControlMaster`, so forwards can't be added to a live connection.
- A new port appears locally within one scan interval, 5 seconds by default.
- Only TCP is forwarded.
- Servers that pick "the next free port" may land on different numbers on the remote than you
  expect. boring forwards whatever the remote actually picks.

## Roadmap

The scripts are the MVP. If boring proves useful, the plan is a single Go binary that keeps one
SSH connection open and adds or removes forwards without restarting, so connections aren't
dropped.

## Name

This project isn't related to [alebeck/boring](https://github.com/alebeck/boring), a separate SSH
tunnel manager.
