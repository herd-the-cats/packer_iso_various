#version Fedora 38 single disk LVM on LUKS
%pre --erroronfail --log /tmp/pre-install.log
#!/bin/bash
KS_PACKER=0
KS_INTERACTIVE=0
KS_AUTO=1
KS_HTTP=0
block_devs=""
block_devs_avail=""
affirm_regex='^[yY]([eE][sS])?$'
virt_status="$(virt-what)" || virt_status=""

# Creating a basic ramdisk because of the slight risk of tmpfs using swap, potentially exposing sensitive params like passwords
mount ramfs -t ramfs /tmp2

# Parse boot command line to determine whether this kickstart is via Packer, text interactive, or non-interactive
boot_params="$(< /proc/cmdline)"
read -ra split_params <<<"$boot_params"
for param in "${split_params[@]}"; do
  case "$param" in
    ks_type=[Pp]acker)    
      export KS_PACKER=1
      export KS_AUTO=0
    ;;
    ks_type=[Ii]nteractive)
      export KS_INTERACTIVE=1
      export KS_AUTO=0
    ;;
    inst.ks=http*)
      export KS_LOCATION="${param#*=}"
      export KS_HTTP=1
    ;;
    inst.ks=hd*)
      export KS_LOCATION="${param#*=}"
    ;;
    inst.ks=cdrom*)
      export KS_LOCATION="${param#*=}"
    ;;
    *)
      printf "DEBUG: Unused parameter: %s\n" "$param"
    ;;
  esac
done

block_devs="$(lsblk -dnlo NAME,TYPE,RM,RO,MOUNTPOINT)" || \
  { echo "Unable to run lsblk for disk devices" ; exit 1 ; }
block_devs_avail="$(printf "%s\n" "$block_devs" | awk '$2 != "disk" {next} ; $3 != "0" {next} ; $4 != "0" {next} ; NF > 4 && $5 ~ /SWAP/ {next} ; {print}')" || \
  { echo "Unable to parse lsblk output" ; exit 1 ; }

declare -A avail_disks
declare -A avail_disks_deps
for bdev in $(echo "$block_devs_avail" | awk '{print $1}') ; do
  avail_disks["$bdev"]="$(lsblk -dnlo NAME,SIZE,MAJ:MIN,MODEL /dev/$bdev)"
  avail_disks_deps["$bdev"]="$(lsblk -nlo NAME,SIZE,FSTYPE,MAJ:MIN,MODEL,SERIAL,WWN /dev/$bdev)"
done


[[ -n "$KS_LOCATION" ]] || echo "Error gathering kickstart url/path from boot command."
KS_DIR="${KS_LOCATION%/*}"
[[ -n "$KS_DIR" ]] || echo "Something went wrong getting the kickstart parent directory."

if [[ "$KS_PACKER" -eq 1 ]] ; then
  if [[ "$KS_HTTP" -eq 1 ]] ; then
    wget -q -O /tmp2/part-include.ks "${KS_DIR}/part-include.ks"
    wget -q -O /tmp2/auth-include.ks "${KS_DIR}/auth-include.ks"
    wget -q -O /tmp2/net-include.ks "${KS_DIR}/net-include.ks"
    wget -q -O /tmp2/tz-include.ks "${KS_DIR}/tz-include.ks"
    wget -q -O /tmp2/boot-include.ks "${KS_DIR}/boot-include.ks"
  else
# This latter will only work if using a direct files option like cdrom files with Packer
    cp -v "${KS_DIR}/part-include.ks" /tmp2/part-include.ks
    cp -v "${KS_DIR}/auth-include.ks" /tmp2/auth-include.ks
    cp -v "${KS_DIR}/net-include.ks" /tmp2/net-include.ks
    cp -v "${KS_DIR}/tz-include.ks" /tmp2/tz-include.ks
    cp -v "${KS_DIR}/boot-include.ks" /tmp2/boot-include.ks
  fi
fi

if [[ "$KS_INTERACTIVE" -eq 1 ]] ; then
  exec < /dev/tty6 > /dev/tty6 2> /dev/tty6
  chvt 6
  
