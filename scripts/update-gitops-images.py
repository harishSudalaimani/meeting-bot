#!/usr/bin/env python3
"""Replace only immutable ECR image references in the learning Helm values."""
import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: update-gitops-images.py <registry> <repository-prefix> <tag> <values-file>", file=sys.stderr)
        return 2
    registry, prefix, tag, values_name = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", tag):
        print("image tag contains unsupported characters", file=sys.stderr)
        return 2
    values_path = Path(values_name)
    text = values_path.read_text(encoding="utf-8")
    text, count = re.subn(r"(?m)^appVersion:\s+\S+$", f"appVersion: {tag}", text)
    if count != 1:
        raise SystemExit(f"expected one appVersion value in {values_path}, found {count}")
    images = {
        "api": "api",
        "controller": "controller",
        "meetingBot": "meeting-bot",
        "deliveryWorker": "delivery-worker",
    }
    for key, repository in images.items():
        pattern = rf"(?m)^(  {re.escape(key)}:)\s+\S+$"
        replacement = rf"\1 {registry}/{prefix}/{repository}:{tag}"
        text, count = re.subn(pattern, replacement, text)
        if count != 1:
            raise SystemExit(f"expected one images.{key} value in {values_path}, found {count}")
    values_path.write_text(text, encoding="utf-8")
    print(f"Updated app version and image tags in {values_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
