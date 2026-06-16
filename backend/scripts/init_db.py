from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.app.database import DB_PATH, init_db
from backend.app.detection import ensure_sample_source
from backend.app.scanner import ensure_placeholders


def main() -> None:
    init_db()
    ensure_placeholders()
    ensure_sample_source()
    print(f"Initialized database: {DB_PATH}")


if __name__ == "__main__":
    main()

