#!/usr/bin/env bash
set -euo pipefail

# Debian 13: XFCE + xRDP + Google Authenticator (PAM TOTP)
# Reversible: backs up any modified file + stores state in /var/lib/xfce-xrdp-2fa/state.env

APP_ID="xfce-xrdp-2fa"
STATE_DIR="/var/lib/${APP_ID}"
BACKUP_DIR="${STATE_DIR}/backups"
STATE_FILE="${STATE_DIR}/state.env"

XRDP_STARTWM="/etc/xrdp/startwm.sh"
XRDP_PAM="/etc/pam.d/xrdp-sesman"

PACKAGES=(xfce4 xfce4-goodies xrdp libpam-google-authenticator)

usage() {
  cat <<'EOF'
Usage:
  sudo ./xfce-xrdp-2fa.sh install --user <username>
  sudo ./xfce-xrdp-2fa.sh undo [--purge-packages]

What it does (install):
  - Installs XFCE + xrdp + libpam-google-authenticator
  - Configures xrdp to start XFCE
  - Enables TOTP for RDP logins via /etc/pam.d/xrdp-sesman (with nullok)
  - Adds xrdp to ssl-cert group
  - Creates/backs up the target user's ~/.xsession -> startxfce4

What you still do manually:
  - For each user who should use 2FA, run:
      google-authenticator
    (or run it as that user with: sudo -u <user> google-authenticator)

Notes:
  - 'nullok' means users without ~/.google_authenticator can still log in.
    Remove nullok later if you want to enforce 2FA for all RDP users.
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root (use sudo)." >&2
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "${STATE_DIR}" "${BACKUP_DIR}"
  chmod 700 "${STATE_DIR}" "${BACKUP_DIR}"
}

timestamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

backup_file() {
  local f="$1"
  if [[ -f "${f}" ]]; then
    local ts
    ts="$(timestamp)"
    local dest="${BACKUP_DIR}${f}.${ts}"
    mkdir -p "$(dirname "${dest}")"
    cp -a "${f}" "${dest}"
    echo "Backed up ${f} -> ${dest}"
  fi
}

write_state() {
  # Overwrite state file with current values
  cat > "${STATE_FILE}" <<EOF
APP_ID="${APP_ID}"
BACKUP_DIR="${BACKUP_DIR}"
XRDP_STARTWM="${XRDP_STARTWM}"
XRDP_PAM="${XRDP_PAM}"
PACKAGES="${PACKAGES[*]}"
TARGET_USER="${TARGET_USER:-}"
TARGET_HOME="${TARGET_HOME:-}"
CREATED_XSESSION="${CREATED_XSESSION:-0}"
EOF
  chmod 600 "${STATE_FILE}"
  echo "Wrote state: ${STATE_FILE}"
}

load_state() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    echo "ERROR: No state file found at ${STATE_FILE}. Nothing to undo." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
}

install_mode() {
  local user=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        user="${2:-}"; shift 2;;
      -h|--help)
        usage; exit 0;;
      *)
        echo "Unknown argument: $1" >&2
        usage; exit 1;;
    esac
  done

  if [[ -z "${user}" ]]; then
    echo "ERROR: --user is required" >&2
    usage
    exit 1
  fi

  if ! id "${user}" >/dev/null 2>&1; then
    echo "ERROR: user '${user}' does not exist." >&2
    exit 1
  fi

  TARGET_USER="${user}"
  TARGET_HOME="$(getent passwd "${TARGET_USER}" | awk -F: '{print $6}')"

  ensure_dirs

  echo "==> Installing packages: ${PACKAGES[*]}"
  apt-get update
  apt-get install -y "${PACKAGES[@]}"

  echo "==> Enable and start xrdp"
  systemctl enable xrdp
  systemctl restart xrdp || true

  echo "==> Add xrdp to ssl-cert group (helps with cert/key access)"
  adduser xrdp ssl-cert >/dev/null || true

  echo "==> Configure xrdp to start XFCE (reversible)"
  backup_file "${XRDP_STARTWM}"
  cat > "${XRDP_STARTWM}" <<'EOF'
