# CI 容器：自包含的 ARM64+USB 模拟环境（无 KVM 依赖，TCG 运行）
# 构建:  docker build -t qemuemulator-ci -f ci/Dockerfile .
# 运行:  docker run --rm --network host \
#          -v <repo>/p0/images:/lab/p0/images \        # 可选: 挂载已下载的镜像省去下载
#          qemuemulator-ci envctl up --fresh && envctl test
# 注意: 首次运行需下载云镜像(588MB)+guest 内安装 modules-extra(20-30min TCG)，
#       建议持久化 overlay/快照卷以复用。

FROM ubuntu:24.04 AS qemu-build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential meson ninja-build pkg-config python3 python3-venv git \
        ca-certificates xz-utils curl \
        libglib2.0-dev libpixman-1-dev zlib1g-dev libfdt-dev libslirp-dev \
    && rm -rf /var/lib/apt/lists/*
COPY p1/scripts/11_apply_device.sh /lab/p1/scripts/
COPY p1/device/dev-wmodem.c /lab/p1/device/
RUN curl -fL -o /tmp/qemu.tar.xz https://download.qemu.org/qemu-9.2.0.tar.xz \
    && mkdir -p /opt && tar -xf /tmp/qemu.tar.xz -C /opt \
    && cd /opt/qemu-9.2.0 \
    && cp /lab/p1/device/dev-wmodem.c hw/usb/ \
    && grep -q USB_WMODEM hw/usb/Kconfig || { \
         printf '\nconfig USB_WMODEM\n    bool\n    default y\n    depends on USB\n' >> hw/usb/Kconfig; \
         printf "system_ss.add(when: 'CONFIG_USB_WMODEM', if_true: files('dev-wmodem.c'))\n" >> hw/usb/meson.build; } \
    && mkdir build && cd build \
    && ../configure --target-list=aarch64-softmmu --disable-docs \
        --disable-guest-agent --disable-werror \
    && make -j"$(nproc)"

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        genisoimage openssh-client curl \
        python3 python3-pip iputils-ping \
        libglib2.0-0 libpixman-1-0 zlib1g libfdt1 libslirp0 \
    && pip install --break-system-packages pytest \
    && rm -rf /var/lib/apt/lists/*
COPY --from=qemu-build /opt/qemu-9.2.0/build/qemu-system-aarch64 /opt/qemu/qemu-system-aarch64
COPY --from=qemu-build /opt/qemu-9.2.0/build/qemu-img /opt/qemu/qemu-img
COPY p1/compat/QEMU_EFI.fd /lab/p1/compat/QEMU_EFI.fd
COPY . /lab
WORKDIR /lab/p1
ENV PATH="/opt/qemu:${PATH}" \
    QEMU_CUSTOM=/opt/qemu/qemu-system-aarch64
# 约定: 20_run_vm.sh 优先使用 $QEMU_CUSTOM（若存在）而非 build 目录中的二进制
CMD ["python3", "envctl.py", "verify"]
