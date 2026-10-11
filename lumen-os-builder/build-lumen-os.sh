#!/usr/bin/env bash
# build-lumen-os.sh : builds a bootable, installable Linux ISO for OLD PCs (BIOS / legacy boot, no UEFI).
# Debian 12 base, lightweight XFCE desktop styled like a modern Windows-style desktop (original name, no
# Microsoft assets), Windows-11-style first-run setup wizard, Calamares installer.
#   ARCH=amd64 (default; 64-bit)  or  ARCH=i386 (32-bit, very old CPUs)
#   KERNEL_VERSION=auto  -> compiles the newest 6.1.x long-term kernel (amd64 only). Default = Debian's tested kernel.
# Untested on the author's side: if a step fails, copy the error text and ask Claude to fix it.
set -euo pipefail
DISTRO_NAME="${DISTRO_NAME:-Lumen OS}"; ARCH="${ARCH:-amd64}"; SUITE=bookworm
KERNEL_VERSION="${KERNEL_VERSION:-}"; KERNEL_CONFIG="${KERNEL_CONFIG:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="$(pwd)/lumen-build"; SAFE="${DISTRO_NAME// /-}"
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
[ "$ARCH" = amd64 ] || [ "$ARCH" = i386 ] || { echo "ARCH must be amd64 or i386"; exit 1; }
[ -z "$KERNEL_VERSION" ] || [ "$ARCH" = amd64 ] || { echo "Custom kernel only supported for amd64"; exit 1; }
apt-get update
apt-get install -y live-build debootstrap squashfs-tools xorriso syslinux syslinux-common isolinux debian-archive-keyring curl xz-utils python3 gnupg ca-certificates \
  build-essential bc bison flex libssl-dev libelf-dev dwarves rsync kmod cpio fakeroot debhelper
mkdir -p "$OUT" && cd "$OUT" && rm -rf config auto
FLAV=amd64; [ "$ARCH" = i386 ] && FLAV=686
lb config --distribution "$SUITE" --architectures "$ARCH" --linux-flavours "$FLAV" \
  --binary-images iso-hybrid --bootloaders syslinux \
  --archive-areas "main contrib non-free non-free-firmware" --debian-installer none \
  --iso-application "$DISTRO_NAME" --iso-volume "$SAFE" --bootappend-live "boot=live components quiet splash"
C=config; mkdir -p $C/package-lists $C/packages.chroot $C/hooks/normal $C/includes.chroot/usr/local/bin \
  $C/includes.chroot/etc/lightdm/lightdm.conf.d $C/includes.chroot/etc/skel/.config/autostart \
  $C/includes.chroot/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml

# ---- optional: compile a long-term kernel for this distro ----
if [ -n "$KERNEL_VERSION" ]; then
  if [ "$KERNEL_VERSION" = auto ]; then
    KERNEL_VERSION="$(curl -fsL https://www.kernel.org/releases.json | python3 -c "import sys,json;print([r['version'] for r in json.load(sys.stdin)['releases'] if r['moniker']=='longterm' and r['version'].startswith('6.1.')][0])")"
  fi
  echo ">> Building kernel $KERNEL_VERSION"; M="${KERNEL_VERSION%%.*}"
  [ -f "linux-$KERNEL_VERSION.tar.xz" ] || curl -fLO "https://cdn.kernel.org/pub/linux/kernel/v$M.x/linux-$KERNEL_VERSION.tar.xz"
  rm -rf "linux-$KERNEL_VERSION"; tar xf "linux-$KERNEL_VERSION.tar.xz"; pushd "linux-$KERNEL_VERSION" >/dev/null
  if [ -n "$KERNEL_CONFIG" ]; then cp "$KERNEL_CONFIG" .config; else make defconfig; fi
  scripts/config --enable BLK_DEV_SD --enable ATA --enable SATA_AHCI --enable ATA_PIIX --enable USB_STORAGE --enable SQUASHFS --enable SQUASHFS_XZ --enable OVERLAY_FS --enable ISO9660_FS --enable BLK_DEV_LOOP --enable DEVTMPFS --enable DEVTMPFS_MOUNT --enable EFI_PARTITION --disable DEBUG_INFO --disable DEBUG_INFO_BTF --disable SYSTEM_TRUSTED_KEYS --disable SYSTEM_REVOCATION_KEYS
  make olddefconfig; make -j"$(nproc)" bindeb-pkg LOCALVERSION=-lumen; popd >/dev/null
  cp linux-image-*lumen*.deb $C/packages.chroot/; rm -f $C/packages.chroot/*-dbg_*.deb
  echo "live-boot live-config initramfs-tools" > $C/package-lists/kernel.list.chroot
  lb config --linux-packages none
else
  echo "linux-image-$FLAV" > $C/package-lists/kernel.list.chroot
fi

cat > $C/package-lists/desktop.list.chroot <<'EOF'
live-boot live-config live-config-systemd sudo locales
xorg xserver-xorg-video-all xserver-xorg-input-all lightdm lightdm-gtk-greeter
xfce4 xfce4-whiskermenu-plugin xfce4-notifyd xfce4-power-manager xfce4-terminal xfce4-screenshooter thunar thunar-archive-plugin mousepad ristretto
arc-theme papirus-icon-theme fonts-inter fonts-noto-core
network-manager network-manager-gnome pulseaudio pavucontrol firefox-esr
python3-gi gir1.2-gtk-3.0 xdg-user-dirs calamares calamares-settings-debian
thunderbird onedrive
firmware-linux-free firmware-misc-nonfree firmware-iwlwifi firmware-realtek firmware-atheros firmware-b43-installer
EOF
# ---- Microsoft services: Edge (64-bit only), OneDrive client, Thunderbird for Outlook mail ----
echo "ca-certificates gnupg apt-transport-https" > $C/package-lists/base.list.chroot_install
if [ "$ARCH" = amd64 ]; then
  mkdir -p $C/archives
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > $C/archives/microsoft.key.chroot
  echo 'deb [arch=amd64] https://packages.microsoft.com/repos/edge stable main' > $C/archives/edge.list.chroot
  echo microsoft-edge-stable >> $C/package-lists/desktop.list.chroot
fi
printf '[Seat:*]\nautologin-user=user\nautologin-session=xfce\ngreeter-session=lightdm-gtk-greeter\n' > $C/includes.chroot/etc/lightdm/lightdm.conf.d/50-live.conf
X=$C/includes.chroot/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
cat > $X/xsettings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0"><property name="Net" type="empty"><property name="ThemeName" type="string" value="Arc"/><property name="IconThemeName" type="string" value="Papirus"/></property><property name="Gtk" type="empty"><property name="FontName" type="string" value="Inter 10"/></property></channel>
EOF
cat > $X/xfwm4.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0"><property name="general" type="empty"><property name="theme" type="string" value="Arc"/><property name="button_layout" type="string" value="|HMC"/><property name="use_compositing" type="bool" value="false"/></property></channel>
EOF
cat > $X/xfce4-panel.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0"><property name="configver" type="int" value="2"/>
<property name="panels" type="array"><value type="int" value="1"/>
<property name="panel-1" type="empty"><property name="position" type="string" value="p=8;x=0;y=0"/><property name="length" type="uint" value="100"/><property name="position-locked" type="bool" value="true"/><property name="size" type="uint" value="44"/>
<property name="plugin-ids" type="array"><value type="int" value="1"/><value type="int" value="2"/><value type="int" value="3"/><value type="int" value="4"/><value type="int" value="5"/><value type="int" value="6"/></property></property></property>
<property name="plugins" type="empty">
<property name="plugin-1" type="string" value="separator"><property name="expand" type="bool" value="true"/><property name="style" type="uint" value="0"/></property>
<property name="plugin-2" type="string" value="whiskermenu"/>
<property name="plugin-3" type="string" value="tasklist"><property name="show-labels" type="bool" value="false"/><property name="flat-buttons" type="bool" value="true"/></property>
<property name="plugin-4" type="string" value="separator"><property name="expand" type="bool" value="true"/><property name="style" type="uint" value="0"/></property>
<property name="plugin-5" type="string" value="systray"/><property name="plugin-6" type="string" value="clock"/></property></channel>
EOF
install -m 755 "$HERE/overlay/lumen-setup" $C/includes.chroot/usr/local/bin/lumen-setup
cat > $C/includes.chroot/usr/local/bin/lumen-setup-launch <<'EOF'
#!/bin/sh
[ -d /run/live ] && exit 0
[ -f "$HOME/.config/.lumen-setup-done" ] && exit 0
exec /usr/local/bin/lumen-setup
EOF
chmod 755 $C/includes.chroot/usr/local/bin/lumen-setup-launch
printf '[Desktop Entry]\nType=Application\nName=Setup\nExec=/usr/local/bin/lumen-setup-launch\n' > $C/includes.chroot/etc/skel/.config/autostart/lumen-setup.desktop
printf '#!/bin/sh\nsed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\\"%s\\"/" /etc/os-release || true\n' "$DISTRO_NAME" > $C/hooks/normal/0100-brand.hook.chroot
chmod +x $C/hooks/normal/0100-brand.hook.chroot

echo ">> Building ISO (30-90 min)"; lb build
mv "$(ls -1 *.iso | head -n1)" "../$SAFE-$ARCH.iso"
echo "DONE: $(dirname "$OUT")/$SAFE-$ARCH.iso  (BIOS/legacy boot)"
