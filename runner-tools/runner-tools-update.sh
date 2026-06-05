#!/usr/bin/env bash
# runner-tools-update.sh
#
# Install + update the host-level CI tooling declared in
# /etc/github-runner-tools.conf (source: scripts/runner-helpers/managed-tools.conf
# in the network-migration repo). One code path serves both roles:
#
#   * provision time — invoked once by scripts/10-ms-a2-runner-toolchain.sh
#     (and the Pi equivalent) to install the full managed set.
#   * weekly         — invoked by runner-tools-update.timer to pull every
#     managed tool up to its latest version, unattended.
#
# Deployed to /usr/local/sbin/runner-tools-update.sh and run as root (apt needs
# it). Self-contained on purpose: it has NO dependency on the repo's
# lib/common.sh, because it lives on the runner host on its own.
#
# Design notes:
#   * Upgrades are SCOPED to the managed set (an explicit `apt-get install` of
#     the listed names), never a system-wide dist-upgrade — a runner host should
#     not silently pull a new kernel/libc mid-week. Security patching of the rest
#     of the OS is a separate concern (unattended-upgrades), out of scope here.
#   * apt-repo tools get their upstream repo ensured (key in /etc/apt/keyrings,
#     list in /etc/apt/sources.list.d) before the install — see the repo registry.
#   * In-flight-job guard: before mutating anything we wait for runner jobs to
#     drain (no Runner.Worker process), then stop the actions.runner.* units so a
#     new job can't start mid-update, then restart them after. Under the ephemeral
#     posture (ADR-032) stopping a runner *between* jobs costs nothing; a job that
#     squeaks into the tiny post-drain window is killed and simply re-queues on
#     GitHub. --dry-run and provisioning (no enabled runner units yet) skip the
#     stop/start naturally.
#
# Usage:
#   runner-tools-update.sh [--dry-run] [--no-guard] [--config PATH]
#
# Exit codes: 0 ok (incl. "deferred, runners busy past max-wait"), 1 hard error.
set -euo pipefail

CONFIG="/etc/github-runner-tools.conf"
DRY_RUN=0
GUARD=1
# Max time to wait for an in-flight job to finish before giving up this run.
# The timer fires weekly, so a deferral just means "try again next week" — but
# a job rarely outlasts 30 min on these runners.
MAX_DRAIN_WAIT="${MAX_DRAIN_WAIT:-1800}"
DRAIN_POLL="${DRAIN_POLL:-15}"
STAMP_DIR="/var/lib/runner-tools"
# One temp root for all downloads/extractions, removed by the EXIT trap. We
# deliberately do NOT use per-function `trap ... RETURN` for these: a RETURN
# trap set inside a function persists and fires on every *later* function
# return too, dereferencing a now-out-of-scope local under `set -u`.
TMP_ROOT="$(mktemp -d)"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --no-guard)  GUARD=0 ;;
    --config)    CONFIG="${2:?--config needs a path}"; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

# ---------- logging (journal-friendly; no color, prefixed) -------------------
log()  { printf '[runner-tools] %s\n' "$*"; }
warn() { printf '[runner-tools] WARN: %s\n' "$*" >&2; }
die()  { printf '[runner-tools] ERR: %s\n'  "$*" >&2; exit 1; }
run()  { # echo + execute, or just echo under --dry-run
  if [ "$DRY_RUN" = 1 ]; then printf '[runner-tools] (dry-run) %s\n' "$*"; else "$@"; fi
}

[ "$(id -u)" = "0" ] || die "must run as root (apt + /etc writes)"
[ -f "$CONFIG" ]     || die "missing config: $CONFIG"

ARCH="$(dpkg --print-architecture)"   # amd64 | arm64
# shellcheck disable=SC1091
. /etc/os-release
CODENAME="${VERSION_CODENAME:-stable}"
log "host arch=${ARCH} codename=${CODENAME} config=${CONFIG} dry-run=${DRY_RUN}"

