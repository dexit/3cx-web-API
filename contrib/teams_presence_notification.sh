#!/bin/bash

# This script uses delegated permissions (the only supported scenario in M365)
#  Presence.Read.All
#  User.ReadBasic.All
#  offline_access

tenant='<M365 tenant ID>'
client_id='<M365 client ID>'

webhook="https://<your-instance>.3cx.eu/<keep-this-arbitrary-path-secret"

# offline_access Scope required in order to receive a Refresh-Tokens
scope='https://graph.microsoft.com/User.ReadBasic.All https://graph.microsoft.com/Presence.Read.All offline_access'

# doing device-code grant here as we're unable to receive a redirectURI call
grant_type='urn:ietf:params:oauth:grant-type:device_code'

token_endpoint="https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token?"
device_endpoint="https://login.microsoftonline.com/${tenant}/oauth2/v2.0/devicecode?"

if ! [ -d "./tmp" ] ; then
	mkdir ./tmp
fi

access_token_file="./tmp/azure.access_token"
refresh_token_file="./tmp/azure.refresh_token"
response_file="./tmp/azure.response"
cert="./tmp/azure.cert"
key="./tmp/azure.key"
user_file="./tmp/azure.users"

usage() {
	echo "Usage: $0 [ <user1> [ .. <userX>] | delete | reauthorize [<subscription-id>] | get <user> ]"
	exit 1
}

if [ "$1" = '-h' -o "$1" = 'help' -o "$1" = '-help' -o "$1" = '--help' ] ; then
	usage
elif [ "$1" = "reauthorize" ] ; then
	user_list=$1
	subscription=$2
elif [ "$1" = "get" ] ; then
	user_list=$1
	if [ -z "${2}" ] ; then
		echo "Error: <user> missing!"
		usage
	fi
	user=$2
else
	user_list=$@
fi

if [ ! -f "${user_file}" ] ; then
	touch "${user_file}"
fi


trap "exit 1" TERM
export MYPID=$$


# Login Prozess - returns refresh_token and access_token (and stores them in files)
token_login() {
	res=$(curl -s -X POST -H 'Content-Type: application/x-www-form-urlencoded' "${device_endpoint}" \
		--data-urlencode "client_id=${client_id}" \
		--data-urlencode "scope=${scope}")

	# Request user to perform Device Login
	echo "${res}" | jq -r '.message'

	device_code=$(echo "${res}" | jq -r '.device_code')
	expires_in=$(echo "${res}" | jq -r '.expires_in')
	interval=$(echo "${res}" | jq -r '.interval')

	count=0
	auth=""

	# Polling token_endpoint until auth-tokens are received (or timeout)
	until [ -n "${auth}" ] ; do
		count=$((count+interval))
		if [ ${count} -ge ${expires_in} ] ; then
			echo "Error: Authentication timeout"
			kill -TERM $MYPID
		fi
		sleep $interval

		# try to retrieve the tokens
		res=$(curl -s -X POST -H 'Content-Type: application/x-www-form-urlencoded' "${token_endpoint}" \
			--data-urlencode "grant_type=${grant_type}" \
			--data-urlencode "client_id=${client_id}" \
			--data-urlencode "device_code=${device_code}")

		# handle error
		error=$(echo "${res}" | jq -r '.error|values')
		if [ -n "${error}" ] ; then
			if [ "${error}" != "authorization_pending" ] ; then
				echo "Error: $error"
				echo "${res}" | jq -r '.error_description'
				kill -TERM $MYPID
			fi
		else
			# handle response otherwise
			auth=$res
		fi
	done

	access_token=$(echo "${auth}" | jq -r '.access_token|values')
	refresh_token=$(echo "${auth}" | jq -r '.refresh_token|values')

	if [ -z "${access_token}" ] ; then
		echo "Error: something went wrong"
		echo "${auth}"
		kill -s TERM $MYPID
	fi

	# write token to file
	echo "${access_token}" > "${access_token_file}"
	echo "${refresh_token}" > "${refresh_token_file}"
}


# get new access_token from refresh_token
token_refresh() {
	# if Client_Secret is set...
	if [ -n "${client_secret}" ] ; then
		auth=$(curl -s -X POST -H 'Content-Type: application/x-www-form-urlencoded' "${token_endpoint}" \
			--data "client_id=${client_id}" \
			--data-urlencode "client_secret=${client_secret}" \
			--data "scope=${scope}" \
			--data "grant_type=refresh_token" \
			--data-urlencode "refresh_token=${refresh_token}")
	# ...also works without Client_Secret
	else
		auth=$(curl -s -X POST -H 'Content-Type: application/x-www-form-urlencoded' "${token_endpoint}" \
			--data "client_id=${client_id}" \
			--data "scope=${scope}" \
			--data "grant_type=refresh_token" \
			--data-urlencode "refresh_token=${refresh_token}")
	fi

	access_token=$(echo "${auth}" | jq -r '.access_token|values')
	refresh_token=$(echo "${auth}" | jq -r '.refresh_token|values')

	if [ -z "${access_token}" ] ; then
		echo "Error: something went wrong"
		echo "${auth}"
		kill -s TERM $MYPID
	fi

	# write token to file
	echo "${access_token}" > "${access_token_file}"
	echo "${refresh_token}" > "${refresh_token_file}"
}


