# Release checklist

## Build
1. Update `VERSION` and add a `## x.y.z (date)` entry to `CHANGELOG.md`.
2. `scripts/build-dmg.sh`: builds a universal binary, ad-hoc signs it, runs the release self-test (240+ checks, including the packaged CLI) and makes the designed `.dmg` plus `SHA256SUMS.txt`. It stops on any failure.
3. Optional: publish by pushing tag `vX.Y.Z` (`.github/workflows/release.yml` checks the tag against `VERSION`, builds, and attaches the `.dmg` and checksums with the changelog entry as notes).

## Clean-machine matrix (by hand, per release)
Use a fresh macOS user account or a VM (UTM), with a **downloaded** copy of the `.dmg` so it's quarantined.

| Check | macOS 13 (Intel or Apple silicon) | macOS 14 | macOS 15+ |
|---|---|---|---|
| `.dmg` opens to the designed window: arrow, app, Applications, READ ME visible | ☐ | ☐ | ☐ |
| First open is blocked; approval works as the READ ME says (Control-click › Open on 13–14; Privacy & Security › Open Anyway on 15+) | ☐ | ☐ | ☐ |
| Menu bar lamp appears; the setup guide opens once | ☐ | ☐ | ☐ |
| Allow Alerts → macOS prompt → "On"; a sample request shows a banner with Allow / Deny | ☐ | ☐ | ☐ |
| Open at login survives a reboot | ☐ | ☐ | ☐ |
| Connect Claude Code → a new `claude` session appears; a permission request is answerable from the popup | ☐ | ☐ | ☐ |
| Install the agentbar command → new terminal → `agentbar status` works | ☐ | ☐ | ☐ |
| Upgrade: install the new `.dmg` over the old app. Alerts and login item still on? (ad-hoc builds may need re-approval) | ☐ | ☐ | ☐ |
| Sleep 10+ min, wake: stuck agents updated, agents can still report | ☐ | ☐ | ☐ |
| Light / dark / Increase Contrast / Reduce Motion look right | ☐ | ☐ | ☐ |

## Checked automatically on the build Mac
- Gatekeeper on a quarantined copy: **rejected**, as expected for a non-notarized app (`spctl -a -t exec`). The READ ME covers approval.
- `codesign --verify --strict`, universal `lipo` check, `hdiutil verify`, minimum macOS 13.
