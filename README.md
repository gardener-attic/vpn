# VPN

This repository contains components to establish network connectivity for Shoot clusters.

## What's inside

[VPN Seed](seed) - a component that establishes connectivity from a pod running in the Seed cluster to the networks of a Shoot cluster (which are usually private).

[VPN Shoot](shoot) - a component that serves an endpoint for incoming connections, allows contacting any IP address within its network and routes the packets back to the caller.

## Local build

```bash
$ make docker-images
```
