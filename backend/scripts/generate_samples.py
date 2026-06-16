from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.app.sample_data import generate_samples


def main() -> None:
    force = "--force" in sys.argv
    created = generate_samples(force=force)
    print(f"Sample directory is ready. Created or refreshed {len(created)} files.")


if __name__ == "__main__":
    main()