# ============================================================================
# Repo registry — the ONLY place upstream apt key/repo URLs live, so the trust
# surface is auditable in one spot. One `repo_<id>` function per apt-repo `spec`
# in the manifest. Each ensures its keyring + sources.list entry idempotently.
# ============================================================================
KEYRING_DIR="/etc/apt/keyrings"

# helper: fetch an armored/binary key and install it dearmored under keyrings/
ensure_key() { # ensure_key <url> <dest.gpg>
  local url="$1" dest="$2"
  [ -s "$dest" ] && return 0
  log "installing apt key: $dest"
  run install -d -m 0755 "$KEYRING_DIR"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp" || { rm -f "$tmp"; die "key fetch failed: $url"; }
  # dearmor handles armored keys; binary keys pass through gpg --dearmor too.
  gpg --dearmor < "$tmp" > "$dest" 2>/dev/null || cp "$tmp" "$dest"
  chmod 0644 "$dest"
  rm -f "$tmp"
}

ensure_list() { # ensure_list <sources.list.d/name.list> <content>
  local dest="$1" content="$2"
  if [ -f "$dest" ] && [ "$(cat "$dest")" = "$content" ]; then return 0; fi
  log "writing apt source: $dest"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  printf '%s\n' "$content" > "$dest"
  chmod 0644 "$dest"
}

# github-cli (gh): https://github.com/cli/cli/blob/trunk/docs/install_linux.md
repo_github-cli() {
  ensure_key "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
             "${KEYRING_DIR}/githubcli-archive-keyring.gpg"
  ensure_list "/etc/apt/sources.list.d/github-cli.list" \
    "deb [arch=${ARCH} signed-by=${KEYRING_DIR}/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"
}

# packagecloud-git-lfs — worked example for promoting git-lfs off the distro
# build. Not active by default (git-lfs is `apt` in the manifest); flip the
# manifest line to `apt-repo packagecloud-git-lfs` to use this.
repo_packagecloud-git-lfs() {
  ensure_key "https://packagecloud.io/github/git-lfs/gpgkey" \
             "${KEYRING_DIR}/git-lfs-archive-keyring.gpg"
  ensure_list "/etc/apt/sources.list.d/github_git-lfs.list" \
    "deb [signed-by=${KEYRING_DIR}/git-lfs-archive-keyring.gpg] https://packagecloud.io/github/git-lfs/ubuntu ${CODENAME} main"
}

ensure_repo() { # dispatch to repo_<id>; fail loudly on an unknown id
  local id="$1"
  if ! declare -F "repo_${id}" >/dev/null; then
    die "manifest references apt-repo '${id}' but no repo_${id} function exists in $0"
  fi
  "repo_${id}"
}

# ============================================================================
# Installer registry — tools with a bespoke OFFICIAL installer that is neither
# apt nor a GitHub-release asset. One `install_<id>` function per `installer`
# spec in the manifest. Like the repo registry, this keeps the download URLs in
# one auditable place. Each installs-or-updates to latest idempotently and logs
# a CHANGED line when the version moves.
# ============================================================================
install_aws-cli() { # AWS CLI v2 — AWS's official bundled installer (always latest v2)
  local archm before after work
  case "$ARCH" in
    amd64) archm="x86_64" ;;
    arm64) archm="aarch64" ;;
    *) warn "aws-cli: unsupported arch '$ARCH'; skipping"; return 0 ;;
  esac
  if command -v aws >/dev/null 2>&1; then before="$(aws --version 2>&1 | head -n1)"; else before="(absent)"; fi
  if [ "$DRY_RUN" = 1 ]; then
    log "installer aws-cli: would download+install latest v2 (current: ${before})"; return 0
  fi
  work="$(mktemp -d "${TMP_ROOT}/aws.XXXXXX")"
  # The awscli-exe zip is, by definition, the latest v2 — `--update` makes the
  # already-installed case a no-op refresh. unzip comes from the managed apt set
  # (installed before this runs).
  if ! curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${archm}.zip" -o "${work}/awscliv2.zip"; then
    warn "aws-cli: download failed; skipping"; return 0
  fi
  ( cd "$work" && unzip -q awscliv2.zip ) || { warn "aws-cli: unzip failed; skipping"; return 0; }
  "${work}/aws/install" --update >/dev/null 2>&1 \
    || "${work}/aws/install" >/dev/null 2>&1 \
    || { warn "aws-cli: install failed"; return 0; }
  after="$(aws --version 2>&1 | head -n1 || echo '(absent)')"
  if [ "$before" = "$after" ]; then log "installer aws-cli: already current (${after})"
  else log "  CHANGED aws-cli: ${before} -> ${after}"; fi
}

