# KVM Configuration for Kubernetes

> Represents a repository used to create a bridge network and virtual machines to be used to emulate on-premise
> infrastructure for Kubernetes deployments.

## Prerequisites

* Ubuntu 20.04
* GitHub account with SSH Keys
* Ethernet for bridge networking (Optional)

Other debian-based operating systems may work, but this has only been tested on Ubuntu 20.04 so far.

## Getting Started

### Create the Bridge Network (Optional)

A bridge network is required to expose the kubernetes cluster on the local network. This is done by creating a bridge
device that will slave all active ethernet connections. Without this, the VMs will only be available from the host and
cannot be accessed on the local network. To create the bridge network, run the following script to create the bridge
network:

```sh
./bridge.sh
```

> NOTE:
> THIS IS ONLY REQUIRED ONCE ON THE HOST

### Create the Virtual Machines

Run the following script to (re)create the virtual machines:

```sh
./kvm.sh --gh-user <YOUR_GITHUB_USERNAME>
```

There are many configuration options that can be used to manipulate the environments. For more information, run
the following:

```sh
./kvm.sh --help
```

## Naming Conventions

The following naming conventions are used:

* Master Nodes (kube-master-##)
* Worker Nodes (kube-worker-##)
* HAProxy Node (kube-proxy)

You can access the proxy stats via: http://kube-proxy:8404/stats

Copyright (c). Deavon McCaffery, Tiffany Wang, and Contributors. See [License](LICENSE) for details.
