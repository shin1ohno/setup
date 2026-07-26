#!/usr/bin/env python3
"""Discover ECHONET Lite devices on the LAN and report which ones are aircons.

Why this exists: homebridge-echonet-lite-aircon auto-discovers its accessories,
so when an aircon is missing from HomeKit there is nothing in the Homebridge log
to distinguish "unit powered off", "wireless LAN adapter offline" and "ECHONET
Lite not enabled in the Eolia app" — all three look like silence. This probe
answers "does anything on this LAN speak ECHONET Lite right now" directly.

Usage:
    echonet-discover                  # multicast discovery (default)
    echonet-discover --sweep          # + unicast probe of every host in the /24
    echonet-discover --timeout 10     # listen longer

Exit status: 0 if at least one home air conditioner (EOJ class group 0x01,
class 0x30) answered, 1 if none answered, 2 if the probe could not run.
Safe to use as a verification gate.

Port note: this binds UDP 3610 rather than an ephemeral port, because the
aircons here answer to 3610 regardless of the request's source port — a probe
from an ephemeral port gets silence even from a unit that is up (measured
2026-07-26). node-echonet-lite opens 3610 without SO_REUSEADDR, so this cannot
share the port with a running Homebridge; on the Homebridge host itself, stop
the service first or probe from another host on the same LAN segment.
"""

import argparse
import binascii
import errno
import ipaddress
import socket
import struct
import subprocess
import sys
import time

MULTICAST_GROUP = "224.0.23.0"
PORT = 3610

# EHD1=0x10 EHD2=0x81 TID=0x0001 SEOJ=05FF01 (controller) DEOJ=0EF001 (node
# profile) ESV=0x62 (Get) OPC=0x01 EPC=0xD6 (self-node instance list S) PDC=0x00
DISCOVERY_FRAME = bytes.fromhex("1081000105FF010EF0016201D600")

# EOJ class group + class -> human label. Only the classes we care about are
# named; anything else is reported by its raw hex.
KNOWN_CLASSES = {
    (0x01, 0x30): "home air conditioner",
    (0x00, 0x11): "temperature sensor",
    (0x00, 0x12): "humidity sensor",
    (0x02, 0x87): "distribution panel metering",
    (0x02, 0x90): "general lighting",
    (0x05, 0xFD): "switch",
    (0x05, 0xFF): "controller",
    (0x0E, 0xF0): "node profile",
}

AIRCON_CLASS = (0x01, 0x30)


def parse_instance_list(payload: bytes):
    """Extract the EOJ list from a Get_Res / INF frame carrying EPC 0xD6.

    Returns a list of (class_group, class_code, instance) tuples. Frames that
    are not a readable response to our request yield an empty list.
    """
    if len(payload) < 12 or payload[0] != 0x10 or payload[1] != 0x81:
        return []
    esv = payload[10]
    # 0x72 = Get_Res, 0x73 = INF (unsolicited announce, same EDT layout)
    if esv not in (0x72, 0x73):
        return []
    opc = payload[11]
    offset = 12
    eojs = []
    for _ in range(opc):
        if offset + 2 > len(payload):
            break
        epc = payload[offset]
        pdc = payload[offset + 1]
        edt = payload[offset + 2 : offset + 2 + pdc]
        offset += 2 + pdc
        if epc != 0xD6 or len(edt) < 1:
            continue
        count = edt[0]
        for i in range(count):
            eoj = edt[1 + i * 3 : 4 + i * 3]
            if len(eoj) == 3:
                eojs.append((eoj[0], eoj[1], eoj[2]))
    return eojs


def local_ipv4_networks():
    """Best-effort list of directly-attached IPv4 /24-or-smaller networks."""
    try:
        out = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", "scope", "global"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    nets = []
    for line in out.splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        try:
            net = ipaddress.ip_network(fields[3], strict=False)
        except ValueError:
            continue
        if net.version == 4 and net.num_addresses <= 256 and not net.is_loopback:
            nets.append(net)
    return nets


class PortBusy(Exception):
    """UDP 3610 is held by another process (almost always Homebridge)."""


def discover(timeout: float, sweep: bool):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", PORT))
    except OSError as exc:
        sock.close()
        if exc.errno == errno.EADDRINUSE:
            raise PortBusy from exc
        raise
    sock.setsockopt(
        socket.IPPROTO_IP,
        socket.IP_ADD_MEMBERSHIP,
        struct.pack("4sl", socket.inet_aton(MULTICAST_GROUP), socket.INADDR_ANY),
    )
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.setblocking(False)

    targets = [(MULTICAST_GROUP, PORT)]
    if sweep:
        for net in local_ipv4_networks():
            targets.extend((str(host), PORT) for host in net.hosts())

    for target in targets:
        try:
            sock.sendto(DISCOVERY_FRAME, target)
        except BlockingIOError:
            time.sleep(0.02)
        except OSError:
            pass

    found = {}
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(1500)
        except BlockingIOError:
            time.sleep(0.05)
            continue
        if data == DISCOVERY_FRAME:
            continue
        eojs = parse_instance_list(data)
        if not eojs:
            continue
        found.setdefault(addr[0], set()).update(eojs)
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--timeout",
        type=float,
        default=6.0,
        help="seconds to listen for responses (default: 6)",
    )
    parser.add_argument(
        "--sweep",
        action="store_true",
        help="also unicast-probe every host on the attached /24 "
        "(catches units that ignore multicast)",
    )
    args = parser.parse_args()

    try:
        found = discover(args.timeout, args.sweep)
    except PortBusy:
        print(f"UDP {PORT} is already in use, so this probe cannot listen for replies.")
        print(
            "Homebridge holds that port while it runs. Either stop it first "
            "(systemctl stop homebridge), or run this probe from another host "
            "on the same LAN segment."
        )
        return 2

    if not found:
        print("No ECHONET Lite responders on this LAN.")
        print(
            "Check that each aircon's wireless LAN adapter is online and that "
            "ECHONET Lite is enabled for it in the Eolia app."
        )
        return 1

    aircons = 0
    for ip in sorted(found, key=lambda a: tuple(int(o) for o in a.split("."))):
        print(ip)
        for group, cls, inst in sorted(found[ip]):
            label = KNOWN_CLASSES.get((group, cls), "unknown class")
            eoj = binascii.hexlify(bytes([group, cls, inst])).decode()
            print(f"  EOJ {eoj}  {label} (instance {inst})")
            if (group, cls) == AIRCON_CLASS:
                aircons += 1

    print(f"\n{aircons} home air conditioner instance(s) found.")
    return 0 if aircons else 1


if __name__ == "__main__":
    sys.exit(main())
