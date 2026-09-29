# Replicated files

## Goal

Keep uploads, requested cache directories, and Caddy certificate storage available locally on every data VM without a central file server.

## Standalone solution

The installer creates `/srv/municipio/data/uploads`, `/srv/municipio/data/cache`, and `/srv/municipio/data/caddy` on the VM's existing filesystem. Caddy mounts the last directory at `/data` for certificates and ACME state.

Docker bind-mounts them into the container. “Mount” here does not mean an external storage service.

## Cluster solution

Each VM stores a Gluster brick under `/srv/municipio/gluster-brick`. The replicated volume is mounted locally at `/srv/municipio/data`; Docker sees the same bind-mount paths as in standalone mode. `DATA_ROOT/caddy` is therefore shared by the Caddy containers on both data VMs. Caddy is started only after Gluster is mounted read/write; it never binds the hidden local directory beneath an absent mount.

With two bricks and no arbitrator, automatic writable failover cannot be made safe in both directions. The first brick is preferred and promotion of the other side is manual. With an optional third Gluster arbiter, the third host stores metadata but not file contents and can provide safe quorum.

The initial version intentionally uses a replicated filesystem instead of bidirectional rsync. Lsyncd/rsync is asynchronous and cannot safely resolve simultaneous updates or partitions.

## GlusterFS remains a host component

GlusterFS is a kernel/FUSE storage layer rather than an application service. A containerized `glusterd` needs a privileged container with shared mount propagation to place a mount in the host's namespace, and the health check, `/etc/fstab` and the `DATA_ROOT` mount are all host-level facts. Running it on the host keeps the storage layer where the kernel already is.

## Never place the database here

`DB_DATA_ROOT` must not sit inside `DATA_ROOT` or `GLUSTER_BRICK`. A MariaDB data directory on replicated storage corrupts silently. `validate_config` rejects this configuration, and `tests/check.sh` covers both variants.

## Cache behavior

Cache directories are replicated because it is an explicit platform requirement. During rolling application updates, nodes with different image versions must not write incompatible cache entries concurrently. The update workflow drains nodes and clears the shared cache only after every node runs the same version. This behavior needs load testing with the selected Municipio release.
