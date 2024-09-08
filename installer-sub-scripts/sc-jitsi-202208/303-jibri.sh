# ------------------------------------------------------------------------------
# JIBRI.SH
# ------------------------------------------------------------------------------
set -e
source $INSTALLER/000-source

# ------------------------------------------------------------------------------
# ENVIRONMENT
# ------------------------------------------------------------------------------
MACH="eb-jibri-template"

JITSI_ROOTFS="/var/lib/lxc/eb-jitsi/rootfs"

# ------------------------------------------------------------------------------
# INIT
# ------------------------------------------------------------------------------
[[ "$DONT_RUN_JIBRI" = true ]] && exit

echo
echo "-------------------------- $MACH --------------------------"

# ------------------------------------------------------------------------------
# PROSODY
# ------------------------------------------------------------------------------
# config
cp $MACHINES/eb-jitsi/etc/prosody/conf.avail/recorder.cfg.lua \
   $JITSI_ROOTFS/etc/prosody/conf.avail/recorder.$JITSI_FQDN.cfg.lua
sed -i "s/___JITSI_FQDN___/$JITSI_FQDN/" \
    $JITSI_ROOTFS/etc/prosody/conf.avail/recorder.$JITSI_FQDN.cfg.lua
ln -fs ../conf.avail/recorder.$JITSI_FQDN.cfg.lua \
    $JITSI_ROOTFS/etc/prosody/conf.d/

lxc-attach -n eb-jitsi -- zsh <<EOS
set -e
systemctl restart prosody.service
EOS

# jibri accounts
PASSWD1=$(openssl rand -hex 20)
PASSWD2=$(openssl rand -hex 20)

lxc-attach -n eb-jitsi -- zsh <<EOS
set -e
prosodyctl unregister jibri auth.$JITSI_FQDN || true
prosodyctl register jibri auth.$JITSI_FQDN $PASSWD1

prosodyctl unregister recorder recorder.$JITSI_FQDN || true
prosodyctl register recorder recorder.$JITSI_FQDN $PASSWD2

mkdir -p /root/meta
echo $JITSI_FQDN > /root/meta/jitsi-fqdn
echo $PASSWD1 > /root/meta/jibri-passwd
echo $PASSWD2 > /root/meta/recorder-passwd
EOS

# ------------------------------------------------------------------------------
# JICOFO
# ------------------------------------------------------------------------------
lxc-attach -n eb-jitsi -- zsh <<EOS
set -e
hocon -f /etc/jitsi/jicofo/jicofo.conf \
    set jicofo.jibri.brewery-jid "\"JibriBrewery@internal.auth.$JITSI_FQDN\""
hocon -f /etc/jitsi/jicofo/jicofo.conf \
    set jicofo.jibri.pending-timeout "90 seconds"
EOS

lxc-attach -n eb-jitsi -- zsh <<EOS
set -e
systemctl restart jicofo.service
EOS

# ------------------------------------------------------------------------------
# META
# ------------------------------------------------------------------------------
# meta
lxc-attach -n eb-jitsi -- zsh <<EOS
set -e
mkdir -p /root/meta
VERSION=\$(apt-cache policy jibri | grep Candidate | rev | cut -d' ' -f1 | rev)
echo \$VERSION > /root/meta/jibri-version
EOS

# ------------------------------------------------------------------------------
# JIBRI SSH KEY
# ------------------------------------------------------------------------------
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# create ssh key if not exists
if [[ ! -f /root/.ssh/jibri ]] || [[ ! -f /root/.ssh/jibri.pub ]]; then
    rm -f /root/.ssh/jibri{,.pub}
    ssh-keygen -qP '' -t rsa -b 2048 -f /root/.ssh/jibri
fi

# copy the public key to a downloadable place
cp /root/.ssh/jibri.pub $JITSI_ROOTFS/usr/share/jitsi-meet/static/

# ------------------------------------------------------------------------------
# HOST CUSTOMIZATION FOR JIBRI
# ------------------------------------------------------------------------------
# jitsi tools
cp $MACHINES/eb-jitsi-host/usr/local/sbin/add-jibri-node.sc.202208 \
    /usr/local/sbin/add-jibri-node
chmod 744 /usr/local/sbin/add-jibri-node
cp $MACHINES/eb-jitsi-host/usr/local/sbin/add-jvb-node \
    /usr/local/sbin/add-jvb-node
chmod 744 /usr/local/sbin/add-jvb-node
