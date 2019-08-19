#!/bin/sh

set -e

if [ -z "$1" ] || [ -z "$2" ]; then
	echo "buildimg.sh srcdir disk.img"
	exit 1
fi
SRCDIR=$1
IMGFILE=$2

# Set environment variables so make can use them.
export TARGET=mips
export TARGET_ARCH=mips64
export KERNCONF=ERL

# Create working space
WORKDIR=`env TMPDIR=\`pwd\` mktemp -d -t ERLBUILD`
chflags nodump ${WORKDIR}

# Build MIPS64 world and ERL kernel
JN=`sysctl -n hw.ncpu`
make -C $SRCDIR buildworld -j${JN}
make -C $SRCDIR buildkernel -j${JN}

# Install into a temporary tree
mkdir ${WORKDIR}/tree
make -C ${SRCDIR} installworld distribution installkernel DESTDIR=${WORKDIR}/tree

# Download packages
cp /etc/resolv.conf ${WORKDIR}/tree/etc/
mkdir -p ${WORKDIR}/tree/usr/local/etc/pkg/repos/
sed -e 's/quarterly/latest/' ${WORKDIR}/tree/etc/pkg/FreeBSD.conf > ${WORKDIR}/tree/usr/local/etc/pkg/repos/FreeBSD.conf
pkg -c ${WORKDIR}/tree install -Fy pkg djbdns isc-dhcp43-server
rm ${WORKDIR}/tree/etc/resolv.conf

# FreeBSD configuration
cat > ${WORKDIR}/tree/etc/rc.conf <<EOF
hostname="ERL"
growfs_enable="YES"
tmpfs="YES"
tmpsize="50M"
ifconfig_octe0="DHCP"
ifconfig_octe1="192.168.1.1 netmask 255.255.255.0"
ifconfig_octe2="192.168.2.1 netmask 255.255.255.0"
pf_enable="YES"
gateway_enable="YES"
sendmail_enable="NONE"
sshd_enable="YES"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
svscan_enable="YES"
dhcpd_enable="YES"
dhcpd_ifaces="octe1 octe2"
EOF
cat > ${WORKDIR}/tree/etc/pf.conf <<EOF
# Allow anything on loopback
set skip on lo0

# Scrub all incoming traffic
scrub in

# NAT outgoing traffic
nat on octe0 inet from { octe1:network, octe2:network } to any -> (octe0:0)

# Reject anything with spoofed addresses
antispoof quick for { octe1, octe2, lo0 } inet

# Default to blocking incoming traffic but allowing outgoing traffic
block all
pass out all

# Allow LAN to access the rest of the world
pass in on { octe1, octe2 } from any to any
block in on { octe1, octe2 } from any to self

# Allow LAN to ping us                                       
pass in on { octe1, octe2 } inet proto icmp to self icmp-type echoreq

# Allow LAN to access DNS, DHCP, and NTP
pass in on { octe1, octe2 } proto udp to self port { 53, 67, 123 }
pass in on { octe1, octe2 } proto tcp to self port 53

# Allow octe2 to access SSH
pass in on octe2 proto tcp to self port 22
EOF
mkdir -p ${WORKDIR}/tree/usr/local/etc
cat > ${WORKDIR}/tree/usr/local/etc/dhcpd.conf <<EOF
option domain-name "localdomain";
subnet 192.168.1.0 netmask 255.255.255.0 {
        range 192.168.1.2 192.168.1.254;
        option routers 192.168.1.1;
        option domain-name-servers 192.168.1.1;
}
subnet 192.168.2.0 netmask 255.255.255.0 {
        range 192.168.2.2 192.168.2.254;
        option routers 192.168.2.1;
        option domain-name-servers 192.168.2.1;
}
EOF

# Script to complete setup once we're running on the right hardware
mkdir -p ${WORKDIR}/tree/usr/local/etc/rc.d
cat > ${WORKDIR}/tree/usr/local/etc/rc.d/ERL <<'EOF'
#!/bin/sh

# KEYWORD: firstboot
# PROVIDE: ERL
# REQUIRE: NETWORKING
# BEFORE: LOGIN

# This script completes the configuration of EdgeRouter Lite systems.  It
# is only included in those images, and so is enabled by default.

. /etc/rc.subr

: ${ERL_enable:="YES"}

name="ERL"
rcvar="ERL_enable"
start_cmd="ERL_run"
stop_cmd=":"

ERL_run()
{

	# Packages
	env SIGNATURE_TYPE=NONE pkg add -f /var/cache/pkg/pkg-*.txz
	pkg install -Uy djbdns isc-dhcp43-server

	# DNS setup
	pw user add dnscache -u 184 -d /nonexistent -s /usr/sbin/nologin
	pw user add dnslog -u 186 -d /nonexistent -s /usr/sbin/nologin
	mkdir /var/service
	/usr/local/bin/dnscache-conf dnscache dnslog /var/service/dnscache 0.0.0.0
	touch /var/service/dnscache/root/ip/192.168

	# Create ubnt user
	echo ubnt | pw user add ubnt -m -G wheel -h 0

	# We need to reboot so that services will be started
	touch ${firstboot_sentinel}-reboot
}

load_rc_config $name
run_rc_command "$1"
EOF
chmod 755 ${WORKDIR}/tree/usr/local/etc/rc.d/ERL

# We want to run firstboot scripts
touch ${WORKDIR}/tree/firstboot

# Create FAT32 filesystem to hold the kernel
newfs_msdos -C 33M -F 32 -c 1 -S 512 ${WORKDIR}/FAT32.img
mddev=`mdconfig -f ${WORKDIR}/FAT32.img`
mkdir ${WORKDIR}/FAT32
mount -t msdosfs /dev/${mddev}  ${WORKDIR}/FAT32
cp ${WORKDIR}/tree/boot/kernel/kernel ${WORKDIR}/FAT32/vmlinux.64
umount /dev/${mddev}
rmdir ${WORKDIR}/FAT32
mdconfig -d -u ${mddev}

# Create UFS filesystem
echo "/dev/da0s2a / ufs rw 1 1" > ${WORKDIR}/tree/etc/fstab
makefs -f 16384 -B big -s 1600m ${WORKDIR}/UFS.img ${WORKDIR}/tree

# Create complete disk image
mkimg -s mbr		\
    -p fat32:=${WORKDIR}/FAT32.img \
    -p "freebsd:-mkimg -s bsd -p freebsd-ufs:=${WORKDIR}/UFS.img" \
    -o ${IMGFILE}

# Clean up
chflags -R noschg ${WORKDIR}
rm -r ${WORKDIR}
