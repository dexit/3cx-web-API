# 3cx <-> MS Teams Presence Sync

These scripts operate on an on-premises 3CX install. They allow to synchronize the presence state between MS Teams and a 3CX PBX both ways.

* Teams state sets the 3CX presence state to "Available"/"Away" (Teams state "Away" is ignored as this is is set automatically after some period of inactivity in Teams)
* during a call on 3CX, Teams' presence is set to "Busy" - there is some logic behind the scenes, we can't control about overriding "Offline" and "Away" in Teams which comes in handy in this case

3cx-Web-API is used to interact with the 3CX PBX. Apart from TAPI and CRM integrations this seems to be the only way to react to call states as well as set the presence state.

All interaction beween 3CX is logged to StdOut by the Web-API. This repo contains a modification for interaction with M365 subscription services (extends 3cx-web-api to handle the notification webhook).

## Webhook setup

In order to direct traffic to the API, /etc/nginx/sites-enabled/3cxpbx (normally a sym-link) has to be modified:
````
...
    upstream webapi {
        server 127.0.0.1:1234;
    }
...
    server {
...
        location ~ ^/secret-url-teams-presence-notification {
            proxy_pass          http://webapi;
        }
...
````
**Note: in this particular setup the path-name is the only "secret", preventing anybody to tamper with your PBX!!!**

## Script Setup

The script *presence_sync.sh* basically parses the output of the 3cx-web-api.
* Teams status subscription is handled via *teams_presence_notification.sh*. Whenever a message is posted to the webhook Url it needs to be handled.
* current 3cx calls are output whenever the */showallcalls* API endpoint is triggered => this should be called via cron

Before running *presence_sync.sh* both scripts *set_teams_presence.sh* and *teams_presence_notification.sh* should be configured and run manually (once) in order to setup authentication.

## Running
````
    ./presence_sync.sh > output.log &
````
The 3cx-web-api can only poll for active calls. Hence a cron has to be set up:
````
* *     * * *   root    curl -s http://localhost:1234/showallcalls > /dev/null 2>&1
````
