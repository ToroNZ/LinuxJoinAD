#!/bin/bash

# Check for sudo priviliges
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Check for flavor
YUM_CMD=$(which yum)
APT_GET_CMD=$(which apt-get)
H=$(hostname)

# Install neccesary packages
if [[ ! -z $YUM_CMD ]]; then
	echo "Current hostname is $H make sure you set a FQDN [Press ENTER to continue]"
	read KEY
	yum install -y ntp realmd samba samba-common oddjob oddjob-mkhomedir sssd ntpdate adcli samba-common-tools
elif [[ ! -z $APT_GET_CMD ]]; then
	echo "Current hostname is $H make sure you set a FQDN [Press ENTER to continue]"
	read KEY
	mkdir -p /var/lib/samba/private
	if ! $(sudo which realmd 2>/dev/null); then
		sudo DEBIAN_FRONTEND=noninteractive apt-get -y install krb5-user
    		aptitude install -y samba sssd
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
	echo "Please enter a domain controller FQDN to use: "
	read DCFQDN
	echo "Please enter second domain controller FQDN to use [leave blank if not]: "
	read DCFQDN2
	if [ -z "$DCFQDN2" ]; then
		echo "Proceeding using only 1 DC"
	fi
	DOMAINS=$(echo $DOMAIN | cut -d. -f 1)
	service ntp stop
	ip=$(ping -c 1 $DOMAIN | gawk -F'[()]' '/PING/{print $2}')
	sed -i "/join.html/ a server $ip" /etc/ntp.conf
	service ntp start
	
	truncate -s0 /etc/krb5.conf
	cat <<EOF >> /etc/krb5.conf
	[libdefaults]
	ticket_lifetime = 24000
	default_realm = "${DOMAIN^^}"
	default_tgs_entypes = rc4-hmac des-cbc-md5
	default_tkt__enctypes = rc4-hmac des-cbc-md5
	permitted_enctypes = rc4-hmac des-cbc-md5
	dns_lookup_realm = true
	dns_lookup_kdc = true
	dns_fallback = yes
	 
	[realms]
	"${DOMAIN^^}" = {
	  kdc = "${DCFQDN,,}"
	  kdc = "${DCFQDN2,,}"
	  default_domain = "${DCFQDN,,}"
	}
	 
	[domain_realm]
	."${DOMAIN,,}"= "${DCFQDN^^}"
	"${DOMAIN,,}" = "${DCFQDN^^}"
	 
	[appdefaults]
	pam = {
	   debug = false
	   ticket_lifetime = 24h
	   renew_lifetime = 7d
	   forwardable = true
	   krb4_convert = false
	}
	 
	[logging]
	default = FILE:/var/log/krb5libs.log
	kdc = FILE:/var/log/krb5kdc.log
	admin_server = FILE:/var/log/kadmind.log
	<<-EOF
	sed -i "/[global]/ a workgroup = ${DOMAINS^^} \\
	client signing = yes \\
	client use spnego = yes \\
	kerberos method = secrets and keytab \\
	realm = ${DOMAIN^^} \\
	security = ads" /etc/samba/smb.conf
	cat << EOF > /etc/sssd/sssd.conf
	[sssd]
	services = nss, pam
	config_file_version = 2
	domains="${DOMAIN^^}"
	default_domain_suffix="${DOMAIN^^}"
	[domain/"${DOMAIN^^}"]
	id_provider = ad
	access_provider = ad
	cache_credentials = True
	krb5_store_password_if_offline = True
	default_shell = /bin/bash
	ldap_id_mapping = True
	use_fully_qualified_names = True
	override_homedir = /home/%d/%u
	fallback_homedir = /home/%d/%u
	access_provider = simple
	# Uncomment if the client machine hostname doesn't match the computer object on the DC
	# ad_hostname = mymachine.myubuntu.example.com
	# Uncomment if DNS SRV resolution is not working
	# ad_server = dc.mydomain.example.com
	# Uncomment if the AD domain is named differently than the Samba domain
	# ad_domain = "${DOMAIN^^}"
	# Enumeration is discouraged for performance reasons.
	# enumerate = true
	EOF
	chown root:root /etc/sssd/sssd.conf
	chmod 600 /etc/sssd/sssd.conf
	systemctl restart ntp.service
	systemctl restart smbd.service nmbd.service 
	systemctl start sssd.service
	kinit $ADMIN
	klist
	net ads join -k
	su - $ADMIN
	# Create home dir at login
	echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0022" | sudo tee -a /etc/pam.d/common-session
	# Configure sudo
	aptitude install libsss-sudo
	# Add Domain admins to sudoers
	#realm permit --groups domain\ admins
	echo "%domain\ admins@$DOMAIN ALL=(ALL) ALL" | sudo tee -a /etc/sudoers.d/domain_admins
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
  sed -i "[sssd]/a full_name_format = %1$s" /etc/sssd/sssd.conf
	# Set default domain to avoid using it on login prompt
	sed -i "/sssd/ a default_domain_suffix=$DOMAIN" /etc/sssd/sssd.conf
	# Change FQDN for usernames < ONLY if you don't setup default domain above
	#sed -i s:'use_fully_qualified_names = True':'use_fully_qualified_names = False':g /etc/sssd/sssd.conf
	# Restart sssd
	systemctl restart sssd
	# Wrap-up
	echo "The computer has joined the domain.  Suggest a reboot, ensure that you are connected to the network, and you should be able to login with domain credentials."
fi
