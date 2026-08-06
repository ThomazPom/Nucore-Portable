#!/bin/bash
# Prime one existing user's distro-configured default services without logging
# that user into a desktop. Called as root before the xorg-only cabinet starts.

set -e

SESSION_USER=${1:-}
[ -n "$SESSION_USER" ] || { echo "nucore-user-session: missing user" >&2; exit 2; }
SESSION_UID=$(id -u "$SESSION_USER") || exit 2
[ "$SESSION_UID" -ge 1000 ] || {
    echo "nucore-user-session: refusing system user '$SESSION_USER' (uid $SESSION_UID)" >&2
    exit 2
}

# user@UID creates /run/user/UID and the user's systemd manager. Starting its
# default.target lets the distribution select the normal enabled services. On
# current Debian/Kali that includes PipeWire/WirePlumber; older or future
# systems remain free to supply a different audio stack. This is not an
# autologin and does not activate graphical-session.target.
systemctl start "user@${SESSION_UID}.service"
systemctl --user --machine="${SESSION_USER}@" start default.target

echo "[nucore-user-session] default user services ready for $SESSION_USER" >&2