# Choosing install disk
  echo "Listing available disks."
  for iter in ${!avail_disks[@]} ; do
    printf "%s\n" "${avail_disks[$iter]}"
  done
  read -p "Show partition and filesystem detail for available disks?(y/n)" DISK_DETAIL
  if [[ "$DISK_DETAIL" =~ $affirm_regex ]] ; then
    for iter in ${!avail_disks_deps[@]} ; do
      printf "%s\n" "${avail_disks_deps[$iter]}"
    done
  fi
  ROOTDISK="not_a_disk"
  while [[ -z ${avail_disks[$ROOTDISK]} ]] ; do
    read -p "Select single disk to format for Fedora install (example: sda, vda, nvme0n1):" ROOTDISK
    [[ -z "${avail_disks[$ROOTDISK]}" ]] && echo "Invalid disk selected."
  done
  ROOTDISK_WIPE=0
  if [[ "$(ls -lah /sys/block/$ROOTDISK/$ROOTDISK*/partition | wc -l)" -gt 0 ]] ; then
    read -p "Existing partitions detected on $ROOTDISK. Ok to wipe partitions and continue? [y/n]" WIPE_ANSWER
    [[ "$WIPE_ANSWER" =~ $affirm_regex ]] && export ROOTDISK_WIPE=1
    if [[ "$ROOTDISK_WIPE" -eq 0 ]] ; then
      echo "Bailing out of kickstart without overwriting partitions on /dev/$ROOTDISK."
      exit 1
    fi
  fi
  rootdisk_size="$(echo "${avail_disks[$ROOTDISK]}" | awk '{gsub(/\.[0-9]G/, "", $2) ; print $2}')"
  if [[ "$rootdisk_size" =~ [0-9]+ && "$rootdisk_size" -gt 800 ]] ; then
    pcnt_div=2
  else
    pcnt_div=1
  fi
# Choosing default network device
  echo "Listing available non-virtual network interfaces"
  find /sys/class/net -type l ! -lname '*virtual*' -printf '%f\n'
  read -p "Select default network device." DEFAULT_NETDEV
# Choosing LUKS password
  LUKSPASS1=""
  LUKSMATCH=0
  while [[ -z "$LUKSPASS1" || "$LUKSMATCH" -eq 0 ]] ; do
    read -p -s "Please enter LUKS password." LUKSPASS1
    read -p -s "Please re-enter LUKS password." LUKSPASS2
    if [[ "$LUKSPASS1" == "$LUKSPASS2" ]] ; then
      LUKSMATCH=1
    else
      echo "LUKS passwords do not match."
    fi
  done
# Choosing root password
  ROOTPASS1=""
  ROOTPMATCH=0
  while [[ -z "$ROOTPASS1" || "$ROOTPMATCH" -eq 0 ]] ; do
    read -p -s "Please enter root password." ROOTPASS1
    read -p -s "Please re-enter root password." ROOTPASS2
    if [[ "$ROOTPASS1" == "$ROOTPASS2" ]] ; then
      ROOTPMATCH=1
    else
      echo "Root passwords do not match."
    fi
  done
# Choosing user name
  read -p "Please enter a name for a primary user account:" USERNAME
# Choosing user password
  USERPASS1=""
  USERPMATCH=0
  while [[ -z "$USERPASS1" || "$USERPMATCH" -eq 0 ]] ; do
    read -p -s "Please enter user password." USERPASS1
    read -p -s "Please re-enter user password." USERPASS2
    if [[ "$USERPASS1" == "$USERPASS2" ]] ; then
      USERPMATCH=1
    else
      echo "User passwords do not match."
    fi
  done
# Choosing hostname
  read -p "Please enter hostname.(leave blank to use localhost.localdomain)" KSHOSTNAME
  if [[ "$KSHOSTNAME" == "" ]] ; then
    KSHOSTNAME="localhost.localdomain"
  fi
