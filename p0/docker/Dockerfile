FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        qemu-system-arm \
        qemu-utils \
        genisoimage \
        qemu-efi-aarch64 \
        openssh-client \
        curl \
    && rm -rf /var/lib/apt/lists/*
