#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (C) 2016-2018 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.

die() {
	echo "[-] Error: $1" >&2
	exit 1
}

PROGRAM="${0##*/}"
ARGS=( "$@" )
SELF="${BASH_SOURCE[0]}"
[[ $SELF == */* ]] || SELF="./$SELF"
SELF="$(cd "${SELF%/*}" && pwd -P)/${SELF##*/}"
[[ $UID == 0 ]] || exec sudo -p "[?] $PROGRAM must be run as root. Please enter the password for %u to continue: " -- "$BASH" -- "$SELF" "${ARGS[@]}"

[[ ${BASH_VERSINFO[0]} -ge 4 ]] || die "bash ${BASH_VERSINFO[0]} detected, when bash 4+ required"

set -e
type curl >/dev/null || die "Please install curl and then try again."
type jq >/dev/null || die "Please install jq and then try again."

PASS_TYPE=password
[[ $1 == --token ]] && PASS_TYPE=token

read -p "[?] Please enter your AzireVPN username: " -r USER
read -p "[?] Please enter your AzireVPN $PASS_TYPE: " -rs PASS
echo

declare -A SERVER_ENDPOINTS
declare -A SERVER_LOCATIONS
declare -a SERVER_CODES

echo "[+] Contacting AzireVPN API for server locations."
RESPONSE="$(curl -LsS https://api.azirevpn.com/v1/locations)" || die "Unable to connect to AzireVPN API."
FIELDS="$(jq -r '.locations[] | select(.endpoints.wireguard) | .name,.city,.country,.endpoints.wireguard' <<<"$RESPONSE")" || die "Unable to parse response."
while read -r CODE && read -r CITY && read -r COUNTRY && read -r ENDPOINT; do
	SERVER_CODES+=( "$CODE" )
	SERVER_LOCATIONS["$CODE"]="$CITY, $COUNTRY"
	SERVER_ENDPOINTS["$CODE"]="$ENDPOINT"
done <<<"$FIELDS"

for CODE in "${SERVER_CODES[@]}"; do
	CONFIGURATION_FILE="/etc/wireguard/azirevpn-$CODE.conf"
	PRIVATE_KEY=""
	shopt -s nocasematch
	if [[ -f $CONFIGURATION_FILE ]]; then
		while read -r line; do
			[[ $line =~ ^PrivateKey[[:space:]]*=[[:space:]]*([a-zA-Z0-9+/]{43}=)[[:space:]]*$ ]] && PRIVATE_KEY="${BASH_REMATCH[1]}" && break
		done < "$CONFIGURATION_FILE"
	fi
	shopt -u nocasematch
	if [[ -z $PRIVATE_KEY ]]; then
		echo "[+] Generating new $CODE private key."
		PRIVATE_KEY="$(wg genkey)"
	else
		echo "[+] Using existing $CODE private key."
	fi
	echo "[+] Contacting AzireVPN API in ${SERVER_LOCATIONS["$CODE"]}."
	RESPONSE="$(curl -LsS -d username="$USER" --data-urlencode "$PASS_TYPE=$PASS" --data-urlencode pubkey="$(wg pubkey <<<"$PRIVATE_KEY")" "${SERVER_ENDPOINTS[$CODE]}")" || die "Unable to connect to AzireVPN API."
	FIELDS="$(jq -r '.status,.message' <<<"$RESPONSE")" || die "Unable to parse response."
	IFS=$'\n' read -r -d '' STATUS MESSAGE <<<"$FIELDS" || true
	if [[ $STATUS != success ]]; then
		if [[ -n $MESSAGE ]]; then
			die "$MESSAGE"
		else
			die "An unknown API error has occurred. Please try again later."
		fi
	fi
	FIELDS="$(jq -r '.data.PublicKey,.data.DNS,.data.Address,.data.Endpoint' <<<"$RESPONSE")" || die "Unable to parse response."
	IFS=$'\n' read -r -d '' PUBLIC_KEY DNS ADDRESS ENDPOINT <<<"$FIELDS" || true

	echo "[+] Writing WriteGuard configuration file to $CONFIGURATION_FILE."
	umask 077
	mkdir -p /etc/wireguard/
	rm -f "$CONFIGURATION_FILE.tmp"
	cat > "$CONFIGURATION_FILE.tmp" <<-_EOF
		[Interface]
		PrivateKey = $PRIVATE_KEY
		Address = $ADDRESS
		DNS = $DNS

		[Peer]
		PublicKey = $PUBLIC_KEY
		Endpoint = $ENDPOINT
		AllowedIPs = 0.0.0.0/0, ::/0
	_EOF
	mv "$CONFIGURATION_FILE.tmp" "$CONFIGURATION_FILE"
done


echo "[+] Success. The following commands may be run for connecting to AzireVPN:"
for CODE in "${SERVER_CODES[@]}"; do
	echo "- ${SERVER_LOCATIONS["$CODE"]}:"
	echo "  \$ wg-quick up azirevpn-$CODE"
done
