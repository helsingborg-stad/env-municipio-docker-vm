# Replicated files

## Goal

Keep uploads and requested cache directories available locally on every data VM without a central file server.

## Standalone solution

The installer creates these directories on the VM's existing filesystem:

```text
/srv/municipio/data/uploads
/srv/municipio/data/cache
```

Docker bind-mounts them into the container. “Mount” here does not mean an external storage service.

## Cluster solution

Each VM stores a Gluster brick under `/srv/municipio/gluster-brick`. The replicated volume is mounted locally at `/srv/municipio/data`; Docker sees the same bind-mount paths as in standalone mode.

With two bricks and no arbitrator, automatic writable failover cannot be made safe in both directions. The first brick is preferred and promotion of the other side is manual. With an optional third Gluster arbiter, the third host stores metadata but not file contents and can provide safe quorum.

The initial version intentionally uses a replicated filesystem instead of bidirectional rsync. Lsyncd/rsync is asynchronous and cannot safely resolve simultaneous updates or partitions.

## Cache behavior

Cache directories are replicated because it is an explicit platform requirement. During rolling application updates, nodes with different image versions must not write incompatible cache entries concurrently. The update workflow drains nodes and clears the shared cache only after every node runs the same version. This behavior needs load testing with the selected Municipio release.

