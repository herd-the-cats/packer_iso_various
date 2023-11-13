#version RHEL 7
%pre --erroronfail --log /tmp/pre-install.log
#!/bin/bash
#----- partitioning logic below--------------
# pick the first drive that is not removable and is over MINSIZE
# minimum size of hard drive needed specified in GIGABYTES
MINSIZE=20
DIR="/sys/block"
ROOTDRIVE=""

# /sys/block/*/size is in 512 byte chunks
# 2**21 is 2 to the power of 21. 1 GiB is 2**20, so we divide
# the number of 512 byte blocks by twice one GiB

for DEV in sda sdb hda hdb vda vdb xvda xvdb; do
  if [ -d $DIR/$DEV ]; then
    REMOVABLE=$(cat $DIR/$DEV/removable)
    if (( $REMOVABLE == 0 )); then
      echo "non-removable device: $DEV"
      SIZE=$(cat $DIR/$DEV/size)
      GB=$((($SIZE) / (2**21)))
      if [ $GB -ge $MINSIZE ]; then
        echo "$DEV GiB: $(($SIZE/2**21))"
        if [ -z $ROOTDRIVE ]; then
          ROOTDRIVE=$DEV
    echo "ROOTDRIVE=$ROOTDRIVE"
        fi
      else
        echo "Disk $DEV is less than $MINSIZE GiB."
      fi
    fi
  fi
done

[[ ! -z $ROOTDRIVE ]] || { printf "ROOTDRIVE unset. Exiting.\n" ; exit 1; }
cat << EOF > /tmp/part-include
bootloader --location=mbr --boot-drive=${ROOTDRIVE} --append="net.ifnames=0 biosdevname=0 elevator=noop console=tty0 console=ttyS0,115200n8"
zerombr
ignoredisk --only-use=${ROOTDRIVE}
#specify one drive to be safe since that's all we're installing to. Principle of least surprise.
clearpart --all --drives=${ROOTDRIVE} --initlabel 
part /boot --fstype="ext4" --ondisk=${ROOTDRIVE} --size=1024
part pv.01 --ondisk=${ROOTDRIVE} --size=1 --grow
volgroup root_vg --pesize=4096 pv.01
logvol / --name="root_lv" --fstype="xfs" --grow --percent=40 --vgname=root_vg
logvol /home --name="home_lv" --fstype="xfs" --grow --percent=20 --vgname=root_vg
logvol swap --name="swap_lv" --fstype="swap" --size=4096 --vgname=root_vg
logvol /tmp --name="tmp_lv" --fstype="xfs" --size=2000 --vgname=root_vg --fsoptions=noexec,nosuid,nodev
logvol /var --name="var_lv" --fstype="xfs" --grow --percent=40 --vgname=root_vg --fsoptions=noexec,nosuid,nodev

EOF

#----- parsing packer variables from boot command line -----
boot_params="$(< /proc/cmdline)"
read -ra split_params <<<"$boot_params"
for param in "${split_params[@]}"; do
  case "$param" in
    packer_ks_rootpw=*)    
      export PACKER_ROOTPW="${param#*=}"
    ;;
    *)
      printf "DEBUG: Unused parameter: %s\n" "$param"
    ;;
  esac
done

if [[ ! -z PACKER_ROOTPW ]]; then
  printf "rootpw --iscrypted %s\n" "$PACKER_ROOTPW" > /tmp/rootpw-include
else
#Putting in a randomized password here if not specified
  python - << 'PYTHON_EOF' > /tmp/rootpw-include
from __future__ import print_function
import os
import crypt
import random
import string
print("rootpw --iscrypted " + crypt.crypt(''.join([random.choice(string.ascii_letters + string.digits) for _ in range(16)]), '$6$rounds=5000$' + ''.join([random.SystemRandom().choice(string.ascii_letters + string.digits) for _ in range(16)])))
PYTHON_EOF
fi

%end

install
cdrom
unsupported_hardware
eula --agreed
cmdline
auth --enableshadow --passalgo=sha512
firewall --disable
firstboot --disable
keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
logging --level=debug
network  --onboot yes --bootproto=dhcp --device=eth0 --noipv6
network  --hostname=localhost.localdomain
selinux --enforcing
services --enabled="sshd"
skipx
timezone America/Chicago --isUtc
reboot

%include /tmp/part-include
%include /tmp/rootpw-include


%packages
@core
cloud-utils-growpart
nfs-utils
bind-utils
curl
deltarpm
gcc
git
net-snmp
net-tools
openssh-clients
openssh-server
strace
vim-enhanced
ntpdate
setools-console
policycoreutils-python
screen
tmux
sudo
psmisc
tree
-wpa_supplicant
-aic*
-b43*
-ipw*
-iwl*
-ql*
-rt73*
-wireless-tools*
-biosdevname
%end


%post --log /root/post-install.log

cat >> /root/pre-install.log << "EOF"
%include /tmp/pre-install.log
EOF

#Enable TRIM for LVM by default and regenerate initramfs to include the change.
/bin/sed -i.bak 's/issue_discards = 0/issue_discards = 1/g' /etc/lvm/lvm.conf
dracut -f
%end


