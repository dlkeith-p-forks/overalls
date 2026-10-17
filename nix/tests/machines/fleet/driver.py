"""Real minimum control-plane topology, enrolled native capacity and nested guests."""

# Stdlib imports for the whole composed fleet script: scenario fragments are
# concatenated below this header and share this single module namespace.
import json
import os
import shlex
import subprocess
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

root = "/var/lib/overalls-fleet"
private = Path(tempfile.mkdtemp(prefix="overalls-fleet-private-"))
marshalls = [m1, m2, m3]
provisioners = [l1, l2]
# Replacement journeys define replacement_host in their testScript header; the
# default fleet journey has none.
