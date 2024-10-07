#!/bin/bash

set -e

APP_HOST="app.mydomain.com"
APP_IP="10.0.0.4";
MAIL_HOST="mydomain.com"
IP4=`curl -s ipv4.icanhazip.com`
openssl genrsa -out dkim.key 1024 2>/dev/null
openssl rsa -in dkim.key -pubout -out dkim.pub.key 2>/dev/null
PG_USER=sl_user
PG_PASS=`tr -dc A-Za-z0-9 </dev/urandom | head -c 20`
FLASK_PASS=`tr -dc A-Za-z0-9 </dev/urandom | head -c 20`
DKIM=`perl -e 'print "v=DKIM1; k=rsa; p="; foreach (<>) { s/-----(BEGIN|END) PUBLIC KEY-----//; s/\n//g; print; }' < dkim.pub.key`

mkdir -p postfix

cat << EOF > postfix/main.cf
# POSTFIX config file, adapted for SimpleLogin
smtpd_banner = $myhostname ESMTP $mail_name (Ubuntu)
biff = no

# appending .domain is the MUA's job.
append_dot_mydomain = no

# Uncomment the next line to generate "delayed mail" warnings
#delay_warning_time = 4h

readme_directory = no

# See http://www.postfix.org/COMPATIBILITY_README.html -- default to 2 on
# fresh installs.
compatibility_level = 2

# TLS parameters
smtpd_tls_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
smtpd_tls_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
smtp_tls_security_level = may
smtpd_tls_security_level = may

# See /usr/share/doc/postfix/TLS_README.gz in the postfix-doc package for
# information on enabling SSL in the smtp client.

alias_maps = hash:/etc/aliases
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 10.0.0.0/24

# Set your domain here
mydestination =
myhostname = $APP_HOST
mydomain = $MAIL_HOST
myorigin = $MAIL_HOST

relay_domains = pgsql:/etc/postfix/pgsql-relay-domains.cf
transport_maps = pgsql:/etc/postfix/pgsql-transport-maps.cf

# HELO restrictions
smtpd_delay_reject = yes
smtpd_helo_required = yes
smtpd_helo_restrictions =
    permit_mynetworks,
    reject_non_fqdn_helo_hostname,
    reject_invalid_helo_hostname,
    permit

# Sender restrictions:
smtpd_sender_restrictions =
    permit_mynetworks,
    reject_non_fqdn_sender,
    reject_unknown_sender_domain,
    permit

# Recipient restrictions:
smtpd_recipient_restrictions =
   reject_unauth_pipelining,
   reject_non_fqdn_recipient,
   reject_unknown_recipient_domain,
   permit_mynetworks,
   reject_unauth_destination,
   reject_rbl_client zen.spamhaus.org,
   reject_rbl_client bl.spamcop.net,
   permit
#maillog_file = /var/log/postfix.log
EOF

cat << EOF > postfix/pgsql-relay-domains.cf
hosts = 10.0.0.3
user = $PG_USER
password = $PG_PASS
dbname = simplelogin

query = SELECT domain FROM custom_domain WHERE domain='%s' AND verified=true
    UNION SELECT '%s' WHERE '%s' = '$MAIL_HOST' LIMIT 1;
EOF

cat << EOF > postfix/pgsql-transport-maps.cf
hosts = 10.0.0.3
user = $PG_USER
password = $PG_PASS
dbname = simplelogin

# forward to smtp:10.0.0.5:20381 for custom domain AND email domain
query = SELECT 'smtp:10.0.0.5:20381' FROM custom_domain WHERE domain = '%s' AND verified=true
    UNION SELECT 'smtp:10.0.0.5:20381' WHERE '%s' = '$MAIL_HOST' LIMIT 1;
EOF

cat << EOF > .env
POSTGRES_USER=$PG_USER
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DB=simplelogin
APP_IP=$APP_IP
EOF

cat << EOF > simplelogin.env
# WebApp URL
URL=https://$APP_HOST

# domain used to create alias
EMAIL_DOMAIN=$MAIL_HOST

# transactional email is sent from this email address
SUPPORT_EMAIL=support@$MAIL_HOST
SUPPORT_NAME=SimpleLogin from $APP_HOST

DISABLE_ONBOARDING=true

# custom domain needs to point to these MX servers
EMAIL_SERVERS_WITH_PRIORITY=[(10, "${APP_HOST}.")]

# By default, new aliases must end with ".{random_word}". This is to avoid a person taking all "nice" aliases.
# this option doesn't make sense in self-hosted. Set this variable to disable this option.
DISABLE_ALIAS_SUFFIX=1

# the DKIM private key used to compute DKIM-Signature
DKIM_PRIVATE_KEY_PATH=/dkim.key

# DB Connection
DB_URI=postgresql://${PG_USER}:${PG_PASS}@sl-db:5432/simplelogin

FLASK_SECRET=$FLASK_PASS

LOCAL_FILE_UPLOAD=1

POSTFIX_SERVER=10.0.0.2
EOF

docker compose up -d sl-db
docker run --rm --name sl-migration -v /persistent/sl:/sl -v /persistent/sl/upload:/code/static/upload -v $(pwd)/dkim.key:/dkim.key -v $(pwd)/dkim.pub.key:/dkim.pub.key -v $(pwd)/simplelogin.env:/code/.env --network="${PWD##*/}_sl-network" simplelogin/app:3.4.0 flask db upgrade
docker run --rm --name sl-init      -v /persistent/sl:/sl -v $(pwd)/simplelogin.env:/code/.env -v $(pwd)/dkim.key:/dkim.key -v $(pwd)/dkim.pub.key:/dkim.pub.key --network="${PWD##*/}_sl-network" simplelogin/app:3.4.0 python init_app.py
docker compose up -d

cat << EOF


Create the following DNS records:

A Record: $APP_HOST A $IP4
MX Record: $MAIL_HOST MX $APP_HOST
DKIM: dkim._domainkey.$MAIL_HOST. TXT $DKIM
SPF: $MAIL_HOST TXT v=spf1 mx -all
DMARC: _dmarc.$MAIL_HOST TXT v=DMARC1; p=quarantine; adkim=r; aspf=r
Reverse DNS: $IP4 PTR $MAIL_HOST

The app should be available on http://${APP_IP}:7777/ but you will need to setup SSL forwarding to create an account.

EOF
