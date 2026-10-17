"""Network-enabled extension maintenance; ordinary package builds remain offline."""

from extensions import update_main

if __name__ == "__main__":
    raise SystemExit(update_main())
