# Simplelogin Docker - unofficial build script

This is just a build.sh and docker-compose.yaml to bring up the Simple Login stack in one command.

You'll still need to configure HTTPS with a reverse proxy otherwise it won't let you login.

## Usage

You need to have Docker Compose installed.

1. Modify APP_HOST and MAIL_HOST at the top of build.sh
2. Run ./build.sh
3. Add the DNS records suggested by the output
4. Configure a HTTPS proxy to http://10.0.0.3:7777

NOTE: build.sh should only be run once, otherwise it will overwrite the postgres password and dkim key.
After the first build use docker compose commands to bring the stack up and down.

## Known Issues
* Quarantined emails are not stored, the .eml files give a 404
