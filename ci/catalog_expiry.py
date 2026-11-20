"""Report committed release catalog freshness as GitHub Actions outputs."""
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


if __name__ == "__main__":
    path = Path(__file__).resolve().parents[1] / "manifests/first-party-releases.json"
    print(expiry_report(parse_catalog(path.read_text()), datetime.now(timezone.utc)))
