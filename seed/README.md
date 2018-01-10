# VPN Seed

The VPN Seed is a tool that is used for [Shoot clusters](https://github.com/gardener/documentation/wiki/Architecture). It establishes connectivity from a pod running in the Seed cluster to the networks of a Shoot cluster (which are usually private). This is possible as all containers inside a pod share the same network namespace. However, the vpn-seed container requires an public endpoint on the Shoot side (usually the [vpn-shoot](../shoot)) to which it can connect. It will identify the endpoint itself automatically and reconnect whenever the connection gets lost.

## Constraints

The `vpn-seed` container must reside in the same pod for which it should establish connection to the Shoot networks.

## How to build it?

:warning: Please don't forget to update the `$VERSION` variable in the `Makefile` before creating a new release:

```bash
$ make release
```

This will create a new Docker image with the tag you specified in the `Makefile`, push it to our image registry, and clean up afterwards.

## Example manifests

Please find an example Kubernetes manifest within the [`/example`](example) directory.
