# VPN

This repository contains components to establish network connectivity for Shoot clusters.

## What's inside

[VPN Seed](seed) - a component that establishes connectivity from a pod running in the Seed cluster to the networks of a Shoot cluster (which are usually private).

[VPN Shoot](shoot) - a component that serves an endpoint for incoming connections, allows contacting any IP address within its network and routes the packets back to the caller.

# How to build / release

## Local build

Use `docker build` in either sub directory

## Central ci build

PRs are automatically built with our CI system (concourse) and
deployed to our image registry to a `ci/<component-name>` path and tagged with
the head commit id.

## Release build

To release a new image version:

- ensure the proper version is entered in either `shoot/VERSION` or `seed/VERSION`
  - version format _must_ comply to [semver](https://semver.org) format
  - suffixes are removed (e.g. 1.0.0-MS1 becomes `1.0.0`)
  - with the exception of suffix removal, the version from `<component>/VERSION`
    will be used as a release tag
- run the component-specific release job at concourse
