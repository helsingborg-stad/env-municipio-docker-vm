# Quick start

On a fresh Ubuntu Server 22.04/24.04/26.04 LTS or Debian 12/13 amd64 VM, run:

```bash
curl -fL https://raw.githubusercontent.com/helsingborg-stad/env-municipio-docker-vm/main/installer.sh -o installer.sh
sudo sh installer.sh
```

The wizard runs on the VM, shows numbered choices, and suggests an answer in `[brackets]` that Enter accepts. For a single server it asks:

1. **How many servers?** Press Enter for *this server only*.
2. **The website:** its web address (a pasted `https://…/` is trimmed to the hostname), who takes care of the HTTPS certificate (press Enter to let this server do it), and the WordPress administrator's email.
3. **Passwords:** the WordPress login password, or Enter to create one. The database passwords are always generated.

Finally it asks whether to change advanced settings (Enter for *no*), shows a summary, and installs. The server name and address are detected automatically. Under advanced settings you can choose Docker Swarm, the administrator user name, the database name and user, and type your own database passwords.

When it finishes, the application, MariaDB and Caddy containers and the health timer are started and enabled for reboot. Nothing but Docker was installed as a package. Open the site hostname in a browser. Check the server with:

```bash
sudo /scripts/status.municipio.sh
```

If setup stops after saving the configuration, run `sudo sh installer.sh` again and choose **yes** to resume. A missing Docker socket usually means the Engine service did not start; check `sudo systemctl status docker.service` and `sudo journalctl -u docker.service` if the retry cannot start it.

The generated settings are at `/etc/municipio/municipio.env`, readable only by root. Generated passwords are not printed. If the WordPress password was generated, the wizard ends by showing the `sudo grep WP_ADMIN_PASSWORD …` command that reveals it. Values are written single-quoted, because the file is read both by bash and by Docker Compose's dotenv parser — keep that form if you edit it. To update the application image later, use `/scripts/update.municipio.sh` with an exact image digest; the MariaDB and Caddy images have their own deliberate procedure in the [runbook](runbook.md).

The download URL will work once the repository's `main` branch is publicly published. If you prefer a branded URL such as `https://install.getmunicipio.com`, serve the repository's `installer.sh` over HTTPS at that address. The bootstrap script downloads the source bundle from the GitHub `main` branch by default; for releases, publish a versioned archive and update its source URL before advertising the installer. Do not advertise a domain until it actually serves the reviewed script.

To remove the installation and return the VM to its original state, download and run the uninstaller the same way. It deletes the database, uploads and backups, and removes Docker Engine; see [Uninstalling](../README.md#uninstalling).

```bash
curl -fL https://raw.githubusercontent.com/helsingborg-stad/env-municipio-docker-vm/main/uninstaller.sh -o uninstaller.sh
sudo sh uninstaller.sh
```

For a two-VM cluster, choose *two servers* (`cluster-manual`) or *two servers plus a tie-breaker* (`cluster-arbitrator`) in step 1, then say which server this is and give the name and internal IP address of each server. On both website servers, type the same **cluster password** (at least 16 characters) and the same WordPress password. The database passwords are derived from the cluster password, so both data VMs end up with identical ones in whatever order they are installed. They must match because a Galera state transfer replicates the privilege tables. The first install prepares services but cannot start a cluster alone. Once peers are ready, the wizard can bootstrap or join a node; Swarm workers also need a join token and a manager-side `enable-node` command. Follow the [cluster runbook](runbook.md) for the safe order, including `cluster.municipio.sh clear-bootstrap-flag` once the peer has joined. Swarm is available under the wizard's advanced settings.
