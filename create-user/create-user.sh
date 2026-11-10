#!/usr/bin/env bash
# Create a login user with an SSH key and passwordless sudo.
set -euo pipefail

PROG=$(basename "$0")
INSTALL_PATH=/usr/local/bin/create-user
ARGS=("$@")
NAME='' EMAIL='' KEY='' YES=0 DRY_RUN=0 INSTALL=0 SUDO=1

usage() {
  cat <<EOF
$PROG - create a user with SSH key login and passwordless sudo.

Creates the user (no password), adds the SSH public key to
~/.ssh/authorized_keys with correct permissions, and adds a
NOPASSWD sudoers drop-in in /etc/sudoers.d/<name>, verified with visudo.
If the user already exists you are asked to confirm before continuing;
re-running then grants sudo, or with --no-sudo revokes it.

Usage:
  $PROG [--no-sudo] [--dry-run]              interactive mode (asks for name, email, key)
  $PROG -name NAME -email EMAIL -key KEY [-y] [--no-sudo] [--dry-run]
  $PROG --install [--dry-run]
  $PROG --help

Parameters:
  -name NAME    Linux user name (lowercase letter first, then lowercase
                letters, digits, _ and -, max 32 chars)
  -email EMAIL  email address, used as the key comment
  -key KEY      ed25519 public key body (the base64 part), or a full public
                key line "TYPE BASE64 [comment]" of any type, used as-is
  -y            answer "yes" if the user already exists (needed when no
                terminal is attached, e.g. cron or CI)
  --no-sudo     no sudo access: removes /etc/sudoers.d/<name> and the
                sudo/admin/wheel group membership; warns if other sudoers
                rules still apply (group removal applies from next login)
  --dry-run     validate input and print the commands without running them
  --install     install this script as $INSTALL_PATH for all users
  -h, --help    show this help

-name, -email and -key must be given together; if none is given the
script runs in interactive mode. Runs itself via sudo when not root.

Examples:
  $PROG
  $PROG -name jdoe -email jdoe@example.com -key AAAAC3NzaC1lZDI1NTE5AAAA... -y
  sudo ./create-user.sh --install

Exit codes: 0 success, 1 invalid input or failed step.
EOF
}

