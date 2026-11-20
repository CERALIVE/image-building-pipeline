"""Report committed release catalog freshness as GitHub Actions outputs."""
import argparse
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Final

from pin_releases import DEFAULT_MAX_AGE_HOURS, Catalog, parse_catalog
from pin_versions import PinError

WARNING_WINDOW: Final = timedelta(hours=48)
HOUR: Final = timedelta(hours=1)


def expiry_report(catalog: Catalog, now: datetime) -> str:
    """Return workflow outputs using the supplied UTC clock."""
    age = now - catalog.checked_at
    if age < timedelta(0):
        raise PinError("release catalog checked_at is in the future")
    expires_at = catalog.checked_at.astimezone(timezone.utc) + timedelta(hours=DEFAULT_MAX_AGE_HOURS)
    remaining = expires_at - now
    return "\n".join((
        f"age_hours={age / HOUR:.2f}",
        f"remaining_hours={remaining / HOUR:.2f}",
        f"expires_at={expires_at.isoformat()}",
        f"expired={str(remaining < timedelta(0)).lower()}",
        f"warn={str(remaining < WARNING_WINDOW).lower()}",
    ))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=Path(__file__).resolve().parents[1] / "manifests/first-party-releases.json")
    parser.add_argument("--now", type=datetime.fromisoformat, help="override the clock with an ISO 8601 timestamp")
    args = parser.parse_args()
    now = args.now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        parser.error("--now must include timezone")
    try:
        report = expiry_report(parse_catalog(args.catalog.read_text(encoding="utf-8")), now)
    except (OSError, ValueError, TypeError, OverflowError) as error:
        detail = " ".join(str(error).splitlines())
        print(f"Cannot check release catalog: {detail}", file=sys.stderr)
        return 2
    print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
