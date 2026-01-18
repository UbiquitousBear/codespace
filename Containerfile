FROM scratch
LABEL org.opencontainers.image.source=https://github.com/UbiquitousBear/codespaces-vm

COPY codespace-vm-kernel /boot/vmlinuz
COPY codespace-vm-initrd.img /boot/initrd.img
