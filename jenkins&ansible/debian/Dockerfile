FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y sudo openssh-server docker.io python3 python3-docker && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd && \
    echo "PermitRootLogin no" > /etc/ssh/sshd_config.d/10-ssh_config.conf && \
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config.d/10-ssh_config.conf && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config.d/10-ssh_config.conf && \
    echo "AllowUsers andrea" >> /etc/ssh/sshd_config.d/10-ssh_config.conf

RUN useradd --create-home --shell /bin/bash --groups sudo andrea && \
    echo "andrea ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/andrea && \
    chmod 440 /etc/sudoers.d/andrea && \
    mkdir -p /home/andrea/.ssh && \
    chmod 700 /home/andrea/.ssh && \
    chown andrea:andrea /home/andrea/.ssh

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