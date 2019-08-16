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

service_name="${SERVICE_NAME:-vpn-shoot}"
openvpn_port="${OPENVPN_PORT:-1194}"

tcp_keepalive_time="${TCP_KEEPALIVE_TIME:-7200}"
tcp_keepalive_intvl="${TCP_KEEPALIVE_INTVL:-75}"
tcp_keepalive_probes="${TCP_KEEPALIVE_PROBES:-9}"
tcp_retries2="${TCP_RETRIES2:-5}"

APISERVER_AUTH_MODE="${APISERVER_AUTH_MODE:-basic-auth}"
APISERVER_AUTH_MODE_BASIC_AUTH_CSV="${APISERVER_AUTH_MODE_BASIC_AUTH_CSV:-/srv/auth/basic_auth.csv}"
APISERVER_AUTH_MODE_BASIC_AUTH_USERNAME="${APISERVER_AUTH_MODE_BASIC_AUTH_USERNAME:-admin}"
APISERVER_AUTH_MODE_CLIENT_CERT_CA="${APISERVER_AUTH_MODE_CLIENT_CERT_CA:-/srv/secrets/vpn-seed/ca.crt}"
APISERVER_AUTH_MODE_CLIENT_CERT_CRT="${APISERVER_AUTH_MODE_CLIENT_CERT_CRT:-/srv/secrets/vpn-seed/tls.crt}"
APISERVER_AUTH_MODE_CLIENT_CERT_KEY="${APISERVER_AUTH_MODE_CLIENT_CERT_KEY:-/srv/secrets/vpn-seed/tls.key}"

function get_host() {
  if [[ -z "$MAIN_VPN_SEED" ]]; then
    echo "kube-apiserver"
  else
    echo "127.0.0.1"
  fi
}

function identify_endpoint() {
  log "trying to identify the endpoint (load balancer name of $service_name service) myself..."

  curl_auth_flags=""
  if [[ "$APISERVER_AUTH_MODE" == "basic-auth" ]]; then
    curl_auth_flags="--insecure --user ${APISERVER_AUTH_MODE_BASIC_AUTH_USERNAME}:$(cat ${APISERVER_AUTH_MODE_BASIC_AUTH_CSV} | sed -E 's/^([^,]*),.*$/\1/')"
  elif [[ "$APISERVER_AUTH_MODE" == "client-cert" ]]; then
    curl_auth_flags="--cacert $APISERVER_AUTH_MODE_CLIENT_CERT_CA --cert $APISERVER_AUTH_MODE_CLIENT_CERT_CRT --key $APISERVER_AUTH_MODE_CLIENT_CERT_KEY"
  fi

  set +e
  SERVICE_STATUS="$(curl \
                      --connect-timeout 5 \
                      --max-time 5 \
                      --silent \
                      $curl_auth_flags \
                      --header "Accept: application/json" \
                      --request GET \
                      "https://$(get_host)/api/v1/namespaces/kube-system/services/$service_name")"
  ENDPOINTS="$(echo "$SERVICE_STATUS" | jq -r 'if (.status | type) == "object" and (.status.loadBalancer | type) == "object" and (.status.loadBalancer.ingress | type) == "array" and (.status.loadBalancer.ingress | length) > 0 then .status.loadBalancer.ingress | map(if(. | has("ip")) then .ip else .hostname end) | .[] else empty end')"
  set -e

ENDPOINT=""
  if [[ -z "$ENDPOINTS" || "$ENDPOINTS" == "null" ]]; then
    log "error: could not identify any endpoints"
    return
  fi

  log "found endpoints: [ $(echo $ENDPOINTS | tr "\n" " ")]"
  for endpoint in $ENDPOINTS; do
    log "checking whether port ${openvpn_port} is open on $endpoint ..."
    if ! nc -z -v -w 3 "$endpoint" "${openvpn_port}" &> /dev/null; then
      log "error: port ${openvpn_port} on $endpoint is not open, can not use it"
    else
      log "port ${openvpn_port} on $endpoint is open, using it"
      ENDPOINT="$endpoint"
      return
    fi
  done
}

function set_value() {
  if [ -f $1 ] ; then
    log "Setting $2 on $1"
    echo "$2" > $1
  fi
}

function configure_tcp() {
  set_value /proc/sys/net/ipv4/tcp_keepalive_time $tcp_keepalive_time
  set_value /proc/sys/net/ipv4/tcp_keepalive_intvl $tcp_keepalive_intvl
  set_value /proc/sys/net/ipv4/tcp_keepalive_probes $tcp_keepalive_probes

  set_value /proc/sys/net/ipv4/tcp_retries2 $tcp_retries2
}

configure_tcp

# for each cidr config, it looks first at its env var, then a local file (which may be a volume mount), then the default
baseConfigDir="/init-config"
fileServiceNetwork=
filePodNetwork=
fileNodeNetwork=
[ -e "${baseConfigDir}/serviceNetwork" ] && fileServiceNetwork=$(cat ${baseConfigDir}/serviceNetwork)
[ -e "${baseConfigDir}/podNetwork" ] && filePodNetwork=$(cat ${baseConfigDir}/podNetwork)
[ -e "${baseConfigDir}/nodeNetwork" ] && fileNodeNetwork=$(cat ${baseConfigDir}/nodeNetwork)

service_network="${SERVICE_NETWORK:-${fileServiceNetwork}}"
service_network="${service_network:-100.64.0.0/13}"
pod_network="${POD_NETWORK:-${filePodNetwork}}"
pod_network="${pod_network:-100.96.0.0/11}"
node_network="${NODE_NETWORK:-${fileNodeNetwork}}"
node_network="${node_network:-10.250.0.0/16}"

# calculate netmask for given CIDR (required by openvpn)
CIDR2Netmask() {
    local cidr="$1"

    local ip=$(echo $cidr | cut -f1 -d/)
    local numon=$(echo $cidr | cut -f2 -d/)

    local numoff=$(( 32 - $numon ))
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

while : ; do
    # identify_endpoint may get an invalid endpoint, need
    # to make sure openvpn is able to pick up the correct
    # one once it has been registered
    identify_endpoint
    if [[ ! -z $ENDPOINT ]]; then
        openvpn --remote ${ENDPOINT} --port ${openvpn_port} --config openvpn.config
    else
        log "No tunnel endpoint found"
    fi
    sleep 5
done
