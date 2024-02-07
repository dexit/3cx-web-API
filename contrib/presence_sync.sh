#!/bin/bash
#
# This Script requires
#  3CX Web-Api (https://github.com/adn77/3cx-web-API)
#  curl
#  jq

declare -A users

# extension to O365 user ID mapping
users["1234"]='user1@example.org'
users["4711"]='user2@example.org'

# status refresh time in seconds
refresh=60

# regex to match state and extension
busy_match="^\s*ID=.*;S=(Dialing|Connected);DN=(.*);Queue_Name="

# path to Web-API binary
WEB_API="./WebAPICore"

# listen port to start the WebApi on
WEB_API_PORT=1234

# path to teams_presence_notification.sh
TEAMS_NOTIFY="./teams_presence_notification.sh"

# path to set_teams_presence.sh
TEAMS_PRESENCE="./set_teams_presence.sh"

# those paths are used to exchange data between teams_presence_notification.sh
key_file="./tmp/azure.key"
user_file="./tmp/azure.users"

if [ ! -f "${user_file}" ] ; then
	touch "${user_file}"
fi

declare -A extensions
declare -A statechange

userlist=""
# initialize some state data
for i in "${!users[@]}" ; do
	statechange[$i]=0
	extensions["${users[$i]}"]=$i
	userlist="${userlist} ${users[$i]}"
done

echo "Requesting status updates from MS Teams for"
echo " ${userlist}"
(sleep 5 ; ${TEAMS_NOTIFY}${userlist} > /dev/null )&

update=$(date +%s)

# loop over StdOutput of the call processing API
while read line ; do
	now=$(date +%s)
	logdate=$(date -u +'%FT%TZ')
#	echo $logdate - $line
	# exit if the API server received a /stop command
	if [[ "$line" =~ "Server Stop" ]] ; then
		echo "${logdate} - deleting subscription"
		${TEAMS_NOTIFY} delete
		echo "${logdate} - stopping server"
		exit 0
	# process notification lifecycleEvent
	elif [[ "$line" =~ "subscriptionRemoved" ]] ; then
		echo "${logdate} - subscription removed - ${line}"
		echo "${logdate} - (re)creating subscription"
		${TEAMS_NOTIFY} "${userlist}"
	# process notification lifecycleEvent
	elif [[ "$line" =~ "reauthorizationRequired" ]] ; then
		id=$(echo "${line}" | jq -r '.value[0].subscriptionId')
		echo "${logdate} - reauthorizing subscription ${id}"
		out=$(${TEAMS_NOTIFY} reauthorize "${id}")
		if [[ "$out" =~ "Error" ]] ; then
			echo "${logdate} - (re)creating subscription"
			${TEAMS_NOTIFY} "${userlist}"
		else
			echo "${logdate} - recreated subscription: ${out}"
		fi
	# process notification lifecycleEvent
	elif [[ "$line" =~ "missed" ]] ; then
		echo "${logdate} - missed lifecycleEvent - ${line}"
		${TEAMS_NOTIFY} "${userlist}"
	# process notification webhook
	elif [[ "$line" =~ "subscriptionId" ]] ; then
		# decrypt encryption key with private key
		# OpenSSL 1.1
#		key=$(echo $line | jq -r '.value[0].encryptedContent.dataKey' | base64 -d | openssl rsautl -decrypt -inkey "${key_file}" -oaep | hexdump -e '16/1 "%02x"')
		# OpenSSL 3.x
		key=$(echo "${line}" | jq -r '.value[0].encryptedContent.dataKey' | base64 -d | openssl pkeyutl -decrypt -inkey "${key_file}" -pkeyopt rsa_padding_mode:oaep | hexdump -e '16/1 "%02x"')
		# iv is first 32 bytes of encryption key
		iv=$(echo $key | head --bytes 32)
		# decrypt data payload
		json=$(echo $line | jq -r '.value[] | .encryptedContent.data' | base64 -d | openssl enc -d -aes-256-cbc -K $key -iv $iv)
