# ------------------------------------------------------------------------------
# STREAM.SH
# ------------------------------------------------------------------------------
set -e
source $INSTALLER/000-source

# ------------------------------------------------------------------------------
# ENVIRONMENT
# ------------------------------------------------------------------------------
MACH="eb-stream"
cd $MACHINES/$MACH

ROOTFS="/var/lib/lxc/$MACH/rootfs"
DNS_RECORD=$(grep "address=/$MACH/" /etc/dnsmasq.d/eb-stream | head -n1)
IP=${DNS_RECORD##*/}
SSH_PORT="30$(printf %03d ${IP##*.})"
echo STREAM="$IP" >> $INSTALLER/000-source

# ------------------------------------------------------------------------------
# NFTABLES RULES
# ------------------------------------------------------------------------------
# the public ssh
nft delete element eb-nat tcp2ip { $SSH_PORT } 2>/dev/null || true
nft add element eb-nat tcp2ip { $SSH_PORT : $IP }
nft delete element eb-nat tcp2port { $SSH_PORT } 2>/dev/null || true
nft add element eb-nat tcp2port { $SSH_PORT : 22 }
# rtmp
nft delete element eb-nat tcp2ip { 1935 } 2>/dev/null || true
nft add element eb-nat tcp2ip { 1935 : $IP }
nft delete element eb-nat tcp2port { 1935 } 2>/dev/null || true
nft add element eb-nat tcp2port { 1935 : 1935 }
# admin web
nft delete element eb-nat tcp2ip { 8000 } 2>/dev/null || true
nft add element eb-nat tcp2ip { 8000 : $IP }
nft delete element eb-nat tcp2port { 8000 } 2>/dev/null || true
nft add element eb-nat tcp2port { 8000 : 80 }

# ------------------------------------------------------------------------------
# INIT
# ------------------------------------------------------------------------------
[[ "$DONT_RUN_STREAM" = true ]] && exit

echo
echo "-------------------------- $MACH --------------------------"

# ------------------------------------------------------------------------------
# CONTAINER SETUP
# ------------------------------------------------------------------------------
# stop the template container if it's running
set +e
lxc-stop -n eb-trixie
lxc-wait -n eb-trixie -s STOPPED
set -e

# remove the old container if exists
set +e
lxc-stop -n $MACH
lxc-wait -n $MACH -s STOPPED
lxc-destroy -n $MACH
rm -rf /var/lib/lxc/$MACH
sleep 1
set -e

# create the new one
lxc-copy -n eb-trixie -N $MACH -p /var/lib/lxc/

# the shared directories
mkdir -p $SHARED/cache

# the container config
rm -rf $ROOTFS/var/cache/apt/archives
mkdir -p $ROOTFS/var/cache/apt/archives
rm -rf $ROOTFS/media/frames
mkdir -p $ROOTFS/media/frames

cat >> /var/lib/lxc/$MACH/config <<EOF
lxc.mount.entry = tmpfs media/frames tmpfs\
  defaults,noatime,mode=1777,size=1G 0 0

# Start options
lxc.start.auto = 1
lxc.start.order = 301
lxc.start.delay = 2
lxc.group = eb-group
lxc.group = onboot
EOF

# container network
cp $MACHINE_COMMON/etc/systemd/network/eth0.network $ROOTFS/etc/systemd/network/
sed -i "s/___IP___/$IP/" $ROOTFS/etc/systemd/network/eth0.network
sed -i "s/___GATEWAY___/$HOST/" $ROOTFS/etc/systemd/network/eth0.network

# start the container
lxc-start -n $MACH -d
lxc-wait -n $MACH -s RUNNING

# wait for the network to be up
for i in $(seq 0 9); do
    lxc-attach -n $MACH -- ping -c1 host.loc && break || true
    sleep 1
done

# ------------------------------------------------------------------------------
# HOSTNAME
# ------------------------------------------------------------------------------
lxc-attach -n $MACH -- zsh <<EOS
set -e
echo $MACH > /etc/hostname
sed -i 's/\(127.0.1.1\s*\).*$/\1$MACH/' /etc/hosts
hostname $MACH
EOS

# ------------------------------------------------------------------------------
# PACKAGES
# ------------------------------------------------------------------------------
# fake install
lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY -dy reinstall hostname
EOS

# update
lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY update
apt-get $APT_PROXY -y dist-upgrade
EOS

# packages
lxc-attach -n $MACH -- zsh <<EOS
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY -y install ffmpeg
apt-get $APT_PROXY -y install nginx libnginx-mod-rtmp
apt-get $APT_PROXY -y install xz-utils
apt-get $APT_PROXY -y install libxml-xpath-perl
EOS

# ------------------------------------------------------------------------------
# STREAM
# ------------------------------------------------------------------------------
# recordings folder
lxc-attach -n $MACH -- zsh <<EOS
set -e
mkdir -p /usr/local/eb/recordings
chown www-data: /usr/local/eb/recordings
EOS

# livestream folder
lxc-attach -n $MACH -- zsh <<EOS
set -e
mkdir -p /usr/local/eb/livestream/stat
touch /usr/local/eb/livestream/index.html
ln -s /media/frames /usr/local/eb/livestream/frames
chown www-data: /usr/local/eb/livestream -R
EOS

# rmpt_stat
lxc-attach -n $MACH -- zsh <<EOS
set -e
mkdir -p /tmp/source
chown _apt:root /tmp/source
cd /tmp/source

export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY -dy source nginx=1.24.0-1
tar xf nginx_*.debian.tar.xz

cp /tmp/source/debian/modules/rtmp/stat.xsl \
    /usr/local/eb/livestream/stat/rtmp_stat.xsl
chown www-data: /usr/local/eb/livestream/stat/rtmp_stat.xsl
EOS

# tools
cp usr/local/bin/create-frames $ROOTFS/usr/local/bin/
cp usr/local/bin/mark-frames $ROOTFS/usr/local/bin/
cp usr/local/bin/handle-recording $ROOTFS/usr/local/bin/
chmod 755 $ROOTFS/usr/local/bin/create-frames
chmod 755 $ROOTFS/usr/local/bin/mark-frames
chmod 755 $ROOTFS/usr/local/bin/handle-recording

# ------------------------------------------------------------------------------
# NGINX
# ------------------------------------------------------------------------------
cp $ROOTFS/etc/nginx/nginx.conf $ROOTFS/etc/nginx/nginx.conf.org

cp etc/nginx/access_list_http.conf $ROOTFS/etc/nginx/
cp etc/nginx/access_list_rtmp_play.conf $ROOTFS/etc/nginx/
cp etc/nginx/access_list_rtmp_publish.conf $ROOTFS/etc/nginx/

cp etc/nginx/modules-available/90-rtmp.conf \
    $ROOTFS/etc/nginx/modules-available/
ln -s ../modules-available/90-rtmp.conf $ROOTFS/etc/nginx/modules-enabled/

cp etc/nginx/sites-available/livestream.conf \
    $ROOTFS/etc/nginx/sites-available/
ln -s ../sites-available/livestream.conf $ROOTFS/etc/nginx/sites-enabled/

rm $ROOTFS/etc/nginx/sites-enabled/default
sed -i 's/^worker_processes .*$/worker_processes 1;/' \
    $ROOTFS/etc/nginx/nginx.conf

lxc-attach -n $MACH -- systemctl stop nginx.service
lxc-attach -n $MACH -- systemctl start nginx.service

# ------------------------------------------------------------------------------
# CONTAINER SERVICES
# ------------------------------------------------------------------------------
lxc-stop -n $MACH
lxc-wait -n $MACH -s STOPPED
lxc-start -n $MACH -d
lxc-wait -n $MACH -s RUNNING

# wait for the network to be up
for i in $(seq 0 9); do
    lxc-attach -n $MACH -- ping -c1 host.loc && break || true
    sleep 1
done
