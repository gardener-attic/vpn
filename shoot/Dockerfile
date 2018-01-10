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

FROM alpine:3.7

RUN apk add --update bash curl openssh rsync iptables && \
    mkdir -p ~root/.ssh /etc/authorized_keys && chmod 700 ~root/.ssh/ && \
    sed -i -e 's@^AuthorizedKeysFile.*@@g' /etc/ssh/sshd_config  && \
    echo -e "AuthorizedKeysFile\t.ssh/authorized_keys /etc/authorized_keys/%u" >> /etc/ssh/sshd_config && \
    echo -e "Port 22\n" >> /etc/ssh/sshd_config && \
    cp -a /etc/ssh /etc/ssh.cache && \
    rm -rf /var/cache/apk/*

ADD ./network-connection.sh /network-connection

EXPOSE 22

# We use "exec" and "trap 'exit' TERM" in the bash script, otherwise,
# the script won't recieve and react to SIGTERM
CMD exec /network-connection