die() { printf 'Error: %s\n\n' "$*" >&2; usage >&2; exit 1; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
run() { if ((DRY_RUN)); then printf '[dry-run]'; printf ' %q' "$@"; echo; else "$@"; fi; }

valid_name() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; }
valid_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
key_line() { if [[ $KEY == *' '* ]]; then printf '%s' "$KEY"; else printf 'ssh-ed25519 %s %s' "$KEY" "$EMAIL"; fi; }
valid_key() {
  local line type body
  line=$(key_line); read -r type body _ <<<"$line"
  [[ $line != *$'\n'* && $body =~ ^[A-Za-z0-9+/]+=*$ ]] || return 1
  # The blob embeds its own type. A mismatch means ssh-keygen only accepted the
  # line by reading the first word as sshd options, and sshd would ignore it.
  [[ $(base64 -d <<<"$body" 2>/dev/null | tail -c +5 | head -c ${#type}) == "$type" ]] || return 1
  ssh-keygen -l -f - <<<"$line" >/dev/null 2>&1
}

# --- parse arguments --------------------------------------------------------
while (($#)); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    -y) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-sudo) SUDO=0 ;;
    --install) INSTALL=1 ;;
    -name|-email|-key)
      [[ $# -ge 2 && -n $2 && $2 != -* ]] || die "$1 requires a value"
      case $1 in -name) NAME=$2 ;; -email) EMAIL=$2 ;; -key) KEY=$2 ;; esac
      shift ;;
    *) die "unknown parameter: $1" ;;
  esac
  shift
done

if ((EUID != 0 && !DRY_RUN)); then
  exec sudo -- "$(readlink -f "$0")" "${ARGS[@]}"
fi

if ((INSTALL)); then
  run install -m 755 "$(readlink -f "$0")" "$INSTALL_PATH"
  ((DRY_RUN)) || echo "Installed as $INSTALL_PATH"
  exit 0
fi

# --- collect and validate input ---------------------------------------------
ask() { read -r -p "$1" "$2" || fail 'no input'; }  # EOF would otherwise loop forever

if [[ -z $NAME$EMAIL$KEY ]]; then
  until ask 'User name: ' NAME && valid_name "$NAME"; do echo 'Invalid user name.'; done
  until ask 'User email: ' EMAIL && valid_email "$EMAIL"; do echo 'Invalid email.'; done
  until ask 'User SSH key: ' KEY && valid_key; do echo 'Invalid SSH public key.'; done
else
  [[ -n $NAME && -n $EMAIL && -n $KEY ]] || die '-name, -email and -key must all be given'
  valid_name "$NAME" || die "invalid user name: $NAME"
  valid_email "$EMAIL" || die "invalid email: $EMAIL"
  valid_key || die 'invalid SSH public key'
fi

LINE=$(key_line)
read -r _ BODY _ <<<"$LINE"
SUDOERS=/etc/sudoers.d/$NAME

# --- create -----------------------------------------------------------------
if id "$NAME" >/dev/null 2>&1; then
  if ((!YES)); then
    read -r -p "User '$NAME' already exists. Continue? [Y/n] " ans || fail "user '$NAME' exists and no answer was given (use -y)"
    [[ -z $ans || $ans =~ ^[Yy] ]] || { echo 'Aborted, nothing changed.'; exit 1; }
  fi
else
  run adduser --disabled-password --gecos "" "$NAME"
fi

HOME_DIR=$(getent passwd "$NAME" | cut -d: -f6) || true
HOME_DIR=${HOME_DIR:-/home/$NAME}  # dry run: user was not created
SSH_DIR=$HOME_DIR/.ssh
AUTH=$SSH_DIR/authorized_keys
# chmod and >> as root follow symlinks; refuse rather than touch their targets.
[[ -L $SSH_DIR || -L $AUTH ]] && fail "$SSH_DIR or $AUTH is a symlink, refusing to modify it"

run mkdir -p "$SSH_DIR"
# Append instead of overwrite so re-runs keep the user's other keys.
if ((DRY_RUN)); then
  printf '[dry-run] append to %s: %s\n' "$AUTH" "$LINE"
elif ! awk -v b="$BODY" '{for (i = 1; i <= NF; i++) if ($i == b) f = 1} END {exit !f}' "$AUTH" 2>/dev/null; then
  # without a final newline the key would be glued onto the previous line
  [[ -s $AUTH && -n $(tail -c1 "$AUTH") ]] && echo >>"$AUTH"
  printf '%s\n' "$LINE" >>"$AUTH"
fi
run chmod 700 "$SSH_DIR"
run chmod 600 "$AUTH"
run chown -R "$NAME:" "$SSH_DIR"  # "user:" = the user's login group, whatever its name

if ((!SUDO)); then
  run rm -f "$SUDOERS"
  for g in sudo admin wheel; do
    id -nG "$NAME" 2>/dev/null | grep -qw "$g" && run gpasswd -d "$NAME" "$g"
  done
  # Rules elsewhere (e.g. /etc/sudoers) are not ours to edit; report them instead.
  if ((!DRY_RUN)) && ! sudo -l -U "$NAME" 2>&1 | grep -q 'not allowed'; then
    echo "Warning: '$NAME' still has sudo rules elsewhere, see: sudo -l -U $NAME" >&2
  fi
  ((DRY_RUN)) || echo "Done: '$NAME' can log in with the given key (no sudo access)."
  exit 0
fi

# Check in a temp file first so a bad rule never goes live in /etc/sudoers.d.
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$NAME" >"$TMP"
visudo -c -f "$TMP" >/dev/null || fail 'sudoers check failed, nothing written'
run install -m 440 -o root -g root "$TMP" "$SUDOERS"
run visudo -c -f "$SUDOERS"

((DRY_RUN)) || echo "Done: '$NAME' can log in with the given key and use sudo without a password."
