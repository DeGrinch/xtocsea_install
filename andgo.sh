#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# XTOCSEA — FULL INSTALLER + GIT / SYNC AUTOMATION
# filename: andgo.sh
#
# PURPOSE:
#   - Create system user: xtocsea
#   - Create required directory structure:
#         /home/xtocsea/install
#         /home/xtocsea/services/backup
#         /home/xtocsea/wifi_tools          (reserved; not used by sync)
#         /home/xtocsea/gitrepo             (bare repo parent)
#
#   - Initialize Git:
#         Working repo: /home/xtocsea
#         Bare repo:    /home/xtocsea/gitrepo/xtocsea.git
#
#   - SSH keys:
#         Single-key policy per repo. Name format:
#           ed25519_xtocsea_<owner>_<uuid>
#         If keys already exist in /home/xtocsea/.ssh, prompt to keep or replace.
#
#   - No clone/pull on install. Working repo starts with README.md only.
#
#   - Populate automation scripts:
#         /home/xtocsea/services/backup/xtocsea_local_sync.sh
#             rsync mirror /home/xtocsea → /home/xtocsea/gitrepo
#             strict exclusions, log rotation keep last 25
#
#         /home/xtocsea/services/backup/git_auto_push.sh
#             commit + push only if staged changes exist
#
#         /home/xtocsea/install/initialize_repo.sh
#             optional first-time pull from origin, safe-only (ff-only)
#
#         /home/xtocsea/install/establish_localrepo_sync_and_git_push_cron.sh
#             adds hourly cron combining sync + auto-push (only after init)
#
# RESULT AFTER INSTALL:
#   - User + dirs created
#   - SSH key created or reused
#   - Working + bare repos initialized
#   - Scripts written and executable
#   - You then run /home/xtocsea/install/initialize_repo.sh to pull when ready
#
# REQUIREMENTS:
#   - Run as root
#
# QUICK USE:
#   curl -L "https://raw.githubusercontent.com/<your-org>/xtocsea/main/andgo.sh" -o andgo.sh
#   chmod +x andgo.sh
#   sudo ./andgo.sh
###############################################################################

# ---------- Configurable defaults ----------
DEFAULT_REPO="https://github.com/DeGrinch/xtocsea"   # You can change this
SYSTEM_USER="xtocsea"
ROOT="/home/${SYSTEM_USER}"
SSH_DIR="${ROOT}/.ssh"
WORK_REPO="${ROOT}"
BARE_REPO_DIR="${ROOT}/gitrepo"
BARE_REPO="${BARE_REPO_DIR}/xtocsea.git"

SYNC_BIN="${ROOT}/services/backup/xtocsea_local_sync.sh"
GIT_PUSH_BIN="${ROOT}/services/backup/git_auto_push.sh"
INIT_BIN="${ROOT}/install/initialize_repo.sh"
CRON_SETUP_BIN="${ROOT}/install/establish_localrepo_sync_and_git_push_cron.sh"

log(){ printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }

# 1) Root check
[[ "$(id -u)" -eq 0 ]] || { echo "must run as root"; exit 1; }

# 2) Ensure system user + home
if ! id "$SYSTEM_USER" >/dev/null 2>&1; then
  log "Creating system user: ${SYSTEM_USER}"
  useradd --system --create-home --shell /bin/bash "$SYSTEM_USER"
fi

# 3) Ensure directory structure
mkdir -p "${ROOT}/install" "${ROOT}/wifi_tools" "${ROOT}/services/backup" "${BARE_REPO_DIR}" "${ROOT}/logs"
chown -R "$SYSTEM_USER":"$SYSTEM_USER" "$ROOT"

# 4) Collect repo URL and git identity for commits (avoid “Author identity unknown”)
read -rp "Repo URL (default ${DEFAULT_REPO}): " REPO_URL
REPO_URL="${REPO_URL:-$DEFAULT_REPO}"

