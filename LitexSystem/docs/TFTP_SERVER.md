<!--
  Know-how from setting up the TFTP server for the TFTP netboot of mmRISC-2's LiteX BIOS
  (LitexSystem/software/boot/README.md, "TFTP netboot of the LiteX BIOS") on Ubuntu in Parallels
  Desktop on a Mac. Summarized in another Claude chat, "TFTP access to Ubuntu on Parallels
  Desktop" (2026-09-26), and recorded here as it was.

  Notes for this board:
  - The client is the Arty's LiteX BIOS (`netboot`). The BIOS asks for `blksize 1024` (as in the
    tcpdump example below). The files to put there are Image, fw_jump.bin and boot.json.
  - The first netboot on the board failed because ufw had UDP 69 closed (section 3 below).
  - Linux on the board also has BusyBox's tftp client, which can be used to check from an outside
    machine: `tftp -g -b 1024 -r <FILE> <SERVER_IP>`
-->

# Serving TFTP to the LAN from Ubuntu on a Mac (Parallels Desktop)

[日本語](TFTP_SERVER_J.md)

How to run a TFTP server on Ubuntu in Parallels Desktop on a Mac so that outside machines on the same
LAN (an evaluation board, for example) can reach it, and the points where it is easy to get stuck.

## Notation

Read the placeholders in the text as fits your setup.

| Placeholder | Meaning | Example |
|---|---|---|
| `<SERVER_IP>` | IP address of Ubuntu (the TFTP server) | 192.168.x.y |
| `<CLIENT_IP>` | IP address of the outside machine (the TFTP client) | 192.168.x.z |
| `<LAN_SUBNET>` | LAN subnet | 192.168.x.0/24 |
| `<IFACE>` | Ubuntu's network interface | enp0s5, for example |
| `<FILE>` | File to fetch | boot.bin, for example |

## 1. Parallels: use a bridged network

In the VM's "Configuration" → "Hardware" → "Network", set the source to "Bridged Network" and choose
explicitly the Mac interface the outside machine is connected to (Wi-Fi / Ethernet / USB-Ethernet).

Port forwarding can be set up with the shared network (NAT) too, but TFTP uses UDP 69 only for the
first request, and the server answers the data transfer from an ephemeral port, so it tends to be
unreliable through NAT. A bridge is the sure way.

After setting it, check that Ubuntu has a LAN address.

```bash
ip -4 addr
```

## 2. Ubuntu: install and configure tftpd-hpa

```bash
sudo apt install tftpd-hpa tftp-hpa
```

`/etc/default/tftpd-hpa`:

```
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure"
```

To allow uploads (put) from clients to create new files, add `--create` to `TFTP_OPTIONS`; for a more
detailed log, add `-v -v`.

```bash
sudo mkdir -p /srv/tftp
sudo chown tftp:tftp /srv/tftp
sudo chmod 775 /srv/tftp
sudo systemctl restart tftpd-hpa
```

Check what it listens on. `0.0.0.0:69` (or `*:69`) is fine. With `127.0.0.1:69` nothing from outside
reaches it.

```bash
sudo ss -ulnp | grep ':69'
```

## 3. Ubuntu: allow UDP 69 in ufw

When ufw is enabled with the default `deny (incoming)`, requests to UDP 69 are silently dropped with no
answer. That is often the state right after installing Ubuntu or after allowing only SSH, so allow TFTP
from the LAN.

```bash
sudo ufw allow from <LAN_SUBNET> to any port 69 proto udp comment 'TFTP'
sudo ufw status verbose
```

What you should see:

```
69/udp                     ALLOW IN    <LAN_SUBNET>               # TFTP
```

Only 69/udp needs to be allowed. The data transfer is started by the server, sending first from an
ephemeral port, so the ACKs from the client pass as ESTABLISHED through conntrack.

## 4. Checking it

Watch the packets on Ubuntu while getting a file from the outside machine.

```bash
sudo tcpdump -ni any host <CLIENT_IP>
```

On the outside machine:

```bash
tftp <SERVER_IP> -c get <FILE>
```

When it works, OACK / DATA go `Out` from Ubuntu in answer to the RRQ (the port numbers depend on the
setup).

```
In  IP <CLIENT_IP>.<cport> > <SERVER_IP>.69: TFTP, RRQ "<FILE>" octet blksize 1024
Out IP <SERVER_IP>.<sport> > <CLIENT_IP>.<cport>: TFTP, OACK ...
In  IP <CLIENT_IP>.<cport> > <SERVER_IP>.<sport>: TFTP, ACK ...
Out IP <SERVER_IP>.<sport> > <CLIENT_IP>.<cport>: TFTP, DATA ...
```

## Cautions

**A test from Ubuntu itself does not check the outside path.** Running tftp on Ubuntu to its own IP goes
through loopback, so it succeeds even when ufw drops the packets on the outward interface. Always try
from an outside machine (at least from the Mac).

**ping working does not mean TFTP works.** ping (ICMP) and TFTP (UDP 69) are treated separately by the
firewall. Whether it really is Ubuntu that answers the ping can be checked by matching the MAC address
in `arp -a` on the client with the MAC address in Ubuntu's `ip link`.

**"In" in tcpdump does not mean the packet passed the firewall.** tcpdump catches packets before
netfilter, so a packet it shows may still be dropped by ufw.

**Filtering on `udp` alone hides ICMP.** When tftpd is not listening, the kernel answers with ICMP port
unreachable, which `tcpdump ... udp` does not show. When narrowing it down, filter on `host` only.

## Narrowing it down from what tcpdump shows

| What tcpdump shows | Likely causes |
|---|---|
| Not even the RRQ | The Mac (pf, security software), the network settings of Parallels, a duplicate IP |
| The RRQ, but no answer at all | Dropped by Ubuntu's firewall (ufw / iptables / nftables) |
| ICMP port unreachable in answer to the RRQ | tftpd is not listening (`TFTP_ADDRESS` and the like) |
| DATA goes out but the client fails | The client's firewall (Windows, for example) or a device on the way |

### Commands for checking

Ubuntu:

```bash
sudo ufw status verbose
sudo journalctl -k | grep 'UFW BLOCK' | grep 'DPT=69'
sudo nft list ruleset
sudo journalctl -u tftpd-hpa -f
```

Mac:

```bash
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
sudo pfctl -s info
sudo pfctl -s rules
```

How UDP 69 looks from outside (if nmap is available):

```bash
sudo nmap -sU -p 69 <SERVER_IP>
```

## Note

To make other services on Ubuntu (NFS, DHCP and so on) reachable from outside, open their ports one by
one with `sudo ufw allow` in the same way.
