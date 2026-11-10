#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""List the SVL elements in a Klepton capture.

    svldump.py <log>                     # element-kind census per direction
    svldump.py <log> --list [--kind 0x0d03] [--limit N]   # one line per element
"""
import argparse
import collections
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import kltrace  # noqa: E402
from ovrlink import svl  # noqa: E402

SVL_PORT = 10400


def elements(log):
    """Yield (packet, datagram, element) for every intact SVL datagram."""
    for packet in kltrace.parse(log):
        if not packet.peer.endswith(f":{SVL_PORT}") or packet.truncated:
            continue
        datagram = svl.unpack(packet.data)
        if datagram is None:
            continue
        for element in datagram.elements:
            yield packet, datagram, element


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("log")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--kind", type=lambda text: int(text, 0))
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--width", type=int, default=48)
    args = parser.parse_args()

    census = collections.Counter()
    sizes = collections.defaultdict(list)
    shown = 0
    for packet, datagram, element in elements(args.log):
        if args.kind is not None and element.kind != args.kind:
            continue
        key = (packet.arrow, element.kind)
        census[key] += 1
        sizes[key].append(len(element.value))
        if args.list and not (args.limit and shown >= args.limit):
            print(f"{packet.index:6d} {packet.time:12.6f} {packet.arrow} seq={datagram.seq:5d} "
                  f"class={element.cls:#04x} type={element.type:#04x} id={element.id:5d} index={element.index:#06x} "
                  f"len={len(element.value):4d} {element.value[:args.width].hex()}")
            shown += 1
    if not args.list:
        for (arrow, kind), count in sorted(census.items()):
            lengths = sizes[(arrow, kind)]
            print(f"{arrow} class={kind & 0xff:#04x} type={kind >> 8:#04x} "
                  f"x{count:5d}  len {min(lengths)}..{max(lengths)}")


if __name__ == "__main__":
    main()