read -rp "Git user.name to set locally (default: ${SYSTEM_USER}): " GIT_NAME
GIT_NAME="${GIT_NAME:-$SYSTEM_USER}"

read -rp "Git user.email to set locally (default: ${SYSTEM_USER}@localhost): " GIT_EMAIL
GIT_EMAIL="${GIT_EMAIL:-${SYSTEM_USER}@localhost}"

# Extract owner for key naming when URL is GitHub-style
REPO_OWNER="$(echo "$REPO_URL" | sed -E 's|.*github.com[:/]+([^/]+).*$|\1|')"

# 5) SSH key management with single-key policy
UUID="$(uuidgen)"
KEY_NAME="ed25519_${SYSTEM_USER}_${REPO_OWNER}_${UUID}"
KEY_PATH="${SSH_DIR}/${KEY_NAME}"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$SYSTEM_USER":"$SYSTEM_USER" "$SSH_DIR"

# Detect any existing keys
EXISTING_KEYS=$(find "$SSH_DIR" -maxdepth 1 -type f \( -name "*.pem" -o -name "id_*" -o -name "ed25519*" \) 2>/dev/null || true)

if [[ -n "${EXISTING_KEYS}" ]]; then
  echo
  echo "The SSH directory already contains key(s)."
  echo "Generating a new key will delete the old ones (revoking repo access)."
  echo "1. Keep current key(s) and proceed"
  echo "2. Delete all keys in ${SSH_DIR} and generate a new key"
  read -rp "Choose [1 or 2]: " ANSWER
  if [[ "$ANSWER" == "2" ]]; then
    log "Deleting existing SSH keys in ${SSH_DIR}"
    find "$SSH_DIR" -maxdepth 1 -type f \( -name "*.pem" -o -name "id_*" -o -name "ed25519*" \) -exec rm -f {} +
    USE_EXISTING_KEY=false
  else
    USE_EXISTING_KEY=true
  fi
else
  USE_EXISTING_KEY=false
fi

# Optional: allow copy of a provided private key path; else generate as xtocsea user
if [[ "$USE_EXISTING_KEY" != true ]]; then
  echo
  echo "Optional: provide path to an existing private key (ENTER to auto-generate):"
  read -rp "> " KEY_SRC
  if [[ -n "$KEY_SRC" && -f "$KEY_SRC" ]]; then
    cp "$KEY_SRC" "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    chown "$SYSTEM_USER":"$SYSTEM_USER" "$KEY_PATH"
  else
    sudo -u "$SYSTEM_USER" ssh-keygen -t ed25519 -C "$KEY_NAME" -f "$KEY_PATH" -N "" >/dev/null
  fi
fi

# Trust GitHub host key to avoid first-use prompts
ssh-keyscan -t rsa github.com >> "${SSH_DIR}/known_hosts" 2>/dev/null || true
chmod 644 "${SSH_DIR}/known_hosts"
chown "$SYSTEM_USER":"$SYSTEM_USER" "${SSH_DIR}/known_hosts"

# Show public key for adding to GitHub deploy keys
echo
echo "----- PUBLIC KEY — ADD TO YOUR GITHUB REPO (Deploy key with read/write) -----"
cat "${KEY_PATH}.pub" 2>/dev/null || true
echo "-----------------------------------------------------------------------------"
echo

# 6) Initialize bare repo (if missing)
if [[ ! -d "$BARE_REPO" ]]; then
  log "Initializing bare repository at ${BARE_REPO}"
  sudo -u "$SYSTEM_USER" git init --bare "$BARE_REPO" >/dev/null
fi

# 7) Initialize working repo (if missing) and set local git identity
if [[ ! -d "${WORK_REPO}/.git" ]]; then
  log "Initializing working repository at ${WORK_REPO}"
  sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" init >/dev/null
  sudo -u "$SYSTEM_USER" bash -c "cd '$WORK_REPO'; echo '# xtocsea repo' > README.md"
  sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" add README.md >/dev/null
  sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -m 'initial commit' >/dev/null
