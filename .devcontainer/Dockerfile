# Используем базовый образ
FROM mcr.microsoft.com/devcontainers/base:debian

# Установим зависимости
RUN apt-get update && \
    apt-get install -y wget gpg lsb-release gnupg software-properties-common curl

# Добавим репозиторий HashiCorp и установим Terraform
RUN wget -O- https://apt.releases.hashicorp.com/gpg | \
    gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
    https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list && \
    apt-get update && \
    apt-get install -y terraform && \
    apt-get install -y inotify-tools && \
    apt-get install -y netcat-openbsd && \
    terraform -version

RUN curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash

RUN echo 'export PATH=$PATH:/root/yandex-cloud/bin' >> /root/.bashrc

COPY .terraformrc /root/.terraformrc

ENV PATH=$PATH:/root/yandex-cloud/bin
