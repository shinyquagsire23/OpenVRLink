#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run one streaming session per experiment, each leaving out one published
value, and report what the host did.

    ablate.py <host> [--seconds 8] [id ...]      # ids in hex; default: every startup value

The first run is the control (nothing omitted). Runs are spaced so that each
meets a cold host.
"""
import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ovrlink import broadcast, pairing, profile  # noqa: E402
from ovrlink.client import Client  # noqa: E402
from ovrlink.identity import Identity  # noqa: E402

# SteamVR on the host exits about 30 s after the client drops. Shorter gaps
# test a host that still remembers the previous session's device description,
# which streams no matter what is published (45 s was measured as too short).
COLD_GAP_SECONDS = 62

NAMES = {value: name for name, value in vars(profile).items()
         if name.isupper() and isinstance(value, int)}


def run(host_address, omit, seconds):
    sock, identity = broadcast.open_socket(), Identity()
    host = pairing.find_host(sock, identity, host_address)
    session = pairing.request_session(sock, identity, host)
    client = Client(session, log=lambda message: None, omit=omit)
    stats = client.run(seconds, lambda frame_id, frame: None)
    times = sorted(stats.frame_times.items())
    host_fps = 0.0
    if len(times) > 10:
        span = ((times[-1][1] - times[0][1]) % (1 << 32)) / 1e6
        host_fps = (times[-1][0] - times[0][0]) / span if span else 0.0
    return stats, host_fps, client


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("host")
    parser.add_argument("ids", nargs="*", type=lambda text: int(text, 16))
    parser.add_argument("--seconds", type=float, default=8)
    args = parser.parse_args()
    ids = args.ids or sorted(profile.startup_values(1)) + [profile.FOCUS_EVENT]
    print(f"{'omitted':28s} first frame  frames  incomplete  host fps  audio  host rate request")
    for omit in [None] + ids:
        label = "(control)" if omit is None else f"{omit:#04x} {NAMES.get(omit, '')}"
        try:
            stats, host_fps, client = run(args.host, () if omit is None else (omit,), args.seconds)
        except Exception as error:  # a refused or timed-out session is a result too
            print(f"{label:28s} session failed: {type(error).__name__} {error}")
            time.sleep(COLD_GAP_SECONDS)
            continue
        first = f"{stats.first_frame_at:6.2f} s" if stats.frames else "   never"
        asked = profile.DISPLAY_RATE_REQUEST in client.values.remote
        print(f"{label:28s} {first:>11s} {stats.frames:7d} {client.assembler.dropped:11d} "
              f"{host_fps:9.1f} {stats.audio_messages:6d}  {'yes' if asked else 'no'}", flush=True)
        time.sleep(COLD_GAP_SECONDS)


if __name__ == "__main__":
    main()