ensure_installer() { # dispatch to install_<id>; fail loudly on an unknown id
  local id="$1"
  if ! declare -F "install_${id}" >/dev/null; then
    die "manifest references installer '${id}' but no install_${id} function exists in $0"
  fi
  "install_${id}"
}

# ============================================================================
# Parse the manifest into three buckets.
# ============================================================================
APT_PKGS=()        # plain distro packages
APT_REPO_PKGS=()   # packages that also need a repo ensured
APT_REPO_IDS=()    # the repo ids to ensure (deduped below)
GH_LINES=()        # "name owner/repo asset"
INSTALLER_IDS=()   # bespoke-installer ids (e.g. aws-cli)

while read -r name source spec asset _rest; do
  case "$name" in ''|\#*) continue ;; esac   # skip blanks/comments
  case "$source" in
    apt)       APT_PKGS+=("$name") ;;
    apt-repo)  APT_REPO_PKGS+=("$name"); APT_REPO_IDS+=("$spec") ;;
    installer) INSTALLER_IDS+=("$spec") ;;
    github)    GH_LINES+=("$name $spec $asset") ;;
    *) warn "skipping '$name': unknown source '$source'" ;;
  esac
done < "$CONFIG"

# dedupe repo ids
if [ "${#APT_REPO_IDS[@]}" -gt 0 ]; then
  mapfile -t APT_REPO_IDS < <(printf '%s\n' "${APT_REPO_IDS[@]}" | sort -u)
fi

ALL_APT=("${APT_PKGS[@]}" "${APT_REPO_PKGS[@]}")
log "managed: ${#ALL_APT[@]} apt package(s), ${#INSTALLER_IDS[@]} installer(s), ${#GH_LINES[@]} github tool(s), ${#APT_REPO_IDS[@]} upstream repo(s)"

# ============================================================================
# In-flight-job guard: drain → stop runner units (captured for restart).
# ============================================================================
STOPPED_UNITS=()

runner_units() { # active/enabled actions.runner.*.service units, one per line
  systemctl list-unit-files 'actions.runner.*.service' --no-legend 2>/dev/null \
    | awk '$2=="enabled"||$2=="static"{print $1}'
}

drain_and_stop() {
  [ "$GUARD" = 1 ] || { log "guard disabled (--no-guard)"; return 0; }
  [ "$DRY_RUN" = 1 ] && { log "guard: dry-run, not stopping runners"; return 0; }

  local units; units="$(runner_units || true)"
  if [ -z "$units" ]; then
    log "guard: no runner units present (provision-time?); proceeding"
    return 0
  fi

  # Wait for any active job (Runner.Worker child) to finish.
  local waited=0
  while pgrep -f 'Runner\.Worker' >/dev/null 2>&1; do
    if [ "$waited" -ge "$MAX_DRAIN_WAIT" ]; then
      warn "a job is still running after ${MAX_DRAIN_WAIT}s; deferring this update to the next timer fire"
      exit 0
    fi
    log "guard: job in progress; waiting ${DRAIN_POLL}s (waited ${waited}s/${MAX_DRAIN_WAIT}s)"
    sleep "$DRAIN_POLL"
    waited=$((waited + DRAIN_POLL))
  done

  # Drained. Stop the runner units so no new job starts under our feet.
  log "guard: jobs drained; stopping runner units for the update window"
  local u
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    systemctl stop "$u" || warn "failed to stop $u"
    STOPPED_UNITS+=("$u")
  done <<< "$units"
}

