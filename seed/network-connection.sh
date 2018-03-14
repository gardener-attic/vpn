#!/bin/bash -eu
#
# Copyright 2017 The Gardener Authors.
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

if [[ -z "$IDENTITY_FILE" ]]; then
  log "error: environment variable IDENTITY_FILE not set"
  exit 1
fi
chmod 600 $IDENTITY_FILE

service_network="${SERVICE_NETWORK:-100.64.0.0/13}"
pod_network="${POD_NETWORK:-100.96.0.0/11}"
node_network="${NODE_NETWORK:-10.250.0.0/16}"
service_name="${SERVICE_NAME:-vpn-shoot}"

failed_pings=0
successful_ssh_connections_without_ping=0

function identify_endpoint() {
  log "trying to identify the endpoint (load balancer name of $service_name service) myself..."

  set +e
  BASIC_AUTH="admin:$(cat /srv/auth/basic_auth.csv | sed -E 's/^([^,]*),.*$/\1/')"
  SERVICE_STATUS="$(curl \
                      --silent \
                      --insecure \
                      --user "$BASIC_AUTH" \
                      --header "Accept: application/json" \
                      --request GET \
                      "https://$KUBE_APISERVER_SERVICE_HOST:$KUBE_APISERVER_SERVICE_PORT/api/v1/namespaces/kube-system/services/$service_name")"
  ENDPOINTS="$(echo "$SERVICE_STATUS" | jq -r 'if (.status | type) == "object" and (.status.loadBalancer | type) == "object" and (.status.loadBalancer.ingress | type) == "array" and (.status.loadBalancer.ingress | length) > 0 then .status.loadBalancer.ingress | map(if(. | has("ip")) then .ip else .hostname end) | .[] else empty end')"
  set -e

ENDPOINT=""
  if [[ -z "$ENDPOINTS" || "$ENDPOINTS" == "null" ]]; then
    log "error: could not identify any endpoints"
    return
  fi

  log "found endpoints: [ $(echo $ENDPOINTS | tr "\n" " ")]"
  for endpoint in $ENDPOINTS; do
    log "checking whether port 22 is open on $endpoint ..."
    if ! nc -z -v -w 3 "$endpoint" 22 &> /dev/null; then
      log "error: port 22 on $endpoint is not open, can not use it"
    else
      log "port 22 on $endpoint is open, using it"
      ENDPOINT="$endpoint"
      return
    fi
  done
}

function restart_vpn_shoot() {
  log "deleting vpn-shoot container(s)..."
  set +e

  BASIC_AUTH="admin:$(cat /srv/auth/basic_auth.csv | sed -E 's/^([^,]*),.*$/\1/')"
  RESPONSE="$(curl \
                --silent \
                --insecure \
                --user "$BASIC_AUTH" \
                --header "Accept: application/json" \
                --request GET \
                "https://$KUBE_APISERVER_SERVICE_HOST:$KUBE_APISERVER_SERVICE_PORT/api/v1/namespaces/kube-system/pods?labelSelector=app=$service_name")"
  POD_NAMES="$(echo $RESPONSE | jq -r '.items[].metadata.name')"

  for name in "$POD_NAMES"; do
    curl \
      --silent \
      --insecure \
      --user "$BASIC_AUTH" \
      --header "Accept: application/json" \
      --request DELETE \
      "https://$KUBE_APISERVER_SERVICE_HOST:$KUBE_APISERVER_SERVICE_PORT/api/v1/namespaces/kube-system/pods/$name"
  done

  set -e
  log "deletion done"
}

while true; do
  if ! ip addr | grep -e 'tun[0-9]*:' 1>/dev/null; then
    log "no tunnel interface found..."
    identify_endpoint
    if [[ ! -z "$ENDPOINT" ]]; then
      if [[ -z "$MAIN_VPN_SEED" ]]; then
        log "choosing randomly a tunnel device number"
        TUN_DEVICE_NR="$(shuf -i 2-127 -n 1)"
      else
        log "using tunnel device number 1"
        TUN_DEVICE_NR="1"
      fi

      if [[ $successful_ssh_connections_without_ping -ge 5 ]]; then
        restart_vpn_shoot
        successful_ssh_connections_without_ping=0
        log "successful_ssh_connections_without_ping: $successful_ssh_connections_without_ping"
      else
        TUN_DEVICE="tun$TUN_DEVICE_NR"
        LOCAL_IP="192.168.111.$TUN_DEVICE_NR"
        REMOTE_IP="192.168.111.$(expr 127 + $TUN_DEVICE_NR)"
        log "tun device: $TUN_DEVICE"
        log "LOCAL_IP:   $LOCAL_IP"
        log "REMOTE_IP:  $REMOTE_IP"

        log "trying to establish the ssh connection..."
        if ssh \
          -w "$TUN_DEVICE_NR:$TUN_DEVICE_NR" \
          -q \
          -o "StrictHostKeyChecking=no" \
          -o "ServerAliveInterval=30" \
          -o "ServerAliveCountMax=5" \
          -o "UserKnownHostsFile=/dev/null" \
          -i "$IDENTITY_FILE" \
          -f \
          -N \
          "$USER"@"$ENDPOINT"; then

          # check whether tunnel device was created
          if ip addr | grep -e "${TUN_DEVICE}:"; then
            ip addr add local $LOCAL_IP peer $REMOTE_IP broadcast $LOCAL_IP dev $TUN_DEVICE
            ip link set $TUN_DEVICE up
            ip route add $service_network via $LOCAL_IP # service network
            ip route add $pod_network     via $LOCAL_IP # pod network
            ip route add $node_network    via $LOCAL_IP # host network
            successful_ssh_connections_without_ping=$((successful_ssh_connections_without_ping+1))
            log "success: ssh connection established, successful_ssh_connections_without_ping: $successful_ssh_connections_without_ping"
          else
            set +e
            log "error: ssh connection established, but tun device not found - killing ssh connection"
            kill -9 $(pgrep -fn "ssh -w $TUN_DEVICE_NR:$TUN_DEVICE_NR")
            set -e
          fi
        else
          log "error: ssh connection could not be established"
        fi
      fi
    fi
  else
    TUN_DEVICE=$(ip addr | grep -e 'tun[0-9]*:' | sed -E 's/^.*(: (tun[0-9]*)\:).*/\2/')
    TUN_DEVICE_NR=$(echo $TUN_DEVICE | sed -E 's/^tun([0-9]*)$/\1/')
    REMOTE_IP="192.168.111.$(expr 127 + $TUN_DEVICE_NR)"

    log "$TUN_DEVICE found. pinging peer to keep the connection up"
    set +e
    if ! ping $REMOTE_IP -w 5 -c 1 1>/dev/null; then
      log "did not receive pong from peer after 5 seconds, trying further..."
      let failed_pings++
      if [[ $failed_pings -gt 3 ]]; then
        log "did not receive a pong for 30 sec - killing ssh connection"
        kill -9 $(pgrep -fn "ssh -w $TUN_DEVICE_NR:$TUN_DEVICE_NR")
        failed_pings=0
      fi
    else
      failed_pings=0
      successful_ssh_connections_without_ping=0
      log "pong from peer received successfully, successful_ssh_connections_without_ping: $successful_ssh_connections_without_ping"
    fi
    set -e
  fi
  sleep 5
done
