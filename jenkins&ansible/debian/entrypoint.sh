#!/bin/bash

set -e

dockerd &> /var/log/dockerd.log & 

sleep 10

exec /usr/sbin/sshd -D -e