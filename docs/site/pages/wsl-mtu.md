---
title: wsl mtu stalls
nav: 16
description: Sessions to a WSL2 host that connect fine, then freeze mid-output — diagnosing and fixing the MTU black hole.
---

# WSL MTU stalls

A WSL2 host is the one setup where a session connects normally and then simply
stops, with no error on either end. It is almost never SSH or Tessera — it is
the MTU of the virtual adapter WSL2 sits behind.

## Symptoms

- The session connects, the prompt appears, and short commands run fine.
- Anything that sends a large burst freezes: `cat` on a long file, a wide
  `ls`, a full tmux redraw, a transfer in the [files panel](files.md).
- Nothing reports a failure. The session just stops moving. Reconnecting
  works, then stalls again on the same kind of output.
- The same host over mosh behaves better than over ssh.

If the connection never reaches a prompt at all, the same fault can be
swallowing the SSH key exchange, which is itself large. The test below still
applies.

## Why it happens

WSL2 runs behind a Hyper-V virtual switch, and its `eth0` comes up with an MTU
of 1500. When the Windows host actually reaches the network through something
smaller — a VPN, PPPoE, or any tunnel — packets above that real path MTU are
dropped somewhere in between.

Path MTU discovery is supposed to handle exactly this: the hop that can't
forward the packet returns an ICMP *fragmentation needed*, and the sender backs
off. Many VPNs and firewalls drop that ICMP, so no reply ever arrives. Small
packets keep flowing and large ones vanish silently — a PMTU black hole. To
SSH that looks like a connection that stopped for no reason.

## Confirm it

From inside WSL, check what the interface claims:

```
ip link show eth0
```

Then find the size that actually survives the path. These pings set
don't-fragment, and the payload plus 28 bytes of header is the total size, so
`-s 1472` probes a 1500-byte packet. Aim at something on the far side of the
same path — the server you connect to, or any public address:

```
ping -M do -s 1472 -c 1 example.com   # 1500 — usually times out
ping -M do -s 1372 -c 1 example.com   # 1400 — usually gets through
```

A **timeout** is the black hole. (An immediate local error instead means the
size exceeds your own interface MTU — lower `-s` and try again.) Narrow the
range until you find the largest payload that answers; add 28 and that is your
real path MTU.

The Windows-side equivalents, from PowerShell:

```
ping -f -l 1472 example.com
netsh interface ipv4 show subinterfaces
```

The second lists the MTU of every adapter. A VPN adapter sitting at 1400
alongside `vEthernet (WSL)` at 1500 is the mismatch you're chasing.

## Fix it in WSL

Set the interface to the size you measured. This takes effect immediately and
is lost at next shutdown:

```
sudo ip link set dev eth0 mtu 1400
```

Reconnect and repeat whatever used to stall. If the output runs clean, the
diagnosis is confirmed.

To make it stick, have WSL apply it at boot. In `/etc/wsl.conf` inside the
distro:

```
[boot]
command = ip link set dev eth0 mtu 1400
```

Then run `wsl --shutdown` from Windows and start the distro again. The `[boot]`
command needs a reasonably current WSL — check with `wsl --version`.

Use the number your ping test produced rather than copying 1400. It is a safe
fallback that clears almost every VPN, but a value matched to your path wastes
less of every packet.

## Or let WSL mirror the host

On Windows 11 22H2 and later with WSL 2.0+, mirrored networking hands the
distro the host's own interfaces, MTUs included, so the mismatch never arises.
In `%UserProfile%\.wslconfig`:

```
[wsl2]
networkingMode=mirrored
```

Apply it with `wsl --shutdown`. This changes considerably more than the MTU —
localhost and LAN reachability both behave differently — so prefer the boot
command if a stalling session is the only problem you have.

## When the low-MTU hop is on the server's side

WSL is not always the constrained end; running the same ping test from the
server tells you which side is clamped. Where you control the router in
between, clamping TCP's MSS to the discovered path MTU fixes every connection
through it at once:

```
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu
```

## While you're still stuck

Switching the host's [transport](connections.md#transport-ssh-or-mosh) to mosh
is a workaround rather than a fix. Mosh's datagrams are small enough to slip
under a broken MTU, and it repaints the screen instead of replaying a byte
stream, so an interactive session survives. The files panel and the tmux side
channel still ride SSH, so large transfers can continue to stall.

If none of this matches what you're seeing, capture a log
(**settings → diagnostics → export log**, see [diagnostics](security.md#diagnostics))
and open an issue at
[GitHub Issues](https://github.com/bambouville/tessera/issues).
