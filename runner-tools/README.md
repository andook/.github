# runner-tools — canonical CI runner tooling manifest

**Single source of truth** for the host-level tooling pre-installed on the
`andook` org's self-hosted CI runners. Re-homed here on 2026-06-05 from the
`network-migration` repo (see that repo's `docs/15-ms-r1-arc-arm64-runners.md`
§6) so that **both** consumers read one copy and never drift:

- **Bare-metal runners** (MS-A2 x64, Pi arm64): `network-migration`'s
  `scripts/lib/runner-tools-deploy.sh` fetches these two files from this repo at
  provision time and installs them on the host as `/etc/github-runner-tools.conf`
  + `/usr/local/sbin/runner-tools-update.sh`, plus a weekly refresh timer.
- **ARC runner image** (MS-R1 arm64, this repo's `runner-image/Containerfile`):
  COPYs `managed-tools.conf` + `runner-tools-update.sh` and runs the updater at
  build time, so the image's apt/installer layer matches the bare-metal hosts.

## Files

| File | Role |
|---|---|
| `managed-tools.conf` | The declarative tool inventory. **This is the single edit point.** |
| `runner-tools-update.sh` | Installer/updater that consumes the manifest. Self-contained, runs as root. `--no-guard` skips the systemd runner-drain (used by the image build, which has no runner units). |

## Editing

Add/remove a line in `managed-tools.conf`, open a PR. On merge to `main`,
`.github/workflows/build-arm64-runner.yml` rebuilds + pushes the ARC image.
Bare-metal hosts pick the change up on their next weekly
`runner-tools-update.timer` fire (or an explicit re-provision).

Column format and `source` types (`apt` / `apt-repo` / `installer` / `github`)
are documented in the header of `managed-tools.conf` itself.