# Choosing timezone
  read -p "Show available timezones?(y/n)" TZ_DETAIL
  if [[ "$TZ_DETAIL" =~ $affirm_regex ]] ; then
    timedatectl list-timezones | more
  fi
  read -p "Please enter timezone (leave blank to use UTC)" KSTZ
  if [[ "$KSTZ" == "" ]] ; then
    KSTZ="UTC"
  fi


  cat >> /tmp2/part-include.ks <<EOPARTITIONS
  clearpart --drives="$ROOTDISK" --all --disklabel=gpt
  part pv.01 --fstype="lvmpv" --ondisk="$ROOTDISK" --size=20000 --grow --encrypted --luks-version=luks2 --pbkdf=argon2id --passphrase="$LUKSPASS1"
  part /boot/efi --fstype="efi" --ondisk="$ROOTDISK" --size=1000 --fsoptions="umask=0077,shortname=winnt"
  volgroup vgfedora --pesize=4096 pv.01
  logvol / --fstype="xfs" --size=6000 --grow --percent=$((8 / pcnt_div)) --vgname=vgfedora --name="lv_root" --label="/"
  logvol /var --fstype="xfs" --size=4000 --grow --percent=$((6 / pcnt_div)) --vgname=vgfedora --name="lv_var" --label="/var"
  logvol /var/log --fstype="xfs" --size=2000 --vgname=vgfedora --name="lv_var_log" --label="/var/log"
  logvol /var/log/audit --fstype="xfs" --size=1000 --vgname=vgfedora --name="lv_var_log_audit" --label="/var/log/audit"
  logvol /var/tmp --fstype="xfs" --size=2000 --vgname=vgfedora --name="lv_var_tmp" --label="/var/tmp"
  logvol /home --fstype="xfs" --size=3000 --grow --percent=$((20 / pcnt_div)) --vgname=vgfedora --name="lv_home" --label="/home"

EOPARTITIONS

  export ROOTPASS1
  export USERNAME
  export USERPASS1
  python - <<'PYTHON_EOF1' > /tmp2/auth-include.ks
from __future__ import print_function
import os
import crypt
import random
import string

rootpass = os.getenv('ROOTPASS1')
username = os.getenv('USERNAME')
userpass = os.getenv('USERPASS1')

def random_salt_string(length, rounds=None):
  if rounds is None:
    rounds = 5000
  prefix = '$6$rounds=' + rounds + '$'
  salt_str = ''.join([random.choice(string.ascii_letters + string.digits + '.' + '/') for _ in range(length)])
  result = prefix + salt_str
  return result

rootsalt = random_salt_string(15)
usersalt = random_salt_string(15)

print("rootpw --iscrypted " + crypt.crypt(rootpass, rootsalt))
print("user --name=" + username + " --password=" + crypt.crypt(userpass, usersalt) + " --iscrypted --groups=wheel")
PYTHON_EOF1

  if [[ -n "$virt_status" ]] ; then
    append_line="--append=\"console=tty0 console=ttyS0,115200n8\""
  else
    append_line=""
  fi

  cat >> /tmp2/boot-include.ks <<EOBOOT
  bootloader --location=partition --boot-drive=$ROOTDISK "$append_line"
EOBOOT

  cat >> /tmp2/net-include.ks <<EONET
  network  --onboot yes --bootproto=dhcp --device="$DEFAULT_NETDEV" --noipv6 --hostname="$KSHOSTNAME"
EONET

  cat >> /tmp2/tz-include.ks <<EOTZ
  timezone "$KSTZ" --utc
EOTZ

  chvt 1
  exec < /dev/tty1 > /dev/tty1 2> /dev/tty1
fi


if [[ "$KS_AUTO" -eq 1 ]] ; then
  echo '1' > /tmp/.ks_auto

