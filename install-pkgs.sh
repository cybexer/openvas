#!/bin/bash

apt-get update
apt-get install software-properties-common -yq --no-install-recommends  && \
add-apt-repository ppa:deadsnakes/ppa && \
apt-get install python3.8 -yq --no-install-recommends
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.8 1


{ cat <<EOF
bison
build-essential
ca-certificates
gpg-agent
cmake
curl
gcc
gcc-mingw-w64
geoip-database
gnutls-bin
graphviz
heimdal-dev
ike-scan
libgcrypt20-dev
libglib2.0-dev
libgnutls28-dev
libgpgme11-dev
libgpgme-dev
libhiredis-dev
libical2-dev
libksba-dev
libmicrohttpd-dev
libnet-snmp-perl
libpcap-dev
libpopt-dev
libsnmp-dev
libssh-gcrypt-dev
libxml2-dev
net-tools
nmap
nsis
openssh-client
python3-pip
python3.8-dev
perl-base
pkg-config
postgresql
postgresql-contrib
postgresql-server-dev-all
redis-server
redis-tools
rsync
smbclient
software-properties-common
texlive-fonts-recommended
texlive-latex-extra
uuid-dev
wapiti
wget
xsltproc
EOF
} | xargs apt-get install -yq --no-install-recommends

# Install python modules
python3.8 -m pip install defusedxml
python3.8 -m pip install dialog
python3.8 -m pip install lxml
python3.8 -m pip install paramiko
python3.8 -m pip install polib
python3.8 -m pip install psutil
python3.8 -m pip install setuptools
python3.8 -m pip install distutils

# Install Node.js
curl -sL https://deb.nodesource.com/setup_10.x | bash -
apt-get install nodejs -yq --no-install-recommends


# Install Yarn
curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list
apt-get update && apt-get install yarn -yq --no-install-recommends && yarn install && yarn upgrade caniuse-lite browserlist


rm -rf /var/lib/apt/lists/*
