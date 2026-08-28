FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y sudo openssh-server docker.io python3 python3-docker && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd && \
    sed -i -E 's/^#?#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i -E 's/^#?PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i -E 's/^#?PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo 'AllowUsers andrea' >> /etc/ssh/sshd_config

RUN useradd --create-home --shell /bin/bash --groups sudo andrea && \
    echo "andrea ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p /home/andrea/.ssh && \
    chmod 700 /home/andrea/.ssh && \
    chown andrea:andrea /home/andrea/.ssh

COPY id_key_andrea.pub /home/andrea/.ssh/authorized_keys

RUN chmod 600 /home/andrea/.ssh/authorized_keys && \
    chown andrea:andrea /home/andrea/.ssh/authorized_keys

RUN groupadd -f docker && usermod -aG docker andrea

RUN mkdir -p /etc/docker && cat > /etc/docker/daemon.json <<'EOF'
{
  "insecure-registries": ["192.168.56.14:5000"]
}
EOF

EXPOSE 22

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]