#!/usr/bin/env bash
set -Eeuo pipefail

USERNAME=${USERNAME:-admin}
PASSWORD=${PASSWORD:-admin}
RELAYHOST=${RELAYHOST:-172.17.0.1}
SMTPPORT=${SMTPPORT:-25}
REDISDBS=${REDISDBS:-512}
QUIET=${QUIET:-false}



if [ ! -d "/run/redis" ]; then
	mkdir /run/redis
fi
if  [ -S /run/redis/redis.sock ]; then
        rm /run/redis/redis.sock
fi
# Does redis need to be bound to 0.0.0.0 or will it work with just local host?
redis-server --unixsocket /run/redis/redis.sock --unixsocketperm 700 \
             --timeout 0 --databases $REDISDBS --maxclients 10000 --daemonize yes \
             --port 6379 --bind 0.0.0.0 --logfile /var/log/redis/redis-server.log --loglevel notice

echo "Wait for redis socket to be created..."
while  [ ! -S /run/redis/redis.sock ]; do
        sleep 1
done

echo "Testing redis status..."
X="$(redis-cli -s /run/redis/redis.sock ping)"
while  [ "${X}" != "PONG" ]; do
        echo "Redis not yet ready..."
        sleep 1
        X="$(redis-cli -s /run/redis/redis.sock ping)"
done
echo "Redis ready."

# This is for a first run with no existing database.
if  [ ! -d /data/database ]; then
	echo "Creating Data and database folder..."
	mv /var/lib/postgresql/12/main /data/database
	ln -s /data/database /var/lib/postgresql/12/main
	chown postgres:postgres -R /var/lib/postgresql/12/main
	chown postgres:postgres -R /data/database
fi

# These are  needed for a first run WITH a new container image
# and an existing database in the mounted volume at /data

if [ ! -L /var/lib/postgresql/12/main ]; then
	echo "Fixing Database folder..."
	rm -rf /var/lib/postgresql/12/main
	ln -s /data/database /var/lib/postgresql/12/main
	chown postgres:postgres -R /var/lib/postgresql/12/main
	chown postgres:postgres -R /data/database
fi

