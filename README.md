# Splunk Enterprise 10 — Ansible Single Instance

Ansible automation to install and configure **Splunk Enterprise 10** as a single standalone instance on Linux.

## Layout

```
.
├── ansible.cfg
├── inventory/
│   ├── production/hosts.yml
│   └── group_vars/
│       ├── splunk_servers.yml
│       └── splunk_vault.example.yml
├── playbooks/
│   ├── splunk_enterprise_single_instance.yml
│   └── splunk_enterprise_itsi_single_instance.yml
└── roles/
    ├── splunk_enterprise/
    └── splunk_itsi/
```

## Requirements

- Ansible 2.14+
- Target host: RHEL/CentOS/Rocky/Alma (RPM or tarball) or Debian/Ubuntu (DEB or tarball)
- Sudo access on the target host
- Outbound HTTPS to `download.splunk.com` (unless you provide a local package path)
- Minimum 8 GB RAM and 50 GB free disk (configurable)

## Quick start

1. Update inventory with your host details:

```yaml
# inventory/production/hosts.yml
splunk-01:
  ansible_host: 10.0.0.10
  ansible_user: ansible
```

2. Set the admin password (use Ansible Vault in production):

```bash
cp inventory/group_vars/splunk_vault.example.yml inventory/group_vars/splunk_vault.yml
ansible-vault encrypt inventory/group_vars/splunk_vault.yml
```

3. Run the playbook:

```bash
ansible-playbook playbooks/splunk_enterprise_single_instance.yml --ask-vault-pass
```

Or pass the password at runtime:

```bash
ansible-playbook playbooks/splunk_enterprise_single_instance.yml \
  --extra-vars 'splunk_admin_password=ChangeMe-Strong-Password-123!'
```

## Configuration

Key variables in `inventory/group_vars/splunk_servers.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `splunk_version` | `10.0.0` | Splunk Enterprise version |
| `splunk_build` | `e8eb0c4654f8` | Splunk build hash |
| `splunk_package_type` | `tgz` | `tgz`, `rpm`, or `deb` |
| `splunk_install_dir` | `/opt/splunk` | Installation directory |
| `splunk_user` | `splunk` | Service account |
| `splunk_web_port` | `8000` | Web UI port |
| `splunk_mgmt_port` | `8089` | Management API port |
| `splunk_configure_firewall` | `false` | Open ports in firewalld/ufw |

### Using a local package

To avoid downloading from Splunk on each run:

```yaml
splunk_package_path: "/tmp/splunk-10.0.0-e8eb0c4654f8-linux-amd64.tgz"
```

### Using a mirror URL

```yaml
splunk_package_url: "https://internal-mirror.example.com/splunk-10.0.0-e8eb0c4654f8-linux-amd64.tgz"
```

## What the role does

1. **Preflight** — OS/package validation, RAM and disk checks
2. **User** — Creates the `splunk` service account
3. **Install** — Downloads and installs Splunk (tarball, RPM, or DEB)
4. **Configure** — Seeds admin credentials via `user-seed.conf`, deploys `server.conf`, sets ulimits
5. **Service** — Starts Splunk, accepts license, enables systemd boot-start

Admin credentials are hashed with `splunk hash-passwd` before first start. Splunk removes `user-seed.conf` after seeding the local `passwd` file.

## Tags

Run specific stages:

```bash
ansible-playbook playbooks/splunk_enterprise_single_instance.yml --tags preflight
ansible-playbook playbooks/splunk_enterprise_single_instance.yml --tags install
ansible-playbook playbooks/splunk_enterprise_single_instance.yml --tags configure,service
```

## Post-install

- Web UI: `https://<host>:8000`
- Default admin user: value of `splunk_admin_username` (default `admin`)
- Apply a license in **Settings → Licensing** if you are not using the trial license

## Notes

- This playbook installs Splunk only when it is not already present. Upgrades require a separate process.
- RPM/DEB packages install to `/opt/splunk` only. Use `tgz` for custom install paths.
- Store `splunk_admin_password` in Ansible Vault; never commit plaintext secrets.

## Splunk ITSI (single instance)

Install Splunk Enterprise and **IT Service Intelligence (ITSI) 4.21** together:

1. Download `splunk-it-service-intelligence-4.21.0.spl` from [Splunkbase](https://splunkbase.splunk.com/) (requires Splunk.com login).
2. Copy the package to the target host or internal mirror and set in `inventory/group_vars/splunk_servers.yml`:

```yaml
itsi_package_path: "/tmp/splunk-it-service-intelligence-4.21.0.spl"
```

3. Run the combined playbook:

```bash
ansible-playbook playbooks/splunk_enterprise_itsi_single_instance.yml --ask-vault-pass
```

### ITSI role behavior

1. **Preflight** — Verifies Splunk is installed, checks RAM (12 GB+), CPU (16+ cores), 30 GB free under `$SPLUNK_HOME`, version compatibility, and conflicting apps
2. **Java** — Installs OpenJDK 17 and sets `JAVA_HOME` in `$SPLUNK_HOME/etc/splunk-launch.conf`
3. **Install** — Extracts the `.spl` package into `$SPLUNK_HOME/etc/apps` (Splunk-required method; does not use `splunk install app`)
4. **Configure** — Ensures app ownership and Java settings
5. **Service** — Restarts Splunk and waits for the management port

Complete first-time ITSI configuration (KV store migration, license, content packs) in Splunk Web after the playbook finishes.

Disable ITSI with `itsi_install_enabled: false` to run Splunk Enterprise only.

```bash
ansible-playbook playbooks/splunk_enterprise_itsi_single_instance.yml --tags splunk
ansible-playbook playbooks/splunk_enterprise_itsi_single_instance.yml --tags itsi
```
