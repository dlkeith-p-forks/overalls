"""@cc [owner:ghuntley,label:security] packaged-localization-context
The disposable login link MUST remain owner-private and MUST NOT be printed.
"""

import json
import os
from pathlib import Path

os.umask(0o077)
token: str = Path("/run/overalls-test/localization-login").read_text().strip()
context: dict[str, str] = {
    "origin": "https://localhost",
    "owner": "/magic_link/" + token,
    "vm_id": Path("/run/overalls-test/localization-machine").read_text().strip(),
}
with Path("/run/overalls-test/localization-context.json").open("x") as stream:
    json.dump(context, stream)
