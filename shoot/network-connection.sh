#!/bin/bash -e
#
# Copyright (c) 2018 SAP SE or an SAP affiliate company. All rights reserved. This file is licensed under the Apache Software License, v. 2 except as noted otherwise in the LICENSE file
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

function log() {
  echo "[$(date -u)]: $*"
}

trap 'exit' TERM SIGINT

service_network="${SERVICE_NETWORK:-100.64.0.0/13}"
pod_network="${POD_NETWORK:-100.96.0.0/11}"
node_network="${NODE_NETWORK:-10.250.0.0/16}"

# calculate netmask for given CIDR (required by openvpn)
#
CIDR2Netmask() {
    local cidr="$1"

    local ip=$(echo $cidr | cut -f1 -d/)
    local numon=$(echo $cidr | cut -f2 -d/)

    local numoff=$(( 32 - $numon ))
    local start=
    local end=
    while [ "$numon" -ne "0" ]; do
            start=1${start}
            numon=$(( $numon - 1 ))
    done
    while [ "$numoff" -ne "0" ]; do
        end=0${end}
        numoff=$(( $numoff - 1 ))
    done
    local bitstring=$start$end

    bitmask=$(echo "obase=16 ; $(( 2#$bitstring )) " | bc | sed 's/.\{2\}/& /g')

    local str=
    for t in $bitmask ; do
        str=$str.$((16#$t))
    done

    echo $str | cut -f2-  -d\.
}

service_network_address=$(echo $service_network | cut -f1 -d/)
service_network_netmask=$(CIDR2Netmask $service_network)

pod_network_address=$(echo $pod_network | cut -f1 -d/)
pod_network_netmask=$(CIDR2Netmask $pod_network)

node_network_address=$(echo $node_network | cut -f1 -d/)
node_network_netmask=$(CIDR2Netmask $node_network)

sed -e "s/\${SERVICE_NETWORK_ADDRESS}/${service_network_address}/" \
    -e "s/\${SERVICE_NETWORK_NETMASK}/${service_network_netmask}/" \
    -e "s/\${POD_NETWORK_ADDRESS}/${pod_network_address}/" \
    -e "s/\${POD_NETWORK_NETMASK}/${pod_network_netmask}/" \
    -e "s/\${NODE_NETWORK_ADDRESS}/${node_network_address}/" \
    -e "s/\${NODE_NETWORK_NETMASK}/${node_network_netmask}/" openvpn.config.template > openvpn.config


# make sure forwarding is enabled
#
echo 1 > /proc/sys/net/ipv4/ip_forward

# enable forwarding and NAT
iptables --append FORWARD --in-interface tun0 -j ACCEPT
iptables --append POSTROUTING --out-interface eth0 --table nat -j MASQUERADE

openvpn --config openvpn.config