# Determining the best disk to use automatically
  ROOTDISK="not_a_disk"
  for preferred in nvme0n1 sda vda ; do
    for iter in ${!avail_disks[@]} ; do
      if [[ "$iter" =~ $preferred ]] ; then
        ROOTDISK="$iter"
        break
      fi
    done
    if [[ -n ${avail_disks[$ROOTDISK]} ]] ; then
      break
    fi
  done
  [[ -z ${avail_disks[$ROOTDISK]} ]] && { echo "No suitable disk found. Tried nvme0n1, sda, vda." ; exit 1 ; }
  rootdisk_size="$(echo "${avail_disks[$ROOTDISK]}" | awk '{gsub(/\.[0-9]G/, "", $2) ; print $2}')"
  if [[ "$rootdisk_size" =~ [0-9]+ && "$rootdisk_size" -gt 800 ]] ; then
    pcnt_div=2
  else
    pcnt_div=1
  fi

  LUKSPASS1="$(python - << 'PYTHON_EOF2'
from __future__ import print_function
import os
import random
import string

def random_pass_string(length):
  result = ''.join([random.choice(string.ascii_letters + string.digits + string.punctuation) for _ in range(length)])
  return result

lukspass = random_pass_string(15)
luks_post = os_open('/tmp2/luks-plain','w')
luks_post.write(lukspass + '\n')
luks_post.close()

print(lukspass)
PYTHON_EOF2
)"

  cat >> /tmp2/part-include.ks <<EOPARTITIONS2
  clearpart --drives="$ROOTDISK" --all --disklabel=gpt
  part pv.01 --fstype="lvmpv" --ondisk="$ROOTDISK" --size=20000 --grow --encrypted --luks-version=luks2 --pbkdf=argon2id --passphrase="$LUKSPASS1"
  part /boot/efi --fstype="efi" --ondisk="$ROOTDISK" --size=1000 --fsoptions="umask=0077,shortname=winnt"
  volgroup vgfedora --pesize=4096 pv.01
  logvol / --fstype="xfs" --size=6000 --grow --percent=$((8 / pcnt_div)) --vgname=vgfedora --name="lv_root" --label="/"
  logvol /var --fstype="xfs" --size=4000 --grow --percent=$((6 / pcnt_div)) --vgname=vgfedora --name="lv_var" --label="/var"
  logvol /var/log --fstype="xfs" --size=2000 --vgname=vgfedora --name="lv_var_log" --label="/var/log"
  logvol /var/log/audit --fstype="xfs" --size=1000 --vgname=vgfedora --name="lv_var_log_audit" --label="/var/log/audit"
  logvol /var/tmp --fstype="xfs" --size=2000 --vgname=vgfedora --name="lv_var_tmp" --label="/var/tmp"
  logvol /home --fstype="xfs" --size=3000 --grow --percent=$((20 / pcnt_div)) --vgname=vgfedora --name="lv_home" --label="/home"

EOPARTITIONS2

#Putting in a randomized password here, saving the crypted version to include and plaintext to echo in post section
  python - << 'PYTHON_EOF3' > /tmp2/auth-include.ks
from __future__ import print_function
import os
import crypt
import random
import string

def random_pass_string(length):
  result = ''.join([random.choice(string.ascii_letters + string.digits + string.punctuation) for _ in range(length)])
  return result

# Salts can't have most punctuation characters
def random_salt_string(length, rounds=None):
  if rounds is None:
    rounds = 5000
  prefix = '$6$rounds=' + rounds + '$'
  salt_str = ''.join([random.choice(string.ascii_letters + string.digits + '.' + '/') for _ in range(length)])
  result = prefix + salt_str
  return result

rootpass = random_pass_string(15)
rootsalt = random_salt_string(15)
username = 'fedorauser'
userpass = random_pass_string(15)
usersalt = random_salt_string(15)

plain_output = os.open('/tmp2/auth-plain','w')

plain_output.write( 'root: ' + rootpass + '\n' )
plain_output.write( username + ': ' + userpass + '\n' )

plain_output.close()
 
print("rootpw --iscrypted " + crypt.crypt(rootpass, rootsalt))
print("user --name=" + username + " --password=" + crypt.crypt(userpass, usersalt) + " --iscrypted --groups=wheel")
PYTHON_EOF3

  if [[ -n "$virt_status" ]] ; then
    append_line="--append=\"console=tty0 console=ttyS0,115200n8\""
  else
    append_line=""
  fi

  cat >> /tmp2/boot-include.ks <<EOBOOT2
  bootloader --location=partition --boot-drive=$ROOTDISK "$append_line"