restart_runners() {
  [ "${#STOPPED_UNITS[@]}" -gt 0 ] || return 0
  log "restarting ${#STOPPED_UNITS[@]} runner unit(s)"
  local u
  for u in "${STOPPED_UNITS[@]}"; do
    systemctl start "$u" || warn "failed to restart $u"
  done
}
# Always bring runners back + clean the temp root, even if the update aborts.
_cleanup() { rm -rf "${TMP_ROOT:-}" 2>/dev/null || true; restart_runners; }
trap _cleanup EXIT

# ============================================================================
# apt path — ensure repos, update, install/upgrade the managed set, summarize.
# ============================================================================
pkg_ver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo "(absent)"; }

apt_update_managed() {
  [ "${#ALL_APT[@]}" -gt 0 ] || return 0

  local id
  for id in "${APT_REPO_IDS[@]}"; do ensure_repo "$id"; done

  # Snapshot versions before, for the change summary.
  declare -gA BEFORE=()
  local p
  for p in "${ALL_APT[@]}"; do BEFORE[$p]="$(pkg_ver "$p")"; done

  log "apt-get update"
  run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  log "apt-get install (scoped to managed set): ${ALL_APT[*]}"
  run env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --no-install-recommends "${ALL_APT[@]}"

  # Summarize what moved.
  if [ "$DRY_RUN" = 1 ]; then
    log "apt summary: (dry-run; no changes applied)"
    for p in "${ALL_APT[@]}"; do log "  $p: ${BEFORE[$p]} (candidate via apt-cache policy)"; done
    return 0
  fi
  local changed=0
  for p in "${ALL_APT[@]}"; do
    local after; after="$(pkg_ver "$p")"
    if [ "${BEFORE[$p]}" != "$after" ]; then
      log "  CHANGED $p: ${BEFORE[$p]} -> ${after}"; changed=$((changed+1))
    fi
  done
  log "apt summary: ${changed} package(s) changed, $(( ${#ALL_APT[@]} - changed )) already current"
}

