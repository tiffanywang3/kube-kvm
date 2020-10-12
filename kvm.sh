#! /usr/bin/env bash

set -e

MASTER_NODE_COUNT=1
WORKER_NODE_COUNT=1

CENTOS_VERSION=7
CPU_LIMIT=2
MEMORY_LIMIT=4096

GH_USER=tiffanywang3

__kvm_help() {
    echo
    echo "KVM Configuration for Kubernetes"
    echo
    echo "Usage: ./kvm.sh [OPTIONS]"
    echo
    echo "Options:"
    echo
    echo -e "--masters\tDEFAULT: 1, the number of master nodes to create"
    echo -e "--workers\tDEFAULT: 1, the number of worker nodes to create"
    echo -e "--os-version\tDEFAULT: 7, the version of CentOS to use"
    echo -e "--cpu\t\tDEFAULT: 2, the number of CPUs for each node"
    echo -e "--memory\tDEFAULT: 4096, the amount of memory to allocate for each node"
    echo -e "--gh-user\tDEFAULT: tiffanywang3, the github username used to retrieve SSH keys"
    echo
    echo "Example:"
    echo
    echo "./kvm.sh --masters 3 --workers 3 --cpu 4 --memory 8192 --gh-user somebody"
}

while [[ $# > 0 ]]; do
    case $1 in
        --masters)
            MASTER_NODE_COUNT=$2
            shift
            ;;
        --workers)
            WORKER_NODE_COUNT=$2
            shift
            ;;
        --os-version)
            CENTOS_VERSION=$2
            shift
            ;;
        --cpu)
            CPU_LIMIT=$2
            shift
            ;;
        --memory)
            MEMORY_LIMIT=$2
            shift
            ;;
        --gh-user)
            GH_USER=$2
            shift
            ;;
        --help)
            __kvm_help
            exit 0
            ;;
        *)
            echo "unknown option: $1"
            echo
            __kvm_help
            exit 1
            ;;
    esac
    shift
done

OS_VARIANT="centos${CENTOS_VERSION}.0"
BASE_IMAGE=CentOS-${CENTOS_VERSION}-x86_64-GenericCloud.qcow2

if [ ! -f $BASE_IMAGE ]; then
  echo "Downloading $BASE_IMAGE...."
  wget http://cloud.centos.org/centos/7/images/$BASE_IMAGE -O $BASE_IMAGE
fi

VM_NETWORKS=""

# setup networks
for network in $(sudo virsh net-list | grep active |  tr -s ' ' | cut -d ' ' -f 2); do
    VM_NETWORKS="${VM_NETWORKS} --network network:${network}"
done

# install all prerequisites
sudo apt update
sudo apt-get install qemu-kvm libvirt-daemon-system \
   libvirt-clients libnss-libvirt virtinst

# make sure libvirtd is enabled
sudo systemctl enable libvirtd

# add user to libvirt group
sudo usermod -a -G libvirt ${USER}

# delete existing nodes
for node in $(sudo virsh list --all --name | grep "kube-"); do
  sudo virsh shutdown $node
  sudo virsh destroy $node
  sudo virsh undefine $node

  rm -f $node.qcow2
  rm -f $node-init.img
  rm -f $node-metadata
done

# ensure base image is accessible
sudo chmod u=rw,go=r $BASE_IMAGE

# create cloud-init config
sed "s/GH_USER/${GH_USER}/g" cloud_init.cfg.template > cloud_init.cfg

# create the haproxy config
cat haproxy.cfg.template > haproxy.cfg

# create a virtual machine
create_vm() {
    hostname=$1
    snapshot=$hostname.qcow2
    init=$hostname-init.img

    # create snapshot and increase size to 30GB
    qemu-img create -b $BASE_IMAGE -f qcow2 -F qcow2 $snapshot 30G
    qemu-img info $snapshot

    # insert metadata into init image
    echo "instance-id: $(uuidgen || echo i-abcdefg)" > $hostname-metadata
    echo "local-hostname: $hostname.local" >> $hostname-metadata

    cloud-localds -v --network-config=network.cfg $init cloud_init.cfg $hostname-metadata

    # ensure file permissions belong to kvm group
    sudo chmod ug=rw,o= $snapshot
    sudo chown $USER:kvm $snapshot $init

    # create the vm
    sudo virt-install --name $hostname \
        --virt-type kvm --memory ${MEMORY_LIMIT} --vcpus ${CPU_LIMIT} \
        --boot hd,menu=on \
        --disk path=$init,device=cdrom \
        --disk path=$snapshot,device=disk \
        --graphics vnc \
        --os-type Linux --os-variant ${OS_VARIANT} \
        ${VM_NETWORKS} \
        --autostart \
        --noautoconsole

    # set the timeout
    sudo virsh guest-agent-timeout $hostname --timeout 60
}

# iterate over each node
for (( i=1; i<=$MASTER_NODE_COUNT; i++ )); do
  # create the vm for the node
  create_vm kube-master-$(printf "%02d" $i)
done

# iterate over each node
for (( i=1; i<=$WORKER_NODE_COUNT; i++ )); do
  # create the vm for the node
  create_vm kube-worker-$(printf "%02d" $i)
done

# wait for nodes to come up
sleep 60

# iterate over each node
for (( i=1; i<=$MASTER_NODE_COUNT; i++ )); do
  # get the name of the master
  name=kube-master-$(printf "%02d" $i)
  ip=$(sudo virsh domifaddr --domain ${name} --source agent | grep -w eth1 | egrep -o '([[:digit:]]{1,3}\.){3}[[:digit:]]{1,3}')

  # add the ip to the haproxy config
  echo "    server $name $ip:6443 check" >> haproxy.cfg
done

# modify the cloud_init to include the haproxy.cfg
cat << EOF >> cloud_init.cfg
  - systemctl enable haproxy.service
  - systemctl start haproxy.service

write_files:
  - path: /etc/haproxy/haproxy.cfg
    encoding: base64
    content: $(cat haproxy.cfg | base64 -w 0)
EOF

# create the ha proxy node
create_vm kube-proxy

# print out the private ips and HAProxy stats
echo
echo PRIVATE IPs
sudo virsh net-dhcp-leases --network default
echo
echo HAProxy Stats: http://kube-proxy:8404/stats