#		echo "${logdate} - ${json}"
		# extract Azure-UserId from json
		userid=$(echo "$json" | jq -r '.id')
		if [ -n "$userid" ] ; then
			# the user - userId should have been placed in a "user_file" when the notification was created
			#  since the userId is static, it saves another API lookup call
			user=$(cat "${user_file}" | grep "${userid}" | cut -d' ' -f1)
			if [ -n "$user" ] ; then
				# if the user is configured with an extension
				if [ -n "${extensions[${user}]}" ] ; then
					# and a state-change did not occur within $refresh period
					if [ $((now - statechange[${extensions[${user}]}])) -gt $((15 * refresh / 10)) ] ; then
						# retrieve the Teams availability status
						status=$(echo "$json" | jq -r '.availability')
						# retrieve 3CX availability status
						localstatus=$(curl -s http://localhost:${WEB_API_PORT}/showstatus/${extensions[${user}]})
						if [[ "$status" =~ "Available" ]] && [[ "${localstatus}" =~ "Away" ]] ; then
							echo "${logdate} - Notify: Setting user <${user}> (${extensions[${user}]}) Available on 3CX (was ${localstatus##*=})"
							curl -s http://localhost:${WEB_API_PORT}/setstatus/${extensions[${user}]}/avail > /dev/null
						elif [[ "$status" =~ "Busy"|"DoNotDisturb"|"BeRightBack"|"Offline" ]] && [[ "${localstatus}" =~ "Available" ]] ; then
							echo "${logdate} - Notify: Setting user <${user}> (${extensions[${user}]}) Away on 3CX (was ${localstatus##*=})"
							curl -s http://localhost:${WEB_API_PORT}/setstatus/${extensions[${user}]}/away > /dev/null
						else
							echo "${logdate} - Notify: Upn: ${user} - Ext: ${extensions[${user}]} - Teams: $status - 3cx: ${localstatus##*=}"
						fi
					fi
				else
					echo "${logdate} - Notify: Upn: ${user} is not configured with an extension"
				fi
			else
				echo "${logdate} - Notify: Upn: ${userid} not found in subscription list"
			fi
		else
			echo "${logdate} - Notify: Error parsing response JSON..."
			echo "${logdate} - ${json}"
		fi
	# This sets the teams status to busy in case a call is currently placed
	# !!! For this to work, http://localhost:${WEB_API_PORT}/showallcalls must be called periodically
	#     Best probably is to setup a cron job
	#
	# check if a call is being set up or already connected
	elif [[ "$line" =~ $busy_match ]] ; then
		ext=${BASH_REMATCH[2]}
		# process further if the extension is in the user mapping
		if [ -n "${users[$ext]}" ] ; then
			# has there been a state change during the last refresh period?
			if [ $((now - statechange[$ext])) -gt $((15 * refresh / 10)) -a ! "$ext" = "925" ] ; then
				echo "${logdate} - Polling: Setting user <${users[$ext]}> (${ext}) Busy on Teams"
				${TEAMS_PRESENCE} "${users[$ext]}" busy > /dev/null
			fi
			statechange[$ext]=$now
#		else
#			echo "${logdate} - Polling: <${ext}> is in a call but didn't find it in the user list"
		fi
	# the showallcalls command always prints <html>
	elif [[ "$line" =~ "<html>" ]] ; then
		# set any users to "available" who are still busy but not in the active call list
		for i in "${!statechange[@]}" ; do
			# extension is not currently in a call, but the time it was is less than 1.5 * refresh period
			if [ -z "$(echo $line | grep "DN=${i}")" -a $((now - statechange[$i])) -lt $((15 * refresh / 10)) ] ; then
				echo "${logdate} - Polling: Setting user <${users[$i]}> (${i}) Available on Teams"
				${TEAMS_PRESENCE} "${users[$i]}" available > /dev/null
			fi
		done
	else
		if ! [[ "$line" =~ CURRENT_STATUS|Call|Ringing|Away|Available ]] && [ -n "$line" ] ; then
			echo "${logdate} - Unknown: ${line}"
		fi
	fi
done < <(${WEB_API} ${WEB_API_PORT})
