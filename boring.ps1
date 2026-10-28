<#
.SYNOPSIS
  boring: forward a remote host's listening TCP ports to the same ports on this machine's localhost.

.DESCRIPTION
  Forwards every TCP port listening on the remote host's loopback or wildcard address to the same
  port on this machine's localhost. Rescans every few seconds and restarts one ssh tunnel when the
  set changes. Uses your ssh client, so ~/.ssh/config, keys, agent and known_hosts all apply;
  key-based authentication is required.

  Inspired by mole (https://github.com/Luqueee/mole, MIT licence).

.EXAMPLE
  .\boring.ps1 my-dev-box

.EXAMPLE
  .\boring.ps1 -Exclude 3773 -Interval 3 user@devbox
#>
# Write-Host is deliberate: status lines are for the console, not the pipeline.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
# MaxPort is read inside Get-RemotePort, which the analyzer does not follow.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MaxPort')]
[CmdletBinding()]
param(
  # The remote host: an ~/.ssh/config alias or [user@]host.
  [Parameter(Mandatory = $true, Position = 0)][string]$HostName,
  # Rescan interval in seconds.
  [int]$Interval = 5,
  # More remote ports to exclude; 22, 25, 53, 111 and 631 are always excluded.
  [int[]]$Exclude = @(),
  # Ignore remote ports above this (default: below Linux's ephemeral range).
  [int]$MaxPort = 32767
)

$ErrorActionPreference = 'Stop'
$version = '0.1.0'
$excluded = @(22, 25, 53, 111, 631) + $Exclude
$sshOptions = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3')
# Runs in the remote login shell: Linux ss, then Linux netstat, then BSD/macOS netstat.
$listeners = 'ss -Hltn 2>/dev/null || netstat -ltn 2>/dev/null || netstat -an -p tcp'

function Write-Status([string]$Message) {
  Write-Host ('{0:HH:mm:ss} {1}' -f (Get-Date), $Message)
}

# Returns the remote's forwardable listening ports, or $null if the host is unreachable.
function Get-RemotePort {
  $output = & ssh @sshOptions $HostName $listeners 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }

  $ports = foreach ($line in $output) {
    if ($line -notmatch 'LISTEN') { continue }

    $address = ($line.Trim() -split '\s+')[3]
    if ($address -notmatch '^(.*)[:.](\d+)$') { continue }

    $ip = $Matches[1] -replace '[\[\]]', '' -replace '%.*$', ''
    $port = [int]$Matches[2]
    if ($port -lt 1 -or $port -gt $MaxPort -or $excluded -contains $port) { continue }
    if ($ip -in @('*', '0.0.0.0', '::', '::1') -or $ip -like '127.*' -or $ip -like '::ffff:127.*') { $port }
  }

  return , @($ports | Sort-Object -Unique)
}

function Get-LocalListeningPort {
  [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
    ForEach-Object { $_.Port }
}

function Open-Tunnel([int[]]$Ports) {
  $arguments = $sshOptions + @('-N', '-o', 'ExitOnForwardFailure=yes')
  foreach ($port in $Ports) { $arguments += @('-L', "${port}:localhost:$port") }
  $arguments += $HostName

  Start-Process -FilePath ssh -ArgumentList $arguments -NoNewWindow -PassThru
}

function Close-Tunnel($Process) {
  if ($Process -and -not $Process.HasExited) {
    $Process.Kill()
    $Process.WaitForExit()
  }
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  throw 'ssh was not found on PATH. Install the OpenSSH client (Windows: Settings > Optional features).'
}

$tunnel = $null
$forwarded = @()
$warned = @()

Write-Status "boring ${version}: watching $HostName every ${Interval}s (Ctrl-C to stop)"

try {
  while ($true) {
    $discovered = Get-RemotePort
    if ($null -eq $discovered) {
      Write-Status "cannot list ports on $HostName; retrying"
      Start-Sleep -Seconds $Interval
      continue
    }

    $tunnelAlive = $tunnel -and -not $tunnel.HasExited
    # Ports held by a live tunnel are ours; after it exits, every port is checked again.
    $owned = if ($tunnelAlive) { $forwarded } else { @() }
    $busy = @(Get-LocalListeningPort)

    $wanted = @(foreach ($port in $discovered) {
        if ($owned -contains $port -or $busy -notcontains $port) { $port }
        elseif ($warned -notcontains $port) {
          Write-Status "skipping ${port}: already in use on this machine"
          $warned += $port
        }
      })
    $warned = @($warned | Where-Object { $discovered -contains $_ -and $busy -contains $_ })

    $changed = ($wanted -join ' ') -ne ($forwarded -join ' ')
    if ($changed -or ($forwarded.Count -gt 0 -and -not $tunnelAlive)) {
      foreach ($port in $wanted) { if ($forwarded -notcontains $port) { Write-Status "+ localhost:$port" } }
      foreach ($port in $forwarded) { if ($wanted -notcontains $port) { Write-Status "- localhost:$port" } }
      if (-not $changed) { Write-Status "tunnel to $HostName exited; reconnecting" }

      Close-Tunnel $tunnel
      $tunnel = $null
      $forwarded = $wanted
      if ($wanted.Count -gt 0) { $tunnel = Open-Tunnel $wanted }
    }

    Start-Sleep -Seconds $Interval
  }
}
finally {
  Close-Tunnel $tunnel
}
