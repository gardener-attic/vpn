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

#!/bin/bash -e

function log() {
  echo "[$(date -u)]: $*"
}

trap 'exit' TERM SIGINT

# Copy default config from cache
if [ ! "$(ls -A /etc/ssh)" ]; then
   cp -a /etc/ssh.cache/* /etc/ssh/
fi
# Generate Host keys, if required
if ! ls /etc/ssh/ssh_host_* 1> /dev/null 2>&1; then
    ssh-keygen -A
fi
# Fix permissions, if writable
if [ -w ~/.ssh ]; then
    chown root:root ~/.ssh && chmod 700 ~/.ssh/
fi
if [ -w ~/.ssh/authorized_keys ]; then
    chown root:root ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi
if [ -w /etc/authorized_keys ]; then
    chown root:root /etc/authorized_keys
    chmod 755 /etc/authorized_keys
    find /etc/authorized_keys/ -type f -exec chmod 644 {} \;
fi
# start ssh daemon in background
/usr/sbin/sshd -D -f /etc/ssh/sshd_config &


while true; do
  TUN_DEVICES=$(ip addr | grep -e 'tun[0-9]*:' | sed -E 's/^.*(: (tun[0-9]*)\:).*/\2/')
  if [[ ${#TUN_DEVICES[@]} == 0 ]]; then
    log "no tun interfaces found, retry in 5 seconds..."
    sleep 5
  else
    for device in $TUN_DEVICES; do
      if ! ip addr | grep -A 3 "$device": | grep 192 1>/dev/null; then
        log "success: $device found, adding peer"
        TUN_DEVICE_NR=$(echo $device | sed -E 's/^tun(.*)$/\1/')
        LOCAL_IP="192.168.111.$(expr 127 + $TUN_DEVICE_NR)"
        REMOTE_IP="192.168.111.$TUN_DEVICE_NR"

        ip addr add local $LOCAL_IP peer $REMOTE_IP broadcast $LOCAL_IP dev $device
        ip link set $device up
        if ! iptables-save | grep "POSTROUTING -o eth0" &> /dev/null; then
          iptables --append POSTROUTING --out-interface eth0 --table nat -j MASQUERADE
        fi
        if ! iptables-save | grep "FORWARD -i $device -j ACCEPT" &> /dev/null; then
          iptables --append FORWARD --in-interface $device -j ACCEPT
        fi
        log "ip routes added"
      fi
    done
    sleep 5
  fi
done