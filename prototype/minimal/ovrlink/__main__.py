# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Protocol probe for Steam VR Link.

    python3 -m ovrlink discover [host ...]     find Steam hosts
    python3 -m ovrlink pair <host>             pair with a host (someone types the PIN there)
    python3 -m ovrlink session <host>          ask a paired host to start SteamVR streaming
    python3 -m ovrlink stream <host> out.h265  start a session and save the video it sends
"""
import argparse

from google.protobuf import text_format

from . import broadcast, pairing
from .identity import Identity


def cmd_discover(args):
    sock = broadcast.open_socket()
    targets = args.hosts or ["255.255.255.255"]
    hosts = broadcast.discover(sock, broadcast.random_client_id(), targets, wait=args.wait)
    if not hosts:
        print("no Steam hosts answered")
    for (ip, port), datagram in sorted(hosts.items()):
        status = datagram.body
        print(f"{ip}:{port}  {status.hostname}  client_id={datagram.header.client_id} "
              f"instance_id={datagram.header.instance_id}")
        print("   ", text_format.MessageToString(status, as_one_line=True))


def cmd_pair(args):
    sock, identity = broadcast.open_socket(), Identity()
    host = pairing.find_host(sock, identity, args.host)
    print(f"pairing with {host.status.hostname} ({host.address[0]})")
    pairing.pair(sock, identity, host, args.name,
                 lambda pin: print(f"enter this PIN in Steam on the host: {pin}"))
    print(f"paired; secret stored in {identity.path}")


def cmd_session(args):
    sock, identity = broadcast.open_socket(), Identity()
    host = pairing.find_host(sock, identity, args.host)
    try:
        session = pairing.request_session(sock, identity, host, log=print)
    except pairing.Unauthorized:
        raise SystemExit("host says this device is not authorized; run `pair` first")
    fields = session.fields
    # The token is a live credential for this one session; show its shape only.
    print(f"host={session.host} port={session.port} start_info={fields[3]!r} "
          f"token={session.token[:4]}… ({len(session.token)} chars)")
    if args.show_args:
        print(session.raw)


def cmd_stream(args):
    from .client import Client
    sock, identity = broadcast.open_socket(), Identity()
    host = pairing.find_host(sock, identity, args.host)
    try:
        session = pairing.request_session(sock, identity, host, log=print)
    except pairing.Unauthorized:
        raise SystemExit("host says this device is not authorized; run `pair` first")
    client = Client(session)
    with open(args.output, "wb") as output:
        stats = client.run(args.seconds, lambda frame_id, frame: output.write(frame))
    client.close()
    print(f"{stats.frames} frames, {stats.frame_bytes} bytes written to {args.output}")
    print("messages received:", {f"{kind:#06x}": count for kind, count in sorted(stats.kinds.items())})


def main():
    parser = argparse.ArgumentParser(prog="ovrlink", description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    discover = commands.add_parser("discover", help="find Steam hosts on the LAN")
    discover.add_argument("hosts", nargs="*", help="probe these addresses instead of broadcasting")
    discover.add_argument("--wait", type=float, default=1.5)
    discover.set_defaults(run=cmd_discover)
    pair = commands.add_parser("pair", help="pair with a host by PIN")
    pair.add_argument("host")
    pair.add_argument("--name", default="OpenVRLink probe", help="device name shown on the host")
    pair.set_defaults(run=cmd_pair)
    session = commands.add_parser("session", help="request a SteamVR streaming session")
    session.add_argument("host")
    session.add_argument("--show-args", action="store_true", help="print the full session string")
    session.set_defaults(run=cmd_session)
    stream = commands.add_parser("stream", help="receive video from a paired host")
    stream.add_argument("host")
    stream.add_argument("output", help="HEVC elementary stream (Annex-B) to write")
    stream.add_argument("--seconds", type=float, default=20)
    stream.set_defaults(run=cmd_stream)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
