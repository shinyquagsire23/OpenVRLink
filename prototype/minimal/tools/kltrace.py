#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Turn a Klepton network trace into a packet list.

Klepton run with KL_TRACE_NET=1 KL_TRACE_NET_HEX=<n> prints, for every socket
call the guest makes, a `[net]` line followed by a hex line:

      [net] sendto(fd=8, 30 B, flags=0x0->0x0, [::ffff:192.168.4.28]:27036) -> 30
           -> ffffffff214c5fa0...  |....|
      [net] recvfrom(fd=8, 1500 B, flags=0x0->0x0) -> 214 from [::ffff:192.168.4.28]:27036
           <- ffffffff214c5fa0...  |....|

This module parses those pairs. The log has no timestamps, so the only clock
is order. Captures contain live credentials — keep them out of the repo.

    kltrace.py <log> [--fd N] [--port P] [--limit N]     # one line per packet
"""
import argparse
import re
from dataclasses import dataclass

SEND = re.compile(
    r"\[net\] (?:sendto|sendmsg|send)\(fd=(?P<fd>\d+), \d+ B, flags=\S+, (?P<peer>[^()]+)\) -> (?P<n>-?\d+)")
RECV = re.compile(
    r"\[net\] (?:recvfrom|recvmsg|recv)\(fd=(?P<fd>\d+), \d+ B, flags=\S+\) -> (?P<n>-?\d+) from (?P<peer>\S+)")
HEX = re.compile(r"\s+(?P<dir>->|<-) (?P<hex>[0-9a-f]+)  \|.*\|(?: t=(?P<t>\d+\.\d+))?$")
# The [net] line and its hex line are separate writes, and a busy receive
# thread can put hundreds of lines between them (8 lost 24 datagrams of an
# 80,000-datagram capture).
LOOKBACK = 400


@dataclass
class Packet:
    index: int        # ordinal among parsed packets
    time: float       # CLOCK_MONOTONIC seconds, 0.0 if the trace predates timestamps
    line: int         # line number in the log, for going back to context
    fd: int
    outbound: bool
    peer: str         # "-" on a connected socket
    data: bytes
    truncated: bool   # the hex dump was shorter than the datagram

    @property
    def arrow(self):
        return "->" if self.outbound else "<-"


def parse(path):
    """Yield every traced packet in the log, in order."""
    with open(path, "rb") as handle:
        lines = handle.read().decode("latin1").replace("\r", "").split("\n")
    index = 0
    claimed = set()
    for number, line in enumerate(lines):
        payload = HEX.match(line)
        if not payload:
            continue
        data = bytes.fromhex(payload["hex"])
        outbound = payload["dir"] == "->"
        # Find the call this dump belongs to: nearest earlier unclaimed [net]
        # line in the same direction that moved at least this many bytes.
        for back in range(number - 1, max(number - 1 - LOOKBACK, -1), -1):
            call = (SEND if outbound else RECV).search(lines[back])
            if call and back not in claimed and int(call["n"]) >= len(data):
                claimed.add(back)
                break
        else:
            continue
        yield Packet(index, float(payload["t"] or 0), back + 1, int(call["fd"]), outbound,
                     call["peer"].strip(), data, len(data) < int(call["n"]))
        index += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("log")
    parser.add_argument("--fd", type=int)
    parser.add_argument("--port", type=int, help="keep packets whose peer ends in :PORT")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--width", type=int, default=64, help="hex bytes shown per packet")
    args = parser.parse_args()
    shown = 0
    for packet in parse(args.log):
        if args.fd is not None and packet.fd != args.fd:
            continue
        if args.port is not None and not packet.peer.endswith(f":{args.port}"):
            continue
        print(f"{packet.index:6d} {packet.time:13.6f} fd{packet.fd} {packet.arrow} {packet.peer:34s} "
              f"{len(packet.data):5d}{'+' if packet.truncated else ' '} "
              f"{packet.data[:args.width].hex()}")
        shown += 1
        if args.limit and shown >= args.limit:
            break


if __name__ == "__main__":
    main()