# ============================================================================
# github-release fallback — resolve latest tag, compare to stamp, install if new.
# ============================================================================
gh_latest_tag() { # gh_latest_tag <owner/repo>
  local repo="$1" url="https://api.github.com/repos/$1/releases/latest"
  local hdr=()
  [ -n "${GH_API_TOKEN:-}" ] && hdr=(-H "Authorization: Bearer ${GH_API_TOKEN}")
  curl -fsSL "${hdr[@]}" -H "Accept: application/vnd.github+json" "$url" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# Returns 0 (true) if a gzip tarball contains any UNSAFE member: a regular
# member with an absolute or `..` path, OR a sym/hardlink whose *target* is
# absolute or escapes via `..`. We extract as root, so a benign-named symlink
# pointing outside $work (e.g. `bin/x -> /etc`) followed by a write "through"
# it is the classic bypass of a name-only check — hence the link-target pass.
tar_has_unsafe_paths() {
  local f="$1"
  # Pass 1: member names.
  if tar tzf "$f" | grep -qE '(^/|(^|/)\.\.(/|$))'; then return 0; fi
  # Pass 2: symlink (l...) / hardlink (h...) targets, from the verbose listing
  # ("name -> target" for symlinks, "name link to target" for hardlinks).
  if tar tvzf "$f" 2>/dev/null | awk '
        $1 ~ /^[lh]/ {
          tgt=""
          n=index($0, " -> ");      if (n > 0) tgt = substr($0, n + 4)
          m=index($0, " link to "); if (m > 0) tgt = substr($0, m + 9)
          if (tgt ~ /^\// || tgt ~ /(^|\/)\.\.(\/|$)/) found = 1
        }
        END { exit(found ? 0 : 1) }
      '; then return 0; fi
  return 1
}

install_github_tool() { # install_github_tool <name> <owner/repo> <asset-template>
  local name="$1" repo="$2" tmpl="$3"
  local tag; tag="$(gh_latest_tag "$repo" || true)"
  [ -n "$tag" ] || { warn "github: could not resolve latest tag for $repo; skipping $name"; return 0; }

  local stamp="${STAMP_DIR}/${name}.tag"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$tag" ]; then
    log "github: $name already at $tag"; return 0
  fi
  log "github: $name -> $tag (was: $( [ -f "$stamp" ] && cat "$stamp" || echo none ))"
  [ "$DRY_RUN" = 1 ] && return 0

  local asset; asset="${tmpl//\{arch\}/$ARCH}"; asset="${asset//\{tag\}/$tag}"
  local url="https://github.com/${repo}/releases/download/${tag}/${asset}"
  local work; work="$(mktemp -d "${TMP_ROOT}/gh.XXXXXX")"
  curl -fsSL "$url" -o "${work}/${asset}" || { warn "github: download failed: $url"; return 0; }

  case "$asset" in
    *.deb)
      env DEBIAN_FRONTEND=noninteractive apt-get install -y "${work}/${asset}" ;;
    *.tar.gz|*.tgz)
      # Tar-slip guard: we extract as root, so vet the archive BEFORE extracting
      # (post-extraction validation is too late — the writes already landed).
      # Rejects unsafe member paths AND unsafe sym/hardlink targets that would
      # let a release asset escape $work into e.g. /usr/local/bin or /etc.
      if tar_has_unsafe_paths "${work}/${asset}"; then
        warn "github: $name archive has unsafe member paths or link targets; refusing to extract"
        return 0
      fi
      tar xzf "${work}/${asset}" -C "$work" --no-same-owner \
        || { warn "github: extraction failed for $name; skipping"; return 0; }
      local bin; bin="$(find "$work" -type f -name "$name" -perm -u+x | head -n1)"
      [ -n "$bin" ] || bin="$(find "$work" -type f -name "$name" | head -n1)"
      [ -n "$bin" ] || { warn "github: no '$name' binary inside $asset; skipping"; return 0; }
      install -m 0755 "$bin" "/usr/local/bin/${name}" ;;
    *)
      install -m 0755 "${work}/${asset}" "/usr/local/bin/${name}" ;;
  esac

  install -d -m 0755 "$STAMP_DIR"
  printf '%s\n' "$tag" > "$stamp"
  log "github: installed $name $tag"
}

github_update_all() {
  [ "${#GH_LINES[@]}" -gt 0 ] || return 0
  install -d -m 0755 "$STAMP_DIR" 2>/dev/null || true
  local line
  for line in "${GH_LINES[@]}"; do
    # shellcheck disable=SC2086
    set -- $line
    install_github_tool "$1" "$2" "$3"
  done
}

installer_update_all() {
  [ "${#INSTALLER_IDS[@]}" -gt 0 ] || return 0
  local id
  for id in "${INSTALLER_IDS[@]}"; do ensure_installer "$id"; done
}

# ============================================================================
# PATH verification — confirm the binaries the release/publish path depends on
# actually resolve. Install dirs (/usr/bin, /usr/local/bin) are on the runner
# user's systemd PATH drop-in, so root's `command -v` here is a faithful proxy.
# Non-fatal: a MISSING line flags a gap without aborting the (already-applied)
# update. Extend PROBE_BINS when a workflow surfaces a new must-have binary.
# ============================================================================
PROBE_BINS="gh minisign zip unzip jq python python3 aws tar"
verify_path() {
  local b miss=0
  log "PATH verification (binaries the release path needs):"
  for b in $PROBE_BINS; do
    if command -v "$b" >/dev/null 2>&1; then
      log "  ok      $b -> $(command -v "$b")"
    else
      warn "  MISSING $b (not on PATH)"; miss=$((miss+1))
    fi
  done
  [ "$miss" -eq 0 ] && log "all probed binaries present" || warn "${miss} probed binary/binaries MISSING"
}

# ============================================================================
# Run.
# ============================================================================
drain_and_stop
apt_update_managed     # installs unzip/zip/python-is-python3 first (installers depend on unzip)
installer_update_all   # aws-cli v2 etc.
github_update_all
verify_path
log "done."
