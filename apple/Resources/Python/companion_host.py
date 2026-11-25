# Companion: lets apwlib host Apple's iCloud Passwords extension in the
# Chromium inside Companion.app (its path in COMPANION_PASSWORDS_HOST), after
# any Chrome, Chromium, Brave or Edge installed on the Mac, which are tried
# first. Never Arc: it opens its own windows instead of running hidden.
# Loaded at start by companion_host.pth, in the bridge and in the daemon it
# starts (which inherits the variable).
import os
import sys

try:
    _host = os.environ.get("COMPANION_PASSWORDS_HOST", "")
    if sys.platform == "darwin":
        from pathlib import Path

        import chauffeur.browsers as _browsers

        _inside = None
        if _host and Path(_host).exists():
            _inside = _browsers.BrowserInfo(
                "companion-chromium",
                "Chromium in Companion",
                Path(_host),
                Path.home() / "Library/Application Support/Companion/passwords-host",
            )
        _catalog = _browsers.catalog

        def catalog():
            found = tuple(b for b in _catalog() if b.id != "arc")
            if _inside is None or any(b.id == _inside.id for b in found):
                return found
            return found + (_inside,)

        _browsers.catalog = catalog

        import apwlib._browsers as _apw

        _apw.BREW_CASKS.setdefault("companion-chromium", "ungoogled-chromium")
        _apw.BROWSERS[:] = [_apw.BrowserInfo(id=b.id, name=b.name, binary=b.binary) for b in catalog()]
except Exception:
    pass
