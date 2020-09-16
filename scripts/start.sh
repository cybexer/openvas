#!/usr/bin/env bash
set -Eeuo pipefail

USERNAME=${USERNAME:-admin}
PASSWORD=${PASSWORD:-admin}
MAX_ROWS_PER_PAGE=${MAX_ROWS_PER_PAGE:-100000}

if [ ! -d "/run/redis" ]; then
	mkdir /run/redis
fi
if  [ -S /run/redis/redis.sock ]; then
        rm /run/redis/redis.sock
fi
redis-server --unixsocket /run/redis/redis.sock --unixsocketperm 700 --timeout 0 --databases 128 --maxclients 10000 --daemonize yes --port 6379 --bind 0.0.0.0 --logfile /var/log/redis/redis-server.log --loglevel notice

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


if  [ ! -d /data ]; then
	echo "Creating Data folder..."
        mkdir /data
fi

if  [ ! -d /data/database ]; then
	echo "Creating Database folder..."
	mv /var/lib/postgresql/10/main /data/database
	ln -s /data/database /var/lib/postgresql/10/main
	chown postgres:postgres -R /var/lib/postgresql/10/main
	chown postgres:postgres -R /data/database
fi

if [ -d /var/lib/postgresql/10/main ]; then
	echo "Fixing Database folder..."
	rm -rf /var/lib/postgresql/10/main
	ln -s /data/database /var/lib/postgresql/10/main
	chown postgres:postgres -R /var/lib/postgresql/10/main
	chown postgres:postgres -R /data/database
fi

echo "Starting PostgreSQL..."
/usr/bin/pg_ctlcluster --skip-systemctl-redirect 10 main start

if [ ! -f "/firstrun" ]; then
	echo "Running first start configuration..."

	echo "Creating Openvas NVT sync user..."
	useradd --home-dir /usr/local/share/openvas openvas-sync
	chown openvas-sync:openvas-sync -R /usr/local/share/openvas
	chown openvas-sync:openvas-sync -R /usr/local/var/lib/openvas

	echo "Creating Greenbone Vulnerability system user..."
	useradd --home-dir /usr/local/share/gvm gvm
	chown gvm:gvm -R /usr/local/share/gvm
	mkdir /usr/local/var/lib/gvm/cert-data
	chown gvm:gvm -R /usr/local/var/lib/gvm
	chmod 770 -R /usr/local/var/lib/gvm
	chown gvm:gvm -R /usr/local/var/log/gvm
	chown gvm:gvm -R /usr/local/var/run

	adduser openvas-sync gvm
	adduser gvm openvas-sync
	touch /firstrun
fi

if [ ! -f "/data/firstrun" ]; then
	echo "Creating Greenbone Vulnerability Manager database"
	su -c "createuser -DRS gvm" postgres
	su -c "createdb -O gvm gvmd" postgres
	su -c "psql --dbname=gvmd --command='create role dba with superuser noinherit;'" postgres
	su -c "psql --dbname=gvmd --command='grant dba to gvm;'" postgres
	su -c "psql --dbname=gvmd --command='create extension \"uuid-ossp\";'" postgres
	su -c "psql --dbname=gvmd --command='create extension pgcrypto';" postgres
	touch /data/firstrun
fi

if [ -f /var/run/ospd.pid ]; then
  rm /var/run/ospd.pid
fi

if [ -S /var/run/ospd/ospd.sock ]; then
  rm /var/run/ospd/ospd.sock
fi

echo "Starting Open Scanner Protocol daemon for OpenVAS..."
ospd-openvas --log-file /usr/local/var/log/gvm/ospd-openvas.log --unix-socket /var/run/ospd/ospd.sock --log-level INFO

while  [ ! -S /var/run/ospd/ospd.sock ]; do
	sleep 1
done

chmod 666 /var/run/ospd/ospd.sock

echo "Starting Greenbone Vulnerability Manager..."
su -c "gvmd --max-ips-per-target 70000 --listen=0.0.0.0 -p 9390" gvm

until su -c "gvmd --get-users" gvm; do
	sleep 1
done

if [ ! -f "/data/set_max_rows_per_page" ]; then
	echo "Setting \"Max Rows Per Page\" to raise the report size limit"
	su -c "gvmd --modify-setting 76374a7a-0569-11e6-b6da-28d24461215b --value $MAX_ROWS_PER_PAGE" gvm
	
	touch /data/set_max_rows_per_page
fi

if [ ! -f "/data/created_gvm_user" ]; then
	echo "Creating Greenbone Vulnerability Manager admin user"
	su -c "gvmd --create-user=${USERNAME} --password=${PASSWORD}" gvm

	echo "Adding import feed rights"
	su -c "psql -t gvmd -c 'select uuid from users where id = 1' > /tmp/userid" postgres
	su -c "cat /tmp/userid | xargs --verbose gvmd --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value " gvm

	touch /data/created_gvm_user
fi

chown openvas-sync:openvas-sync /usr/local/var/run/feed-update.lock

echo "Starting Greenbone Security Assistant..."
su -c "gsad --verbose --no-redirect --mlisten=127.0.0.1 --mport 9390 -p 9392 --listen 0.0.0.0" gvm

echo "Updating NVTs..."
su -c "greenbone-nvt-sync" openvas-sync
sleep 5

echo "Updating GVMD data..."
su -c "greenbone-feed-sync --type GVMD_DATA" openvas-sync
sleep 5

echo "Updating CERT data..."
su -c "/cert-data-sync.sh" openvas-sync
sleep 5

echo "Updating SCAP data..."
su -c "/scap-data-sync.sh" openvas-sync
sleep 5

echo "++++++++++++++++++++++++++++++++++++++++++++++"
echo "+ Your GVM 11 container is now ready to use! +"
echo "++++++++++++++++++++++++++++++++++++++++++++++"
echo ""
echo "++++++++++++++++"
echo "+ Tailing logs +"
echo "++++++++++++++++"
tail -F /usr/local/var/log/gvm/*
