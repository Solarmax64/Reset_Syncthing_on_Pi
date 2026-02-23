# Reset Syncthing

A production-ready Bash script that completely resets and reinstalls [Syncthing](https://syncthing.net/) on Debian-based Linux systems. Originally built for Raspberry Pi, it works on any system running Raspberry Pi OS, Debian 11+, or Ubuntu 22.04+.

## What It Does

1. **Stops** all running Syncthing services and processes
2. **Purges** existing Syncthing packages, configs, logs, and systemd overrides
3. **Installs** the latest Syncthing from the official APT repository
4. **Configures** a fresh instance with a shared folder, systemd service, and optional firewall rules
5. **Optionally** sets up GUI authentication during install

## Quick Start

```bash
# Download and run (interactive, prompts before each step)
sudo ./reset-syncthing.sh

# Non-interactive full reset
sudo ./reset-syncthing.sh --yes

# Preview what would happen without making changes
sudo ./reset-syncthing.sh --dry-run

# With GUI authentication
sudo ./reset-syncthing.sh --gui-user admin --gui-password mypassword
```

## Supported Platforms

| Platform | Versions |
|----------|----------|
| Raspberry Pi OS | Bullseye, Bookworm, Trixie |
| Debian | 11 (Bullseye), 12 (Bookworm), 13 (Trixie) |
| Ubuntu | 22.04 (Jammy), 24.04 (Noble), and later |

Other Debian derivatives are detected automatically and will work with a warning.

## Usage

```
Usage: sudo reset-syncthing.sh [OPTIONS]

Options:
  -h, --help              Show help and exit
  -V, --version           Show version and exit
  -n, --dry-run           Show what would happen without making changes
  -y, --yes               Skip all confirmations (non-interactive)
  -v, --verbose           Show detailed output
  -q, --quiet             Suppress non-error output (log file still written)
  --no-color              Disable colored output

Configuration:
  -c, --config PATH       Use config file at PATH
  --init-config           Create default config at /etc/reset-syncthing/config.conf
  -u, --user USER         Target user (default: auto-detect)
  --share-dir DIR         Syncthing shared folder path
  --gui-bind ADDR         GUI bind address (default: 0.0.0.0:8384)

Authentication:
  --gui-user NAME         Set GUI username (enables authentication)
  --gui-password PASS     Set GUI password (requires --gui-user)

Step control:
  --skip-purge            Skip package purge step
  --skip-install          Skip APT install step
  --skip-firewall         Skip firewall configuration

Logging:
  -l, --log-file PATH     Log to PATH (default: /var/log/reset-syncthing.log)
  --no-log                Disable file logging
```

## Persistent Configuration

Create a config file to persist your preferred settings across runs:

```bash
# Automatic (copies the example template)
sudo ./reset-syncthing.sh --init-config

# Manual
sudo mkdir -p /etc/reset-syncthing
sudo cp config.conf.example /etc/reset-syncthing/config.conf
sudo chmod 0600 /etc/reset-syncthing/config.conf
sudo nano /etc/reset-syncthing/config.conf
```

Settings precedence (highest wins):
1. **CLI arguments** (e.g., `--user myuser`)
2. **Config file** (`/etc/reset-syncthing/config.conf`)
3. **Built-in defaults**

See [config.conf.example](config.conf.example) for all available settings with documentation.

## Interactive Mode

By default, the script prompts before each major step:

```
==> Stop all Syncthing services
Proceed with: Stop all Syncthing services? [y/N/s(kip)]
```

- **y** - Proceed with this step
- **n** - Abort the entire script
- **s** - Skip this step and continue to the next

Use `--yes` to skip all prompts for automated/scripted use.

## Security

**By default, the Syncthing Web GUI has no authentication** and is bound to all network interfaces (`0.0.0.0:8384`). This means anyone on your network can access it.

To secure the GUI during installation:

```bash
sudo ./reset-syncthing.sh --gui-user admin --gui-password yourpassword
```

Or set `GUI_USER` and `GUI_PASSWORD` in the config file (note: password is stored in plaintext in the config file - ensure proper file permissions).

If you skip authentication during setup, set a password immediately via the Web UI: **Actions -> Settings -> GUI**.

To restrict GUI access to localhost only:

```bash
sudo ./reset-syncthing.sh --gui-bind 127.0.0.1:8384
```

## Logging

All output is logged to `/var/log/reset-syncthing.log` by default. Override with `--log-file PATH` or disable with `--no-log`. Logs rotate automatically when the file exceeds 1MB.

## Troubleshooting

**Service won't start:**
```bash
sudo systemctl status syncthing@<user>.service
sudo journalctl -u syncthing@<user>.service --no-pager -n 50
```

**Port already in use:**
```bash
ss -tulpn | grep -E ':(8384|22000|21027)\s'
```

**Re-run without purging (keeps packages, just reconfigures):**
```bash
sudo ./reset-syncthing.sh --skip-purge
```

**Check the config file that was generated:**
```bash
cat ~/.config/syncthing/config.xml
```

**Restore a backed-up config** (backups are saved to `/tmp/syncthing-backup-*` before purge):
```bash
ls /tmp/syncthing-backup-*
cp /tmp/syncthing-backup-<timestamp>/config.xml ~/.config/syncthing/config.xml
sudo systemctl restart syncthing@<user>.service
```

## License

[MIT](LICENSE)