fi

# Also persist local identity settings to avoid future warnings
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" config user.name "$GIT_NAME"
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" config user.email "$GIT_EMAIL"

# 8) Convert HTTPS → SSH (git@github.com:owner/repo.git) when matched
if [[ "$REPO_URL" =~ ^https://github.com/(.+)/(.+)$ ]]; then
  REPO_URL="git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
fi

# 9) Configure remotes for working and bare repos
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote remove origin 2>/dev/null || true
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote remove localpush 2>/dev/null || true
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote add origin "$REPO_URL"
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote add localpush "$BARE_REPO"

sudo -u "$SYSTEM_USER" git -C "$BARE_REPO" remote remove upstream 2>/dev/null || true
sudo -u "$SYSTEM_USER" git -C "$BARE_REPO" remote add upstream "$REPO_URL"

###############################################################################
# WRITE: xtocsea_local_sync.sh  (STRICT EXCLUSIONS + LOG ROTATION)
###############################################################################
cat > "$SYNC_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------
# xtocsea_local_sync.sh
# Safely mirrors /home/xtocsea -> /home/xtocsea/gitrepo
# Excludes sensitive, system, cache, and non-versionable files.
# Rotates logs, keeps last 25 (older logs deleted).
# ---------------------------------------------------------------------

SOURCE="/home/xtocsea/"
TARGET="/home/xtocsea/gitrepo"
LOGDIR="/home/xtocsea/logs"
LOGFILE="$LOGDIR/sync_to_repo.log"
DATESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')

mkdir -p "$LOGDIR"

# Rotate current log (compress) and prune to last 25
cd "$LOGDIR" || exit 1
if [ -f "$LOGFILE" ]; then
  gzip -f "$LOGFILE"
fi
ls -1t sync_to_repo.log* 2>/dev/null | tail -n +26 | xargs -r rm -f

echo "[$DATESTAMP] Starting sync from $SOURCE to $TARGET" >> "$LOGFILE"

# Safety checks
if [ "$SOURCE" = "$TARGET" ]; then
  echo "ERROR: Source and target directories are identical. Aborting." | tee -a "$LOGFILE"
  exit 1
fi

if [ ! -d "$TARGET/.git" ]; then
  echo "ERROR: Target does not appear to be a Git repository. Aborting." | tee -a "$LOGFILE"
  exit 1
fi

# Perform rsync with exclusions (mirrors intent from prior AllWaysUp policy)
rsync -av --delete \
  --exclude='.env' \
  --exclude='tmp/' \
  --exclude='public_html/' \
  --exclude='homes/' \
  --exclude='cgi-bin/' \
  --exclude='.filemin/' \
  --exclude='.spamassassin/' \
  --exclude='.tmp/' \
  --exclude='awstats/' \
  --exclude='bin/' \
  --exclude='virtualmin-backup/' \
  --exclude='etc/' \
  --exclude='.awstats-htpasswd' \
  --exclude='.lesshst' \
  --exclude='guild_settings.db*' \
  --exclude='about_the_database.txt' \
  --exclude='.workspace_context.json' \
  --exclude='thegoatbot.db*' \
  --exclude='.git/' \
  --exclude='.github/' \
  --exclude='.gitignore' \
  --exclude='.mypy_cache/' \
  --exclude='__pycache__/' \
  --exclude='.cache/' \
  --exclude='.config/' \
  --exclude='.gnupg/' \
  --exclude='.local/' \
  --exclude='.npm/' \
  --exclude='.pm2/' \
  --exclude='.ssh/' \
  --exclude='.vscode-remote-containers/' \
  --exclude='.vscode-server/' \
  --exclude='.venv/' \
  --exclude='venv/' \
  --exclude='.bash_history' \
  --exclude='.bash_logout' \
  --exclude='.bashrc' \
  --exclude='.profile' \
  --exclude='.python_history' \
  --exclude='.selected_editor' \
  --exclude='.sudo_as_admin_successful' \
  --exclude='.wget-hsts' \
  --exclude='backups_src/' \
  --exclude='xtocsea_BACKUPS/' \
  --exclude='custom_packages/' \
  --exclude='data/' \
  --exclude='guild_member_logs/' \
  --exclude='logs/' \
  --exclude='sync_logs/' \
  --exclude='Maildir/' \
  --exclude='node_modules/' \
  --exclude='snap/' \
  --exclude='trash/' \
  --exclude='.trash/' \
  --exclude='.Trash/' \
  --exclude='*.log' \
  --exclude='*.sqlite*' \
  --exclude='*.bak' \
  --exclude='*.py_backup_*' \
  --exclude='*.token*' \
  --exclude='*.secret*' \
  --exclude='berconpy-client.tar.gz' \
  --exclude='cron.log' \
  --exclude='hourly_sync.log' \
  --exclude='package-lock.json' \
  --exclude='thegoatbot.log' \
  --exclude='assets/' \
  --exclude='ecosystem.config.js' \
  --exclude='lint_report.txt' \
  --exclude='mypy_report.txt' \
  --exclude='db_helper.py*' \
  --exclude='xtocsea/' \
  "$SOURCE" "$TARGET" >> "$LOGFILE" 2>&1

EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
  echo "[$DATESTAMP] Sync completed successfully." >> "$LOGFILE"
else
  echo "[$DATESTAMP] Sync failed with exit code $EXIT_CODE" >> "$LOGFILE"
fi

exit $EXIT_CODE
EOF

###############################################################################
# WRITE: git_auto_push.sh  (commit + push when staged diffs exist)
###############################################################################
cat > "$GIT_PUSH_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------
# git_auto_push.sh
# Automatically commits and pushes changes in /home/xtocsea
# Only if differences exist. Designed for cron use.
# ---------------------------------------------------------------------

REPO_DIR="/home/xtocsea"
LOGFILE="/home/xtocsea/logs/git_auto_push.log"
DATESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')

mkdir -p "$(dirname "$LOGFILE")"

cd "$REPO_DIR" || {
  echo "[$DATESTAMP] ERROR: Repo directory not found at $REPO_DIR" >> "$LOGFILE"
  exit 1
}

# Verify git repo
if [ ! -d ".git" ]; then
  echo "[$DATESTAMP] ERROR: No .git repository found in $REPO_DIR" >> "$LOGFILE"
  exit 1
fi

# Stage all tracked changes
git add -A

# Exit quietly if nothing to commit
if git diff --cached --quiet; then
  echo "[$DATESTAMP] No changes detected. Nothing to commit." >> "$LOGFILE"
  exit 0
fi

COMMIT_MSG="Automated backup: $DATESTAMP"
echo "[$DATESTAMP] Changes detected. Committing..." >> "$LOGFILE"
git commit -m "$COMMIT_MSG" >> "$LOGFILE" 2>&1

# Push all branches to origin to avoid branch-name assumptions
git push --all origin >> "$LOGFILE" 2>&1

EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
  echo "[$DATESTAMP] Push completed successfully." >> "$LOGFILE"
else
  echo "[$DATESTAMP] Push failed with exit code $EXIT_CODE." >> "$LOGFILE"
fi

exit $EXIT_CODE
EOF

###############################################################################
# WRITE: initialize_repo.sh  (first-time safe pull + cron establishment)
###############################################################################
cat > "$INIT_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------
# initialize_repo.sh
# If bare repo has no commits, offer to fetch+pull safely into working tree.
# Then establish cron for sync + auto-push.
# ---------------------------------------------------------------------

SYSTEM_USER="xtocsea"
ROOT="/home/${SYSTEM_USER}"
WORK="${ROOT}"
BARE="${ROOT}/gitrepo/xtocsea.git"
CRON_SETUP="${ROOT}/install/establish_localrepo_sync_and_git_push_cron.sh"

log(){ printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }

echo "Checking local bare repo for data..."

# If bare repo has no HEAD, consider it empty
if ! sudo -u "$SYSTEM_USER" git -C "$BARE" rev-parse --verify HEAD >/dev/null 2>&1; then
  echo
  echo "No repo data found in: $BARE"
  echo "Do you want to pull the GitHub repo into /home/xtocsea ?"
  echo "  1. Yes (pull into local working repo)"
  echo "  2. No  (cancel)"
  read -rp "Choose [1 or 2]: " ANSWER

  if [[ "$ANSWER" != "1" ]]; then
    echo "Canceled. No pull performed."
    exit 0
  fi

  echo
  echo "Fetching from 'upstream' and pulling into local working repo..."
  echo

  # Ensure working repo exists
  if [[ ! -d "${WORK}/.git" ]]; then
    echo "ERROR: ${WORK} does not appear to be a git repository."
    exit 1
  fi

  # Fetch remote history into bare repo (requires deploy key set on remote)
  if ! sudo -u "$SYSTEM_USER" git -C "$BARE" fetch upstream --all; then
    echo "Unable to reach GitHub or permission denied."
    echo "Ensure the PUBLIC KEY has been added to the repo as a deploy key with write access."
    exit 1
  fi

  # Pull into working tree, fast-forward only (safety: no overwrites)
  if ! sudo -u "$SYSTEM_USER" git -C "$WORK" pull --ff-only origin; then
    echo "ERROR: Pull cannot be performed safely (conflicts or overwrites detected)."
    exit 1
  fi

  echo "Repo successfully initialized in ${WORK}"
fi

# Establish cron after repo presence is confirmed or already present
"$CRON_SETUP"
echo "Cron established (hourly sync + push)."
exit 0
EOF

###############################################################################
# WRITE: establish_localrepo_sync_and_git_push_cron.sh  (hourly cron)
###############################################################################
cat > "$CRON_SETUP_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------
# establish_localrepo_sync_and_git_push_cron.sh
# Adds hourly cron to run: sync then auto-push, with low CPU/IO priority.
# Idempotent: adds only if missing.
# ---------------------------------------------------------------------

SYSTEM_USER="xtocsea"
CRON_LINE='0 * * * * nice -n 10 ionice -c2 -n7 /home/xtocsea/services/backup/xtocsea_local_sync.sh && nice -n 10 ionice -c2 -n7 /home/xtocsea/services/backup/git_auto_push.sh'

# If the exact line already exists, do nothing
if sudo -u "$SYSTEM_USER" crontab -l 2>/dev/null | grep -F "$CRON_LINE" >/dev/null 2>&1; then
  exit 0
fi

# Append line to user's crontab
( sudo -u "$SYSTEM_USER" crontab -l 2>/dev/null; echo "$CRON_LINE" ) | sudo -u "$SYSTEM_USER" crontab -
EOF

# 10) Permissions on scripts
chmod +x "$SYNC_BIN" "$GIT_PUSH_BIN" "$INIT_BIN" "$CRON_SETUP_BIN"
chown "$SYSTEM_USER":"$SYSTEM_USER" "$SYNC_BIN" "$GIT_PUSH_BIN" "$INIT_BIN" "$CRON_SETUP_BIN"

# 11) Final info + next step
echo
echo "========================================================="
echo " XTOCSEA INSTALL COMPLETE"
echo "========================================================="
echo "1) Add the PUBLIC SSH KEY printed above to your GitHub repo"
echo "   as a Deploy Key with write access."
echo
echo "2) When ready, initialize from remote:"
echo "      ${INIT_BIN}"
echo
echo "Scripts:"
echo "  Sync:       /home/xtocsea/services/backup/xtocsea_local_sync.sh"
echo "  Auto push:  /home/xtocsea/services/backup/git_auto_push.sh"
echo "  Cron setup: /home/xtocsea/install/establish_localrepo_sync_and_git_push_cron.sh"
echo "========================================================="
