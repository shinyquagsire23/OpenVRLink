#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Rebuild the video stream from a Klepton capture and check it against the
elementary stream the real client fed its decoder (KL_VTDEC_DUMP).

    replay_video.py <log> [--reference dump.h265] [--out rebuilt.h265]
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import svldump  # noqa: E402  (also puts the package on sys.path)
from ovrlink.video import FrameAssembler  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("log")
    parser.add_argument("--reference")
    parser.add_argument("--out")
    args = parser.parse_args()

    assembler = FrameAssembler()
    frames = []
    for packet, _datagram, element in svldump.elements(args.log):
        if not packet.outbound and (done := assembler.accept(element)):
            frames.append(done)
    total = sum(len(data) for _, data in frames)
    print(f"{len(frames)} frames rebuilt ({total} bytes), {assembler.dropped} incomplete")
    if args.out:
        Path(args.out).write_bytes(b"".join(data for _, data in frames))
    if args.reference:
        reference = Path(args.reference).read_bytes()
        found = sum(data in reference for _, data in frames)
        print(f"{found} of {len(frames)} found byte-for-byte in {args.reference}")


if __name__ == "__main__":
    main()
