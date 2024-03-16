#!/bin/bash

# This script uses application permissions
#  Presence.ReadWrite.All
#  User.ReadBasic.All

tenant='<M365 tenant ID>'
client_id='<M365 client ID>'
client_secret='<M365 client ID>'

scope='https://graph.microsoft.com/.default'
grant_type='client_credentials'

status='{"sessionId":"'${client_id}'"}'

token_file="./tmp/azure.client_token"
response="./tmp/azure.response"
user_file="./tmp/azure.users"

if [ "$#" -lt 2 ] ; then
	echo "Usage: $0 <user> <Available|Busy"
	exit 1
elif [ -n "${1//[-A-Za-z0-9@._]}" ] ; then
	echo "Error: <user> can only contain alpha-numeric characters and any of '-_.@'"
	exit 1
elif [ "$2" = "Busy" ] ; then
	status='{"sessionId":"'${client_id}'","availability":"Busy","activity":"InACall","expirationDuration":"PT2H"}'
fi

user="$1"
token_updated=""

update_token()
{
	token=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded"  "https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token" \
	 --data-urlencode "client_id=${client_id}" \
	 --data-urlencode "client_secret=${client_secret}" \
	 --data-urlencode "scope=${scope}" \
	 --data-urlencode "grant_type=${grant_type}" | jq -r '.access_token|values')

	if [ -z "${token}" ] ; then
		echo "Error: something went wrong"
		exit 1
	fi
	echo "${token}" > "${token_file}"
	chmod 600 "${token_file}"
	token_updated=1
}

get_token()
{
	if [ ! -f "${token_file}" ] ; then
		update_token
	else
		token=$(cat "${token_file}")
	fi
}

get_user()
{
	# check cached id first
	id=$(cat "${user_file}" | grep -m 1 "^${user}" | cut -d" " -f2)
	if [ -z "$id" ] ; then
		# User.ReadBasic.All only permits a subset of attributes - proxyAddresses is NOT one of
		error=$(curl -s -X GET -H "Authorization: Bearer ${token}" -w "%{http_code}" -o "${response}" "https://graph.microsoft.com/v1.0/users?\$filter=userprincipalname+eq+'${user}'+or+mail+eq+'${user}'")

		if [ "$error" = "401" -a -z "${token_updated}" ] ; then
			update_token
			get_user
		elif [ "$error" = "404" ] ; then
			echo "Error: <user> (${user}) not found!"
			exit 1
		elif [ "$error" = "403" ] ; then
			echo "Error: insuffient permissions to read user attributes"
			exit 1
		elif [ "$error" != "200" ] ; then
			echo "Error: unhandled HTTP ${error}"
			cat "${response}"
			exit 1
		fi

		id=$(jq -r '.value[0].id|values' "${response}")
		rm -f "${response}"
		if [ -n "${id}" ] ; then
			echo "${user} ${id}" >> "${user_file}"
		else
			echo "Error: no such user ${user}"
			exit 1
		fi
	fi
}

set_status()
{
	if [ "${status//availability}" != "${status}" ] ; then
		error=$(curl -s -X POST -w "%{http_code}" -o "${response}" -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "https://graph.microsoft.com/v1.0/users/${id}/presence/setPresence" -d "${status}")
	else
		error=$(curl -s -X POST -w "%{http_code}" -o "${response}" -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "https://graph.microsoft.com/v1.0/users/${id}/presence/clearPresence" -d "${status}")
	fi

	if [ "$error" = "401" -a -z "${token_updated}" ] ; then
		update_token
		set_status
	elif [ "$error" = "403" ] ; then
		echo "Error: insuffient permissions to set <${user}< presence"
		exit 1
	elif [ "$error" != "200" ] ; then
		echo "Error: unhandled HTTP ${error}"
		cat "${response}"
	fi
}

get_token
get_user
set_status

rm -f "${response}"
