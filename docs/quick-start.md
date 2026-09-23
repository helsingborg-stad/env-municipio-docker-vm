# Quick start

On a fresh Ubuntu Server 24.04 LTS amd64 VM, run:

```bash
curl -fL https://raw.githubusercontent.com/helsingborg-stad/env-municipio-docker-vm/main/installer.sh -o installer.sh
sudo sh installer.sh
```

The wizard runs on the VM and asks a few questions. For a single server, press Enter to keep **standalone** and **Compose**. Enter the VM address, public site hostname, WordPress administrator email, and passwords (or let the wizard generate passwords). Confirm the summary to install.

When it finishes, the application, local MariaDB, Caddy, and health timer are started and enabled for reboot. Open the site hostname in a browser. Check the server with:

```bash
sudo /scripts/status.municipio.sh
```

The generated settings are at `/etc/municipio/municipio.env`, readable only by root. If you let the wizard generate passwords, retrieve and store them securely from that file; the installer does not print them. To update the container image later, use `/scripts/update.municipio.sh` with an exact image digest.

The download URL will work once the repository's `main` branch is publicly published. If you prefer a branded URL such as `https://install.getmunicipio.com`, serve the repository's `installer.sh` over HTTPS at that address. The bootstrap script downloads the source bundle from the GitHub `main` branch by default; for releases, publish a versioned archive and update its source URL before advertising the installer. Do not advertise a domain until it actually serves the reviewed script.

For a two-VM cluster, select `cluster-manual` or `cluster-arbitrator` and answer the additional peer questions on each VM. The first install prepares services but cannot start a cluster alone. Once peers are ready, the wizard can bootstrap or join a node; Swarm workers also need a join token and a manager-side `enable-node` command. Follow the [cluster runbook](runbook.md) for the safe order. Swarm is an optional runtime choice in the same wizard.
