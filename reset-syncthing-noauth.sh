#!/usr/bin/env bash
set -euo pipefail

### SETTINGS (change if needed)
PI_USER="pi"
PI_HOME="/home/${PI_USER}"
ST_HOME="${PI_HOME}/.config/syncthing"
SHARE_DIR="${PI_HOME}/syncthing"
GUI_BIND="0.0.0.0:8384"                  # Web UI on all LAN interfaces
ST_TCP_PORT="22000"                      # Sync TCP/UDP
ST_UDP_PORT="22000"
ST_DISCOVERY_PORT="21027"                # Local discovery (UDP)
ST_APT_LIST="/etc/apt/sources.list.d/syncthing.list"
ST_APT_KEYRING="/usr/share/keyrings/syncthing-archive-keyring.gpg"
DROPIN_DIR="/etc/systemd/system/syncthing@${PI_USER}.service.d"
DROPIN_FILE="${DROPIN_DIR}/override.conf"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root (use sudo)."
    exit 1
  fi
}

check_env() {
  if ! id -u "${PI_USER}" >/dev/null 2>&1; then
    echo "User '${PI_USER}' not found. Create it or change PI_USER in the script."
    exit 1
  fi
  if [[ ! -d "${PI_HOME}" ]]; then
    echo "Home directory ${PI_HOME} not found."
    exit 1
  fi
  if ! grep -qiE "bookworm|trixie" /etc/os-release; then
    echo "Warning: This targets Raspberry Pi OS Bookworm (Debian 12) or Trixie (Debian 13). Continuing in 3s..."
    sleep 3
  fi
}

kill_everything() {
  echo "Stopping and disabling all Syncthing services (any user)..."
  systemctl stop "syncthing@${PI_USER}.service" >/dev/null 2>&1 || true
  systemctl disable "syncthing@${PI_USER}.service" >/dev/null 2>&1 || true
  systemctl stop syncthing.service >/dev/null 2>&1 || true
  systemctl disable syncthing.service >/dev/null 2>&1 || true

  # Stop any other syncthing@*.service instances that might be enabled
  mapfile -t other_units < <(systemctl list-units --all 'syncthing@*.service' --no-legend | awk '{print $1}')
  for u in "${other_units[@]:-}"; do
    [[ -n "$u" ]] || continue
    systemctl stop "$u" >/dev/null 2>&1 || true
    systemctl disable "$u" >/dev/null 2>&1 || true
  done

  echo "Killing any leftover syncthing processes (all users)..."
  pkill -f "/usr/bin/syncthing" >/dev/null 2>&1 || true
  sleep 1
  pkill -9 -f "/usr/bin/syncthing" >/dev/null 2>&1 || true
}

purge_previous() {
  echo "Purging Syncthing packages and APT repo..."
  apt-get update -y
  apt-get purge -y syncthing || true
  apt-get autoremove -y

  rm -f "${ST_APT_LIST}" || true
  rm -f "${ST_APT_KEYRING}" || true
  rm -f /usr/local/bin/syncthing || true

  echo "Removing prior configs & systemd overrides..."
  rm -rf "${ST_HOME}" || true
  rm -rf "/root/.config/syncthing" || true
  rm -rf /var/lib/syncthing || true

  rm -rf "${DROPIN_DIR}" || true
  rm -rf "/etc/systemd/system/syncthing@.service.d" || true
  systemctl daemon-reload

  echo "Cleaning old logs..."
  journalctl --rotate >/dev/null 2>&1 || true
  journalctl --vacuum-time=1s >/dev/null 2>&1 || true
}

install_latest() {
  echo "Adding official Syncthing APT repository..."
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://syncthing.net/release-key.gpg -o "${ST_APT_KEYRING}"
  chmod 0644 "${ST_APT_KEYRING}"

  cat > "${ST_APT_LIST}" <<EOF
deb [signed-by=${ST_APT_KEYRING}] https://apt.syncthing.net/ syncthing stable
EOF

  echo "Installing Syncthing..."
  apt-get update -y
  apt-get install -y syncthing curl ca-certificates
}

prepare_dirs() {
  echo "Preparing share and config directories..."
  mkdir -p "${SHARE_DIR}"
  chown -R "${PI_USER}:${PI_USER}" "${SHARE_DIR}"
  chmod 0755 "${SHARE_DIR}"

  install -d -m 0700 -o "${PI_USER}" -g "${PI_USER}" "${ST_HOME}"
}

