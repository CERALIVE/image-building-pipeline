"""Report committed release catalog freshness as GitHub Actions outputs."""
import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Final

from pin_releases import Catalog, parse_catalog, unique_object
from pin_versions import PinError

WARNING_WINDOW: Final = timedelta(hours=48)
# Mirror the ordinary pin check's --max-age-hours default.
MAX_AGE: Final = timedelta(hours=168)
HOUR: Final = timedelta(hours=1)


def parse_warning_catalog(text: str) -> Catalog:
    """Validate with the gate's parser and add diagnostics only for this command."""
    try:
        return parse_catalog(text)
    except json.JSONDecodeError as error:
        raise PinError(f"invalid JSON: {error}") from error
    except (TypeError, ValueError) as error:
        data = json.loads(text, object_pairs_hook=unique_object)
        if isinstance(data, dict):
            timestamp = data.get("checked_at")
            if not isinstance(timestamp, str) or not timestamp:
                raise PinError("catalog checked_at must be a non-empty string") from error
            if not isinstance(error, PinError):
                try:
                    datetime.fromisoformat(timestamp)
                except ValueError as timestamp_error:
                    raise PinError("catalog checked_at is not an ISO 8601 timestamp") from timestamp_error
        raise


def expiry_report(catalog: Catalog, now: datetime) -> str:
    """Return workflow outputs using the supplied UTC clock."""
    age = now - catalog.checked_at
    if age < timedelta(0):
        raise PinError("release catalog checked_at is in the future")
    expires_at = catalog.checked_at.astimezone(timezone.utc) + MAX_AGE
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
        report = expiry_report(parse_warning_catalog(args.catalog.read_text(encoding="utf-8")), now)
    except (OSError, ValueError, TypeError, OverflowError) as error:
        detail = " ".join(str(error).splitlines())
        if isinstance(error, FileNotFoundError):
            detail = f"catalog file is missing: {detail}"
        elif isinstance(error, OSError):
            detail = f"catalog file is unreadable: {detail}"
        print(f"Cannot check release catalog: {detail}", file=sys.stderr)
        return 2
    print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
