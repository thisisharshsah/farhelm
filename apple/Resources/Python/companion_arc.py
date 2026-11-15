# Companion: lets apwlib use Arc, a Chromium browser that runs Apple's
# iCloud Passwords extension (apwlib lists Chrome, Chromium, Brave and
# Edge). Loaded at start by companion_arc.pth; Arc comes after the others.
import sys

try:
    if sys.platform == "darwin":
        from pathlib import Path

        import chauffeur.browsers as _browsers

        _arc = _browsers.BrowserInfo(
            "arc",
            "Arc",
            Path("/Applications/Arc.app/Contents/MacOS/Arc"),
            Path.home() / "Library/Application Support/Arc/User Data",
        )
        _catalog = _browsers.catalog

        def catalog():
            found = tuple(_catalog())
            return found if any(b.id == "arc" for b in found) else found + (_arc,)

        _browsers.catalog = catalog

        import apwlib._browsers as _apw

        _apw.BREW_CASKS.setdefault("arc", "arc")
        _apw.BROWSERS[:] = [_apw.BrowserInfo(id=b.id, name=b.name, binary=b.binary) for b in catalog()]
except Exception:
    pass
