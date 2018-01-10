# VPN Shoot

The VPN Shoot is a tool that is used for [Shoot clusters](https://github.com/gardener/documentation/wiki/Architecture). It serves an endpoint for incoming connections, allows contacting any IP address within its network and routes the packets back to the caller (usually the [vpn-seed](../seed)). By that, it connects the components running in the Seed cluster with those running in the Shoot cluster.

## Constraints

The `vpn-shoot` requires a load balancer pointing to it which must be reachable from the Seed cluster network (usually a public load balancer).

## How to build it?

:warning: Please don't forget to update the `$VERSION` variable in the `Makefile` before creating a new release:

```bash
$ make release
```

This will create a new Docker image with the tag you specified in the `Makefile`, push it to our image registry, and clean up afterwards.

## Example manifests

Please find an example Kubernetes manifest within the [`/example`](example) directory.