#!/bin/sh
# Managed by xfce-xrdp-2fa (reversible via undo)
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
EOF
  chmod 755 "${XRDP_STARTWM}"

  echo "==> Configure PAM for xrdp-sesman to use Google Authenticator (reversible)"
  if [[ ! -f "${XRDP_PAM}" ]]; then
    echo "ERROR: Expected ${XRDP_PAM} to exist after installing xrdp." >&2
    exit 1
  fi

  backup_file "${XRDP_PAM}"

  # Insert the google-authenticator line before the first "@include common-auth" if not already present.
  # Use 'nullok' so users without ~/.google_authenticator won't be locked out.
  if grep -qE 'pam_google_authenticator\.so' "${XRDP_PAM}"; then
    echo "PAM already references pam_google_authenticator.so; leaving as-is."
  else
    awk '
      BEGIN { inserted=0 }
      /^[[:space:]]*@include[[:space:]]+common-auth/ && inserted==0 {
        print "auth required pam_google_authenticator.so nullok"
        inserted=1
      }
      { print }
      END {
        if (inserted==0) {
          # If common-auth include not found, append at top for safety
          # (but after possible header)
          # NOTE: We cannot easily insert after header with pure awk; handled by caller.
        }
      }
    ' "${XRDP_PAM}" > "${XRDP_PAM}.tmp"

    # If insertion didn't happen, prepend line at beginning (after header if present).
    if ! grep -qE '^auth required pam_google_authenticator\.so' "${XRDP_PAM}.tmp"; then
      {
        # Keep possible PAM header line as first line
        head -n 1 "${XRDP_PAM}"
        echo "auth required pam_google_authenticator.so nullok"
        tail -n +2 "${XRDP_PAM}"
      } > "${XRDP_PAM}.tmp"
    fi

    mv "${XRDP_PAM}.tmp" "${XRDP_PAM}"
    chmod 644 "${XRDP_PAM}"
    echo "Inserted: auth required pam_google_authenticator.so nullok"
  fi

  echo "==> Configure user session to start XFCE under xrdp"
  CREATED_XSESSION=0
  if [[ -n "${TARGET_HOME}" && -d "${TARGET_HOME}" ]]; then
    local xsession="${TARGET_HOME}/.xsession"
    if [[ -f "${xsession}" ]]; then
      backup_file "${xsession}"
    else
      CREATED_XSESSION=1
    fi
    echo "startxfce4" > "${xsession}"
    chown "${TARGET_USER}:${TARGET_USER}" "${xsession}"
    chmod 700 "${xsession}"
    echo "Wrote ${xsession}"
  else
    echo "WARN: Could not determine home dir for ${TARGET_USER}; skipping ~/.xsession" >&2
  fi

  echo "==> Restart xrdp services"
  systemctl restart xrdp
  systemctl restart xrdp-sesman || true

  write_state

  cat <<EOF

DONE.

Next steps (manual, per-user):
  1) As ${TARGET_USER}, run:
       google-authenticator
     (Or: sudo -u ${TARGET_USER} google-authenticator)

  2) Test RDP login. Depending on your RDP client, you may get:
     - Password prompt then a TOTP prompt
     - OR a single prompt where you enter: passwordTOTP (no separator)

Rollback any time:
  sudo ./xfce-xrdp-2fa.sh undo
EOF
}

restore_latest_backup_for() {
  local f="$1"
  # Find newest backup matching this file
  local pattern="${BACKUP_DIR}${f}."
  local latest
  latest="$(ls -1 "${pattern}"* 2>/dev/null | sort | tail -n 1 || true)"
  if [[ -z "${latest}" ]]; then
    echo "No backup found for ${f}; skipping restore."
    return 0
  fi
  cp -a "${latest}" "${f}"
  echo "Restored ${f} from ${latest}"
}

undo_mode() {
  local purge_packages=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge-packages)
        purge_packages=1; shift;;
      -h|--help)
        usage; exit 0;;
      *)
        echo "Unknown argument: $1" >&2
        usage; exit 1;;
    esac
  done

  require_root
  load_state

  echo "==> Restoring configuration files from backups (if present)"
  restore_latest_backup_for "${XRDP_STARTWM}"
  restore_latest_backup_for "${XRDP_PAM}"

  if [[ -n "${TARGET_HOME:-}" && -n "${TARGET_USER:-}" && -d "${TARGET_HOME}" ]]; then
    local xsession="${TARGET_HOME}/.xsession"
    # If we created it, remove it; if it existed, restore from backup if available.
    if [[ "${CREATED_XSESSION:-0}" == "1" ]]; then
      if [[ -f "${xsession}" ]]; then
        rm -f "${xsession}"
        echo "Removed ${xsession} (it was created by script)"
      fi
    else
      # Restore if we backed it up
      restore_latest_backup_for "${xsession}"
      chown "${TARGET_USER}:${TARGET_USER}" "${xsession}" 2>/dev/null || true
    fi
  fi

  echo "==> Restarting xrdp services (if still installed)"
  systemctl restart xrdp 2>/dev/null || true
  systemctl restart xrdp-sesman 2>/dev/null || true

  if [[ "${purge_packages}" == "1" ]]; then
    echo "==> Purging packages: ${PACKAGES}"
    # shellcheck disable=SC2086
    apt-get purge -y ${PACKAGES} || true
    apt-get autoremove -y || true
  fi

  echo "==> Leaving backups and state directory in place:"
  echo "    ${STATE_DIR}"
  echo "    (You can remove it manually if you want.)"

  echo "UNDO complete."
}

main() {
  require_root

  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"; shift
  case "${cmd}" in
    install) install_mode "$@";;
    undo) undo_mode "$@";;
    -h|--help) usage;;
    *) echo "Unknown command: ${cmd}" >&2; usage; exit 1;;
  esac
}

main "$@"