generate_config() {
  echo "Generating fresh Syncthing config for ${PI_USER}..."
  # Generate keys & default config if missing
  sudo -u "${PI_USER}" syncthing -generate="${ST_HOME}" >/dev/null 2>&1 || true

  local CONFIG="${ST_HOME}/config.xml"
  if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: ${CONFIG} was not created."
    exit 1
  fi

  cp -a "${CONFIG}" "${CONFIG}.bak"

  # Force a fresh <gui> block that binds to all interfaces and has NO auth
  sed -i '/<gui[[:space:]>]/,/<\/gui>/d' "${CONFIG}"
  sed -i "/<\/configuration>/i \
  <gui enabled=\"true\" tls=\"false\" debugging=\"false\">\\
    <address>${GUI_BIND}</address>\\
  </gui>" "${CONFIG}"

  # Point the default folder to SHARE_DIR (create if missing)
  if grep -q 'folder id="default"' "${CONFIG}"; then
    sed -i -E "s#(<folder[^>]*id=\"default\"[^>]*path=\")[^\"]*(\"[^>]*>)#\1${SHARE_DIR}\2#g" "${CONFIG}"
  else
    sed -i -E "s#</configuration>#  <folder id=\"default\" label=\"Shared\" path=\"${SHARE_DIR}\" type=\"sendreceive\" rescanIntervalS=\"3600\">\\
    <filesystemType>basic</filesystemType>\\
  </folder>\\
</configuration>#g" "${CONFIG}"
  fi

  chown -R "${PI_USER}:${PI_USER}" "${ST_HOME}"
  chmod 0600 "${ST_HOME}/config.xml"
}

setup_systemd() {
  echo "Creating systemd drop-in (force bind + correct user + absolute home)..."
  mkdir -p "${DROPIN_DIR}"
  cat > "${DROPIN_FILE}" <<EOF
[Service]
User=${PI_USER}
Group=${PI_USER}
Environment=STGUIADDRESS=${GUI_BIND}
ExecStart=
ExecStart=/usr/bin/syncthing -no-browser -home=${PI_HOME}/.config/syncthing -gui-address=${GUI_BIND}
EOF

  echo "Enabling and starting syncthing@${PI_USER}.service..."
  systemctl daemon-reload
  systemctl enable "syncthing@${PI_USER}.service"
  systemctl restart "syncthing@${PI_USER}.service"

  echo "Waiting for Syncthing to start..."
  sleep 8
}

configure_firewall_if_present() {
  if command -v ufw >/dev/null 2>&1; then
    echo "ufw detected; opening Syncthing ports..."
    ufw allow 8384/tcp || true                     # Web GUI
    ufw allow "${ST_TCP_PORT}"/tcp || true         # Sync TCP
    ufw allow "${ST_UDP_PORT}"/udp || true         # Sync QUIC/UDP
    ufw allow "${ST_DISCOVERY_PORT}"/udp || true   # Local discovery
  else
    echo "ufw not installed; skipping firewall changes."
  fi
}

verify_and_summary() {
  echo
  echo "Verifying service and GUI bind..."
  systemctl --no-pager --full status "syncthing@${PI_USER}.service" || true
  echo
  ss -tulpn | grep -E '(:8384\s)|(:22000\s)' || true

  local DEVICE_ID IP_ADDRS
  DEVICE_ID="$(sudo -u "${PI_USER}" syncthing -home="${ST_HOME}" -device-id 2>/dev/null || true)"
  IP_ADDRS="$(hostname -I 2>/dev/null || echo "your-RPi-IP")"

  echo
  echo "======================================================================"
  echo "Fresh Syncthing install complete (GUI has NO password)!"
  echo
  echo "Web UI:            http://${IP_ADDRS%% *}:8384"
  echo "Auth:              NONE (set a password immediately in the GUI)"
  [[ -n "${DEVICE_ID}" ]] && echo "Device ID:         ${DEVICE_ID}"
  echo "Shared folder:     ${SHARE_DIR}"
  echo "Service:           syncthing@${PI_USER}.service (enabled & running)"
  echo
  echo "Ports:"
  echo " - 8384/tcp  (Web UI)"
  echo " - 22000/tcp (Sync TCP)"
  echo " - 22000/udp (Sync QUIC/UDP)"
  echo " - 21027/udp (Local discovery)"
  echo
  echo "SECURITY REMINDER: Your GUI is open on the LAN with NO password."
  echo "Right after first login, go to Actions → Settings → GUI and set a username/password."
  echo "======================================================================"
}

main() {
  require_root
  check_env
  kill_everything
  purge_previous
  install_latest
  prepare_dirs
  generate_config
  setup_systemd
  configure_firewall_if_present
  verify_and_summary
}

main "$@"
