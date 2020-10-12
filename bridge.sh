#! /usr/bin/env bash
set -eu

# install all prerequisites
sudo apt update
sudo apt-get install qemu-kvm libvirt-daemon-system \
   libvirt-clients libnss-libvirt virtinst

# make sure libvirtd is enabled
sudo systemctl enable libvirtd

# get a list of active ethernet devices (deal with whitespace)
OLDIFS=$IFS
IFS=$'\n'
ACTIVE_CONNECTIONS=( $(nmcli -get-values NAME,DEVICE,TYPE connection show --active | grep ethernet | grep -v bridge | cut -d ':' -f 1,2) )
IFS=$OLDIFS

if [ -z "${ACTIVE_CONNECTIONS:-}" ]; then
    echo
    echo "no active connections to bridge..."
    exit 1
fi

# delete and recreate the bridge
sudo nmcli connection delete br0 || true
sudo nmcli con add ifname br0 type bridge con-name br0 || true
sudo nmcli con modify br0 bridge.stp no

# disable netfilter for the bridge network to avoid issues with docker network configs
sudo cat << EOF > /etc/sysctl.d/bridge.conf
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-arptables = 0
EOF

# activate the netfilter configuration for the bridge device
sudo cat << EOF > /etc/udev/rules.d/99-bridge.rules
ACTION=="add", SUBSYSTEM=="module", KERNEL=="br_netfilter", RUN+="/sbin/sysctl -p /etc/sysctl.d/bridge.conf"
EOF

# update network configuration
sudo netplan apply

# iterate over each device
for connection in "${ACTIVE_CONNECTIONS[@]}"; do

    # get the name
    name=${connection%%\:*}
    device=${connection##*\:}

    # remove the existing bridge slave if it exists
    sudo nmcli con delete bridge-slave-$device || true

    # add the device to the bridge
    sudo nmcli con add type bridge-slave ifname $device master br0

    # take down the connection
    sudo nmcli con down "$name"
done

# bring up the bridge
sudo nmcli con up br0

# show the connections
nmcli con show --active

# create and start the bridge
sudo virsh net-define bridge.xml || true
sudo virsh net-start bridge || true
sudo virsh net-autostart bridge || true
