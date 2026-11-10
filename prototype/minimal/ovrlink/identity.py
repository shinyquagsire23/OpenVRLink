# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""This client's persistent identity: a device id and one pairing secret per host.

The Steam Link client keeps the same things as device_id.txt and
<host client id>/<steamid>/secret_key.txt. Ours live in one JSON file in the
OpenVRLink data directory (docs/client-architecture.md), shared with the Swift
client and outside the repository, because the secrets are live credentials.
"""
import json
import os
import random
import sys
from pathlib import Path



def data_directory():
    """The per-user data folder: Application Support on macOS, %LOCALAPPDATA%
    on Windows, $XDG_DATA_HOME (default ~/.local/share) elsewhere."""
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    elif sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
    else:
        base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return base / "OpenVRLink"


PATH = data_directory() / "identity.json"


class Identity:
    def __init__(self, path=PATH):
        self.path = path
        state = json.loads(path.read_text()) if path.exists() else {}
        self.device_id = state.get("device_id") or random.getrandbits(64) or 1
        self._secrets = {int(k): bytes.fromhex(v) for k, v in state.get("secrets", {}).items()}

    def secret(self, host_client_id):
        """The 32-byte key shared with a host. Before pairing it is random,
        which the host answers with Unauthorized."""
        if host_client_id not in self._secrets:
            self._secrets[host_client_id] = os.urandom(32)
        return self._secrets[host_client_id]

    def set_secret(self, host_client_id, secret):
        self._secrets[host_client_id] = secret
        self.save()

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        state = {"device_id": self.device_id,
                 "secrets": {str(k): v.hex() for k, v in self._secrets.items()}}
        self.path.touch(mode=0o600, exist_ok=True)
        self.path.write_text(json.dumps(state, indent=1))
