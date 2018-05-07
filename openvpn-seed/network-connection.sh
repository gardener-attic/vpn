#!/bin/bash -e
#
# Copyright 2018 The Gardener Authors.
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

service_name="${SERVICE_NAME:-openvpn-shoot}"
openvpn_port="${OPENVPN_PORT:-1194}"

tcp_keepalive_time="${TCP_KEEPALIVE_TIME:-7200}"
tcp_keepalive_intvl="${TCP_KEEPALIVE_INTVL:-75}"
tcp_keepalive_probes="${TCP_KEEPALIVE_PROBES:-9}"
tcp_retries2="${TCP_RETRIES2:-5}"

curl_timeout_options="--connect-timeout 5 --max-time 5"

function get_host() {
  if [[ -z "$MAIN_VPN_SEED" ]]; then
    echo "$KUBE_APISERVER_SERVICE_HOST:$KUBE_APISERVER_SERVICE_PORT"
  else
    echo "127.0.0.1"
  fi
}

function identify_endpoint() {
  log "trying to identify the endpoint (load balancer name of $service_name service) myself..."

  set +e
  BASIC_AUTH="admin:$(cat /srv/auth/basic_auth.csv | sed -E 's/^([^,]*),.*$/\1/')"
  SERVICE_STATUS="$(curl \
                      ${curl_timeout_options} \
                      --silent \
                      --insecure \
                      --user "$BASIC_AUTH" \
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

function restart_vpn_shoot() {
  log "deleting vpn-shoot container(s)..."
  set +e

  BASIC_AUTH="admin:$(cat /srv/kubernetes/auth/basic_auth.csv | sed -E 's/^([^,]*),.*$/\1/')"
  RESPONSE="$(curl \
                ${curl_timeout_options} \
                --silent \
                --insecure \
                --user "$BASIC_AUTH" \
                --header "Accept: application/json" \
                --request GET \
                "https://$(get_host)/api/v1/namespaces/kube-system/pods?labelSelector=app=$service_name")"
  POD_NAMES="$(echo $RESPONSE | jq -r '.items[].metadata.name')"

  for name in "$POD_NAMES"; do
    curl \
      ${curl_timeout_options} \
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

function configure_tcp() {
    echo $tcp_keepalive_time > /proc/sys/net/ipv4/tcp_keepalive_time
    echo $tcp_keepalive_intvl > /proc/sys/net/ipv4/tcp_keepalive_intvl
    echo $tcp_keepalive_probes > /proc/sys/net/ipv4/tcp_keepalive_probes

    echo $tcp_retries2 > /proc/sys/net/ipv4/tcp_retries2
}

configure_tcp

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
