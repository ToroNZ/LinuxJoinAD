#!/bin/bash

# Check for sudo priviliges
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Check for flavor
YUM_CMD=$(which yum)
APT_GET_CMD=$(which apt-get)

# Install neccesary packages
if [[ ! -z $YUM_CMD ]]; then
	yum install -y ntp realmd samba samba-common oddjob oddjob-mkhomedir sssd ntpdate adcli
elif [[ ! -z $APT_GET_CMD ]]; then
	mkdir -p /var/lib/samba/private
	if ! $(sudo which realmd 2>/dev/null); then
    aptitude install realmd adcli sssd
	fi
 	if ! $(sudo which ntpd 2>/dev/null); then
    aptitude install ntp
	fi
else
	echo "error can't install package $PACKAGE"
	exit 1;
fi

# Configure Debian
if [[ ! -z $APT_GET_CMD ]]; then
	echo "Please enter the domain you wish to join: "
	read DOMAIN
 	echo "Please enter a domain admin login to use: "
	read ADMIN
	realm join --user=$ADMIN $DOMAIN
	if [ $? -ne 0 ]; then
		echo "AD join failed.  Please run 'journalctl -xn' to determine why."
		exit 1
	fi
	# Enable sssd service and start
	systemctl enable sssd
	systemctl start sssd
	# Set NTP to avoid clock differences with Domain Controller
	systemctl enable ntpd.service
	systemctl stop ntpd.service
	ip=$(ping -c 1 $DOMAIN | gawk -F'[()]' '/PING/{print $2}')
	ntpdate $ip
	systemctl start ntpd.service
	echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0022" | sudo tee -a /etc/pam.d/common-session
	# Configure sudo
	aptitude install libsss-sudo
	# Add Domain admins to sudoers
	realm permit --groups domain\ admins
	echo "%domain\ admins@$DOMAIN ALL=(ALL) ALL" | sudo tee -a /etc/sudoers.d/domain_admins
	# Change homedir format
	sed -i s:'fallback_homedir = /home/%u@%d':'fallback_homedir = /home/%d/%u':g /etc/sssd/sssd.conf
	# Set default domain to avoid using it on login prompt
	sed -i "/sssd/ a default_domain_suffix=$DOMAIN" /etc/sssd/sssd.conf
	# Change FQDN for usernames < ONLY if you don't setup default domain above
	#sed -i s:'use_fully_qualified_names = True':'use_fully_qualified_names = False':g /etc/sssd/sssd.conf
	# Restart sssd
	systemctl restart sssd
	# Wrap-up
	echo "The computer has joined the domain.  Suggest a reboot, ensure that you are connected to the network, and you should be able to login with domain credentials."
fi

# Configure RHEL
if [[ ! -z $YUM_CMD ]]; then
	echo "Please enter the domain you wish to join: "
	read DOMAIN
 	echo "Please enter a domain admin login to use: "
	read ADMIN
	realm join -U $ADMIN $DOMAIN
	# Enable sssd service and start
	systemctl enable sssd
	systemctl start sssd
	# Set NTP to avoid clock differences with Domain Controller
	systemctl enable ntpd.service
	systemctl stop ntpd.service
	ip=$(ping -c 1 $DOMAIN | gawk -F'[()]' '/PING/{print $2}')
	ntpdate $ip
	systemctl start ntpd.service
	# Add Domain admins to sudoers
	realm permit --groups domain\ admins
	echo "%domain\ admins@$DOMAIN ALL=(ALL) ALL" | sudo tee -a /etc/sudoers.d/domain_admins
	# Change homedir format
	sed -i s:'fallback_homedir = /home/%u@%d':'fallback_homedir = /home/%d/%u':g /etc/sssd/sssd.conf
	# Set default domain to avoid using it on login prompt
	sed -i "/sssd/ a default_domain_suffix=$DOMAIN" /etc/sssd/sssd.conf
	# Change FQDN for usernames < ONLY if you don't setup default domain above
	#sed -i s:'use_fully_qualified_names = True':'use_fully_qualified_names = False':g /etc/sssd/sssd.conf
	# Restart sssd
	systemctl restart sssd
	# Wrap-up
	echo "The computer has joined the domain.  Suggest a reboot, ensure that you are connected to the network, and you should be able to login with domain credentials."
fi
	
	