# check if access_token is still valid
check_access_token() {
	if [ -f "${access_token_file}" -a -f "${refresh_token_file}" ] ; then
		refresh_token=$(cat "${refresh_token_file}")
		access_token=$(cat "${access_token_file}")
		# check the most basic Graph endpoint if it returns data
		error=$(curl -s -X GET -H "Authorization: Bearer ${access_token}" -w "%{http_code}" -o "${response_file}" "https://graph.microsoft.com/v1.0/me")
		if [ "$error" = "401" ] ; then
       			token_refresh
		fi
	else
		token_login
	fi
}


# get User-Id from Azure-UPN
get_user() {
	# check cached id first
	id=$(cat "${user_file}" | grep "${user}" | cut -d" " -f2)
	if [ -z "$id" ] ; then
		id=$(curl -s -X GET -H "Authorization: Bearer ${access_token}" "https://graph.microsoft.com/v1.0/users/${user}" | jq -r '.id'|values)
		if [ -n "${id}" ] ; then
			echo "${user} ${id}" >> "${user_file}"
		else
			echo "Error: no such user ${user}"
		fi
	fi
}

get_user_status() {
	get_user
	if [ -n "${id}" ] ; then
		res=$(curl -s -X GET -H "Authorization: Bearer ${access_token}" -H "Content-Type: application/json" "https://graph.microsoft.com/v1.0/users/${id}/presence" | jq -r '.availability|values')
	fi
}

# get active Subscription-Id (there seems only one subscription per session possible)
get_active_notification() {
	res=$(curl -s -X GET -H "Authorization: Bearer ${access_token}" -H "Content-Type: application/json" "https://graph.microsoft.com/v1.0/subscriptions" | jq -r '.value[] | "\(.id) \(.expirationDateTime)"')
	id=$(echo $res | cut -d' ' -f1)
}


# delete active Subscription
delete_active_notification() {
	get_active_notification
	if [ -n "$id" ] ; then
		res=$(curl -s -X DELETE -H "Authorization: Bearer ${access_token}" -H "Content-Type: application/json" "https://graph.microsoft.com/v1.0/subscriptions/${id}")
	fi
}


# reauthorizes a subscription
reauthorize_notification() {
	if [ -n "$id" ] ; then
		expiration=$(date -d '+1 hour' -u +'%FT%T.%7NZ')
		subscription='{"expirationDateTime": "'${expiration}'"}'
		error=$(curl -s -w "%{http_code}" -o "${response_file}" -X PATCH -H "Authorization: Bearer ${access_token}" -H "Content-Type: application/json" "https://graph.microsoft.com/v1.0/subscriptions/${id}" -d "${subscription}" )
		if [ "$error" = "200" ] ; then
			id=$(jq -r '.id' "${response_file}")
			res=$(jq -r '"\(.id) \(.expirationDateTime)"' "${response_file}")
			return
		fi
	fi
	echo "Error: no active subscription present"
	exit 1
}


# creates new subscription
setup_notification() {
	id_list=""
	# user_list can be separated by comma or space
	for user in ${user_list//,/ } ; do
		id=""
		get_user
		if [ -n "$id" ] ; then
			if [ -n "$id_list" ] ; then
				id_list="${id_list},'${id}'"
			else
				id_list="'${id}'"
			fi
		fi
	done

	if [ -z "${id_list}" ] ; then
		echo "Error: no user found ${user_list}"
		exit 1
	fi

	# create new public/private key-pair for payload encryption if it doesn't exist
	if [ ! -f "$cert" -o ! -f "$key" ] ; then
		openssl req -x509 -newkey rsa:2048 -keyout "$key" -out "$cert" -sha256 -days 365 -nodes -subj '/CN=localhost'
	fi
	cert=$(cat "$cert" | grep -vE '^-----' | sed -ze 's/\n//g')
	# for presence max. duration is 60min.
	expiration=$(date -d '+1 hour' -u +'%FT%T.%7NZ')
	subscription='{ "changeType": "updated",
			"notificationUrl": "'${webhook}'",
			"lifecycleNotificationUrl": "'${webhook}'",
			"resource": "/communications/presences?$filter=id in ('${id_list}')",
			"includeResourceData": true,
			"encryptionCertificate": "'${cert}'",
			"encryptionCertificateId": "20230419",
			"expirationDateTime": "'${expiration}'",
			"clientState": "AlexTest" }'

	res=$(curl -s -X POST -H "Authorization: Bearer ${access_token}" -H "Content-Type: application/json" "https://graph.microsoft.com/v1.0/subscriptions" -d "${subscription}")
	error=$(echo $res | jq -r '.error | values | "\(.code): \(.message)"')
	if [ -n "${error}" ] ; then
		echo "Error: ${error}"
		exit 1
	fi
	res=$(echo $res | jq -r '"\(.id) \(.expirationDateTime)"')
	id=$(echo $res | cut -d' ' -f1)
}


###########
# Main
###########
check_access_token

if [ "$user_list" = "delete" ] ; then
	delete_active_notification
elif [ "$user_list" = "get" ] ; then
	get_user_status
elif [ "$user_list" = "reauthorize" ] ; then
	if [ -z "${subscription}" ] ; then
		get_active_notification
	else
		id=$subscription
	fi
	reauthorize_notification
elif [ -n "$user_list" ] ; then
	setup_notification
else
	get_active_notification
fi
echo $res
