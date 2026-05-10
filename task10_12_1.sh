#!/bin/bash

######################################## PREPARE #######################################
source $(dirname $0)/config
mkdir -p networks /var/lib/libvirt/images/$VM1_NAME /var/lib/libvirt/images/$VM2_NAME config-drives/$VM1_NAME-config config-drives/$VM2_NAME-config
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "$VM1_MANAGEMENT_IP $VM1_NAME
$VM2_MANAGEMENT_IP $VM2_NAME" >> /etc/hosts
VM1_MAC=52:54:00:`(date; cat /proc/interrupts) | md5sum | sed -r 's/^(.{6}).*$/\1/; s/([0-9a-f]{2})/\1:/g; s/:$//;'`
VIRT_TYPE=$(egrep -c '(vmx|svm)' /proc/cpuinfo)
if (( $VIRT_TYPE > 0 )); then VIRT_TYPE="kvm"; else VIRT_TYPE="qemu"; fi

####################################### CLOUD INIT #########################################
mkdir -p $(dirname $SSH_PUB_KEY)
yes "y" | ssh-keygen -t rsa -N "" -f $(echo $SSH_PUB_KEY | rev | cut -c5- | rev)

###### vm1 user-data ######
cat << EOF > config-drives/$VM1_NAME-config/user-data
#cloud-config
ssh_authorized_keys:
  - $(cat  $SSH_PUB_KEY)
apt_update: true
apt_sources:
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - software-properties-common
  - iptables-persistent
runcmd:
  - echo 1 > /proc/sys/net/ipv4/ip_forward
  - iptables -A FORWARD -i $VM1_INTERNAL_IF -o $VM1_EXTERNAL_IF -j ACCEPT
  - iptables -A FORWARD -i $VM1_EXTERNAL_IF -o $VM1_INTERNAL_IF -m state --state ESTABLISHED,RELATED -j ACCEPT
  - iptables -t nat -A POSTROUTING -o $VM1_EXTERNAL_IF -j MASQUERADE
  - iptables-save > /etc/iptables/rules.v4
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  - add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable"
  - apt update
  - apt install docker-ce docker-compose -y
  - ip link add $VXLAN_IF type vxlan id $VID remote $VM2_INTERNAL_IP local $VM1_INTERNAL_IP dstport 4789
  - ip link set vxlan0 up
  - ip addr add $VM1_VXLAN_IP/24 dev vxlan0
EOF

###### vm2 user-data ######
cat << EOF > config-drives/$VM2_NAME-config/user-data
#cloud-config
ssh_authorized_keys: 
  - $(cat  $SSH_PUB_KEY)
apt_update: true
apt_sources:
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - software-properties-common 
runcmd:
  - ip link add $VXLAN_IF type vxlan id $VID remote $VM1_INTERNAL_IP local $VM2_INTERNAL_IP dstport 4789
  - ip link set vxlan0 up
  - ip addr add $VM2_VXLAN_IP/24 dev vxlan0
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  - add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  - apt update
  - apt install docker-ce docker-compose -y
EOF

###### vm1 meta-data ######
echo "hostname: $VM1_NAME
local-hostname: $VM1_NAME
network-interfaces: |
  auto $VM1_EXTERNAL_IF
  iface $VM1_EXTERNAL_IF inet dhcp
  dns-nameservers $VM_DNS
  auto $VM1_INTERNAL_IF
  iface $VM1_INTERNAL_IF inet static
  address $VM1_INTERNAL_IP
  netmask $INTERNAL_NET_MASK
  auto $VM1_MANAGEMENT_IF
  iface $VM1_MANAGEMENT_IF inet static
  address $VM1_MANAGEMENT_IP
  netmask $MANAGEMENT_NET_MASK" > config-drives/$VM1_NAME-config/meta-data

###### vm2 meta-data ######
echo "hostname: $VM2_NAME
local-hostname: $VM2_NAME
network-interfaces: |
  auto $VM2_INTERNAL_IF
  iface $VM2_INTERNAL_IF inet static
  address $VM2_INTERNAL_IP
  netmask $INTERNAL_NET_MASK
  gateway $VM1_INTERNAL_IP
  dns-nameservers $EXTERNAL_NET_HOST_IP $VM_DNS
  auto $VM2_MANAGEMENT_IF
  iface $VM2_MANAGEMENT_IF inet static
  address $VM2_MANAGEMENT_IP
  netmask $MANAGEMENT_NET_MASK" > config-drives/$VM2_NAME-config/meta-data