EOBOOT2

  DEFAULT_NETDEV=""
# Determine default netdev
  netdev_list="$(find /sys/class/net -type l ! -lname '*virtual*' -printf '%f\n')"
  for preferred_netdev in eno ens enp ; do
    for iter in $netdev_list ; do
      if [[ "$iter" == "$preferred_netdev"* ]] ; then
        DEFAULT_NETDEV="$iter"
        break
      fi
    done
    if [[ -n $DEFAULT_NETDEV ]] ; then
      break
    fi
  done
  [[ -z $DEFAULT_NETDEV ]] && { echo "No suitable ethernet device found. Tried eno*, ens*, enp*." ; exit 1 ; }
  KSHOSTNAME="localhost.localdomain"

  cat >> /tmp2/net-include.ks <<EONET2
  network  --onboot yes --bootproto=dhcp --device="$DEFAULT_NETDEV" --noipv6 --hostname="$KSHOSTNAME"
EONET2


  KSTZ="UTC"

  cat >> /tmp2/tz-include.ks <<EOTZ2
  timezone "$KSTZ" --utc
EOTZ2
fi

%end

install
url --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-38&arch=x86_64"
repo --name=fedora-updates --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f38&arch=x86_64" --cost=0
repo --name=rpmfusion-free --mirrorlist="https://mirrors.rpmfusion.org/mirrorlist?repo=free-fedora-38&arch=x86_64"
repo --name=rpmfusion-free-updates --mirrorlist="https://mirrors.rpmfusion.org/mirrorlist?repo=free-fedora-updates-released-38&arch=x86_64" --cost=0
repo --name=rpmfusion-nonfree --mirrorlist="https://mirrors.rpmfusion.org/mirrorlist?repo=nonfree-fedora-38&arch=x86_64"
repo --name=rpmfusion-nonfree-updates --mirrorlist="https://mirrors.rpmfusion.org/mirrorlist?repo=nonfree-fedora-updates-released-38&arch=x86_64" --cost=0
unsupported_hardware
eula --agreed
text
auth --enableshadow --passalgo=sha512
firewall --enable --ssh
firstboot --disable
keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
logging --level=debug
selinux --enforcing
services --enabled="sshd,tmp.mount"
xconfig --startxonboot

%include /tmp2/part-include.ks
%include /tmp2/auth-include.ks
%include /tmp2/boot-include.ks
%include /tmp2/net-include.ks
%include /tmp2/tz-include.ks
reboot


%packages
@core
@"Cinnamon Desktop"
@firefox
@"Development Tools"
@multimedia
@networkmanager-submodules
zram-generator
cloud-utils-growpart
nfs-utils
bind-utils
curl
deltarpm
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
%end

%post --nochroot
if [[ "$(cat /tmp/.ks_auto)" -eq 1 ]] ; then
  exec < /dev/tty6 > /dev/tty6 2> /dev/tty6
  chvt 6
  echo "Automatically generated LUKS password displaying for 60 seconds!"
  cat /tmp2/luks-plain
  sleep 60
  echo "Automatically generated root password displaying for 60 seconds!"
  head 1 /tmp2/auth-plain
  sleep 60
  echo "Automatically generated user password displaying for 60 seconds!"
  head -1 /tmp2/auth-plain
  sleep 60
  chvt 1
  exec < /dev/tty1 > /dev/tty1 2> /dev/tty1
fi

%end

%post --log /root/post-install.log

cat >> /root/pre-install.log <<'EOF'
%include /tmp/pre-install.log
EOF

if [[ -z "$virt_status" ]] ; then
    dnf install @"Hardware Support" @"Printing Support"
fi
#TODO Performance tweaks? vm.swappiness etc.

#Enable TRIM for LVM by default and regenerate initramfs to include the change.
/bin/sed -i.bak 's/issue_discards = 0/issue_discards = 1/g' /etc/lvm/lvm.conf
dracut -f
%end


