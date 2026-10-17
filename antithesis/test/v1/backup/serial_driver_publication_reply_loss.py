#!/usr/bin/env python3.13
"""Lose a real manifest upload reply and retain the published recovery point."""

from backup.scenarios import run_publication_reply_loss

if __name__ == "__main__":
    raise SystemExit(run_publication_reply_loss())