if [ ! -L /usr/local/var/lib  ]; then
	echo "Fixing local/var/lib ... "
	if [ ! -d /data/var-lib ]; then
		mkdir /data/var-lib
	fi
	cp -rf /usr/local/var/lib/* /data/var-lib
	rm -rf /usr/local/var/lib
	ln -s /data/var-lib /usr/local/var/lib
fi
if [ ! -L /usr/local/share ]; then
	echo "Fixing local/share ... "
	if [ ! -d /data/local-share ]; then mkdir /data/local-share; fi
	cp -rf /usr/local/share/* /data/local-share/
	rm -rf /usr/local/share 
	ln -s /data/local-share /usr/local/share 
fi

# Postgres config should be tighter.
# Actually, postgress should be in its own container!
# maybe redis should too. 
if [ ! -f "/setup" ]; then
	echo "Creating postgresql.conf and pg_hba.conf"
	# Need to look at restricting this. Maybe to localhost ?
	echo "listen_addresses = '*'" >> /data/database/postgresql.conf
	echo "port = 5432" >> /data/database/postgresql.conf
	# This probably tooooo open.
	echo -e "host\tall\tall\t0.0.0.0/0\ttrust" >> /data/database/pg_hba.conf
	echo -e "host\tall\tall\t::0/0\ttrust" >> /data/database/pg_hba.conf
	echo -e "local\tall\tall\ttrust"  >> /data/database/pg_hba.conf
fi

echo "Starting PostgreSQL..."
su -c "/usr/lib/postgresql/12/bin/pg_ctl -D /data/database start" postgres


if [ ! -f "/setup" ]; then
	echo "Running first start configuration..."
	useradd --home-dir /usr/local/share/gvm gvm
	chown gvm:gvm -R /usr/local/share/gvm
	if [ ! -d /usr/local/var/lib/gvm/cert-data ]; then 
		mkdir -p /usr/local/var/lib/gvm/cert-data; 
	fi


fi
if [ ! -f "/data/setup" ]; then
	echo "Creating Greenbone Vulnerability Manager database"
	su -c "createuser -DRS gvm" postgres
	su -c "createdb -O gvm gvmd" postgres
	su -c "psql --dbname=gvmd --command='create role dba with superuser noinherit;'" postgres
	su -c "psql --dbname=gvmd --command='grant dba to gvm;'" postgres
	su -c "psql --dbname=gvmd --command='create extension \"uuid-ossp\";'" postgres
	su -c "psql --dbname=gvmd --command='create extension \"pgcrypto\";'" postgres
	chown postgres:postgres -R /data/database
	su -c "/usr/lib/postgresql/12/bin/pg_ctl -D /data/database restart" postgres
	if [ ! -f /data/var-lib/gvm/CA/servercert.pem ]; then
		echo "Generating certs..."
    	gvm-manage-certs -a
	fi
	touch /data/setup
fi

# Always make sure these are right.

chown gvm:gvm -R /usr/local/var/lib/gvm
chmod 770 -R /usr/local/var/lib/gvm
chmod 770 -R /usr/local/var/lib/openvas
chown gvm:gvm -R /usr/local/var/lib/openvas
chown gvm:gvm -R /usr/local/var/log/gvm
chown gvm:gvm -R /usr/local/var/run	

if [ -d /usr/local/var/lib/gvm/data-objects/gvmd/20.08/report_formats ]; then
	echo "Creating dir structure for feed sync"
	for dir in configs port_lists report_formats; do 
		su -c "mkdir -p /usr/local/var/lib/gvm/data-objects/gvmd/20.08/${dir}" gvm
	done
fi

# Migrate to new db version just in case
su -c "gvmd --migrate" gvm

echo "Updating NVTs and other data"
echo "This could take a while if you are not using persistent storage for your NVTs"
echo " or this is the first time pulling to your persistent storage."
echo " the time will be mostly dependent on your available bandwidth."
echo " We sleep for 5 seconds between sync command to make sure everything closes"
echo " and it doesnt' look like we are connecting more than once."
# Fix perms on var/run for the sync to function
chmod 777 /usr/local/var/run/
# And it should be empty. (Thanks felimwhiteley )
if [ -f /usr/local/var/run/feed-update.lock ]; then
        # If NVT updater crashes it does not clear this up without intervention
        echo "Removing feed-update.lock"
	rm /usr/local/var/run/feed-update.lock
fi

# This will make the feed syncs a little quieter
if [ $QUIET == "TRUE" ] || [ $QUIET == "true" ]; then
	QUIET="true"
	echo " Fine, ... we'll be quiet, but we warn you if there are errors"
	echo " syncing the feeds, you'll miss them."
else
	QUIET="false"
fi

if [ $QUIET == "true" ]; then 
	echo " Pulling NVTs from greenbone" 
	su -c "/usr/local/bin/greenbone-nvt-sync" gvm 2&> /dev/null
	sleep 2
	echo " Pulling scapdata from greenbone"
	su -c "/usr/local/sbin/greenbone-scapdata-sync" gvm 2&> /dev/null
	sleep 2
	echo " Pulling cert-data from greenbone"
	su -c "/usr/local/sbin/greenbone-certdata-sync" gvm 2&> /dev/null
	sleep 2
	echo " Pulling latest GVMD Data from greenbone" 
	su -c "/usr/local/sbin/greenbone-feed-sync --type GVMD_DATA " gvm 2&> /dev/null

else
	echo " Pulling NVTs from greenbone" 
	su -c "/usr/local/bin/greenbone-nvt-sync" gvm
	sleep 2
	echo " Pulling scapdata from greenboon"
	su -c "/usr/local/sbin/greenbone-scapdata-sync" gvm
	sleep 2
	echo " Pulling cert-data from greenbone"
	su -c "/usr/local/sbin/greenbone-certdata-sync" gvm
	sleep 2
	echo " Pulling latest GVMD Data from Greenbone" 
	su -c "/usr/local/sbin/greenbone-feed-sync --type GVMD_DATA " gvm

fi

echo "Starting Greenbone Vulnerability Manager..."
su -c "gvmd --osp-vt-update=/tmp/ospd.sock --max-ips-per-target 70000 --listen=0.0.0.0 -p 9390" gvm

until su -c "gvmd --get-users" gvm; do
	echo "Waiting for gvmd"
	sleep 1
done

echo "Checking for $USERNAME"
# Unset this here or the --get-users will kill the script on a normal startup.
set +e
su -c "gvmd --get-users | grep -qis $USERNAME " gvm
if [ $? -ne 0 ]; then
	echo "$USERNAME does not exist"
	echo "Creating Greenbone Vulnerability Manager admin user as $USERNAME"
	su -c "gvmd --role=\"Super Admin\" --create-user=\"$USERNAME\" --password=\"$PASSWORD\"" gvm
	echo "admin user created"
	ADMINUUID=$(su -c "gvmd --get-users --verbose | awk '{print \$2}' " gvm)
	echo "admin user UUID is $ADMINUUID"
	echo "Granting admin access to defaults"
	su -c "gvmd --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value $ADMINUUID" gvm
fi
echo "reset "
set -Eeuo pipefail
touch /setup

# because ....
chown -R gvm:gvm /data/var-lib 


if [ -f /var/run/ospd.pid ]; then
  rm /var/run/ospd.pid
fi


echo "Starting Postfix for report delivery by email"
# Configure postfix
sed -i "s/^relayhost.*$/relayhost = ${RELAYHOST}:${SMTPPORT}/" /etc/postfix/main.cf
# Start the postfix  bits
#/usr/lib/postfix/sbin/master -w
service postfix start

if [ -S /tmp/ospd.sock ]; then
  rm /tmp/ospd.sock
fi
echo "Starting Open Scanner Protocol daemon for OpenVAS..."
ospd-openvas --log-file /usr/local/var/log/gvm/ospd-openvas.log \
             --unix-socket /tmp/ospd.sock --log-level INFO --socket-mode 666

# wait for ospd to start by looking for the socket creation.
while  [ ! -S /tmp/ospd.sock ]; do
	sleep 1
done

# This is cludgy and needs a better fix. namely figure out how to hard code alllll 
# of the scoket references in the startup process.
# Update ... I think this is no longer needed.
# Need to test. Added this back when gvmd --rebuild failed from command line.
# suspect it would have worked fine if using the --osp-vt-update=/tmp/ospd.sock
if [ ! -L /var/run/ospd/ospd.sock ]; then
	echo "Fixing the ospd socket ..."
	#rm -f /var/run/openvassd.sock
	#ln -s /tmp/ospd.sock /var/run/openvassd.sock
	rm -f /var/run/ospd/ospd.sock
	ln -s /tmp/ospd.sock /var/run/ospd/ospd.sock 
fi





echo "Starting Greenbone Security Assistant..."
su -c "gsad --verbose --no-redirect --no-redirect --mlisten=127.0.0.1 --mport 9390 --listen 0.0.0.0 --port=9392" gvm
GVMVER=$(su -c "gvmd --version" gvm ) 
echo "++++++++++++++++++++++++++++++++++++++++++++++"
echo "+ Your GVM/openvas/postgresql container is now ready to use! +"
echo "++++++++++++++++++++++++++++++++++++++++++++++"
echo ""
echo "gvmd --version"
echo "$GVMVER"
echo ""
echo "++++++++++++++++"
echo "+ Tailing logs +"
echo "++++++++++++++++"
tail -F /usr/local/var/log/gvm/*