###### MK ISO ######
mkisofs -o $VM1_CONFIG_ISO -V cidata -r -J --quiet config-drives/$VM1_NAME-config
mkisofs -o $VM2_CONFIG_ISO -V cidata -r -J --quiet config-drives/$VM2_NAME-config

######################################## CONF  NETWORK ##############################################

###### EXTERNAL ######
echo "
<network>
  <name>$EXTERNAL_NET_NAME</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <ip address='$EXTERNAL_NET_HOST_IP' netmask='$EXTERNAL_NET_MASK'>
    <dhcp>
      <range start='$EXTERNAL_NET.2' end='$EXTERNAL_NET.254'/>
      <host mac='$VM1_MAC' name='vm1' ip='$VM1_EXTERNAL_IP'/>
    </dhcp>
  </ip>
</network>" > networks/$EXTERNAL_NET_NAME.xml

###### INTERNAL ######
echo "
<network>
  <name>$INTERNAL_NET_NAME</name>
</network>" > networks/$INTERNAL_NET_NAME.xml

###### MANAGEMENT ######
echo "
<network>
  <name>$MANAGEMENT_NET_NAME</name>
  <ip address='$MANAGEMENT_HOST_IP' netmask='$MANAGEMENT_NET_MASK'/>
</network>" > networks/$MANAGEMENT_NET_NAME.xml

###### APPLY XML ######
virsh net-destroy default
virsh net-undefine default
virsh net-define networks/$EXTERNAL_NET_NAME.xml
virsh net-start $EXTERNAL_NET_NAME
virsh net-autostart $EXTERNAL_NET_NAME
virsh net-define networks/$INTERNAL_NET_NAME.xml
virsh net-start $INTERNAL_NET_NAME
virsh net-autostart $INTERNAL_NET_NAME
virsh net-define networks/$MANAGEMENT_NET_NAME.xml
virsh net-start $MANAGEMENT_NET_NAME
virsh net-autostart $MANAGEMENT_NET_NAME

####################################### VIRT INSTALL ##################################################
wget -O /var/lib/libvirt/images/ubunut-server-16.04.qcow2 $VM_BASE_IMAGE

###### VM1 CREATE ######
cp /var/lib/libvirt/images/ubunut-server-16.04.qcow2  /var/lib/libvirt/images/$VM1_NAME/$VM1_NAME.qcow2
qemu-img resize /var/lib/libvirt/images/$VM1_NAME/$VM1_NAME.qcow2 +3GB
virt-install \
 --name $VM1_NAME\
 --ram $VM1_MB_RAM \
 --vcpus=$VM1_NUM_CPU \
 --$VM_TYPE \
 --os-type=linux \
 --os-variant=ubuntu16.04 \
 --disk path=$VM1_HDD,format=qcow2,bus=virtio,cache=none \
 --disk path=$VM1_CONFIG_ISO,device=cdrom \
 --graphics vnc,port=-1 \
 --network network=$EXTERNAL_NET_NAME,mac=\'$VM1_MAC\' \
 --network network=$INTERNAL_NET_NAME \
 --network network=$MANAGEMENT_NET_NAME \
 --noautoconsole \
 --quiet \
 --virt-type $VM_VIRT_TYPE \
 --import
virsh autostart $VM1_NAME

sleep 300

###### VM2 CREATE ######
cp /var/lib/libvirt/images/ubunut-server-16.04.qcow2  /var/lib/libvirt/images/$VM2_NAME/$VM2_NAME.qcow2
qemu-img resize /var/lib/libvirt/images/$VM2_NAME/$VM2_NAME.qcow2 +3GB
virt-install \
 --name $VM2_NAME\
 --ram $VM2_MB_RAM \
 --vcpus=$VM2_NUM_CPU \
 --$VM_TYPE \
 --os-type=linux \
 --os-variant=ubuntu16.04 \
 --disk path=$VM2_HDD,format=qcow2,bus=virtio,cache=none \
 --disk path=$VM2_CONFIG_ISO,device=cdrom \
 --graphics vnc,port=-1 \
 --network network=$INTERNAL_NET_NAME \
 --network network=$MANAGEMENT_NET_NAME \
 --noautoconsole \
 --quiet \
 --virt-type $VM_VIRT_TYPE \
 --import
virsh autostart $VM2_NAME
virsh list

echo '###### ALL DONE ######'
exit

