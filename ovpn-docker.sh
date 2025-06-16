#!/bin/bash

source .env

function log_error() {
    if [ -n "$1" ]; then
      echo -e "\x1b[0;31m✖ $1\x1b[0m"
    fi
}

function log_success() {
    echo -e "\x1b[0;32m✔\x1b[0m \x1b[0;37m$1\x1b[0m"
}

function log_done() {
    echo -e "🚀 \x1b[1;92mDone!\x1b[0m"
}

function log_result() {
  if [ -n "$1" ]; then
    echo -e "\x1b[0;31m✖ $1\x1b[0m\n"
    exit 1
  elif [ -n "$2" ]; then
    echo -e "\x1b[0;32m✔\x1b[0m \x1b[0;37m$2\x1b[0m"
  fi
}

function show_help() {
  echo -e "
Usage: ./docker-ovpn.sh COMMAND [OPTIONS]

A utility for building running and managing a VPN server

Commands:
  create            Creating an OpenVPN server.
                    A volume will be created and an image
                    will be assembled only if they do not
                    exist, otherwise this step will be skipped.
  init-pki          Create new SSL certificates to encrypt
                    the connection.
  remove            Delete the server with all the data
                    and start the configuration over again.
  client            OpenVPN server Client Management.
  up                Launch a VPN server.
  down              Stop the VPN server.

  help              Show this helper

Client management commands:
  --create name     Create a new client and generate
                    the encryption keys.
  --revoke name     Revoke certificates issued for the
                    client. Prohibit the use of a VPN
  --list            Display the list of server clients.

Remark:
  To create and run a server, you need to execute commands
  in a specific sequence and follow the instructions:
  create, init-pki, up, client --create username.

  The .env file is used for configuration.
"
}

function check_server_ready() {
  result=$(docker image inspect "$IMAGE_NAME" 2>&1 1>/dev/null)
    if [[ ${result,,} =~ "no such image" ]]; then
      log_error "$result\n  You need to execute \"./docker-ovpn.sh create\""
      exit 126
    elif [ -n "$result" ]; then
      log_error "$result"
      extt 1
    fi

  result=$(docker volume inspect --format '{{.Mountpoint}}' "$VOLUME_NAME" 2>&1 1>/dev/null);
    if [[ "$result" =~ "no such volume" ]]; then
      log_error "$result\n  You need to execute \"./docker-ovpn.sh create\""
      exit 126
    elif [ -n "$result" ]; then
      log_error "$result"
      extt 1
    fi
}

function remove_server() {
  local result

  docker container ls --all --filter 'volume=ovpn-data' --format '{{.ID}}' | while read -r id; do
    result=$(docker container rm --force "$id" 2>&1 1>/dev/null);
    if test -z "$result"; then log_success "Container $id is removed"; fi
  done

  result=$(docker container rm --force "$CONTAINER_NAME" 2>&1 1>/dev/null);
  if test -z "$result"; then log_success "Container $CONTAINER_NAME is removed"; fi

  result=$(docker volume rm --force "$VOLUME_NAME" 2>&1 1>/dev/null)
  if test -z "$result"; then log_success "Volume $VOLUME_NAME is removed"; fi

  result=$(docker image rm --force "$IMAGE_NAME" 2>&1 1>/dev/null)
  if [ -z "$result" ]; then log_success "Image $IMAGE_NAME is removed"; fi

  log_done
}

function create_server() {
  result=$(docker image inspect "$IMAGE_NAME" 2>&1 1>/dev/null)
  if [[ ${result,,} =~ "no such image" ]]; then
    docker build -f Dockerfile -t "$IMAGE_NAME" .
  elif [[ -z "$result" ]]; then
    log_success "Image $IMAGE_NAME already existed"
  fi


  result=$(docker volume inspect --format '{{.Mountpoint}}' "$VOLUME_NAME" 2>&1 1>/dev/null);
  if [[ "$result" =~ "no such volume" ]]; then
    result=$(docker volume create --name "$OVPN_DATA" 2>&1 1>/dev/null)
    log_result "$result" "New volume $VOLUME_NAME is created"

    docker run -v "$VOLUME_NAME:/etc/openvpn" --rm "$IMAGE_NAME" ovpn-setup \
      -u "$SERVER_PUBLIC_URL" \
      -C "AES-256-GCM" \
      -b


  else
    log_success "Volume $VOLUME_NAME existed"
  fi

  log_done
}

function init_pki() {
  check_server_ready

  docker run -v "$VOLUME_NAME:/etc/openvpn" --rm -it "$IMAGE_NAME" ovpn-init-pki
}

function server_up() {
  check_server_ready

  result=$(docker container inspect "$CONTAINER_NAME" 2>&1 1>/dev/null)
  if [[ ${result,,} =~ "no such container" ]]; then
    docker run --name "$CONTAINER_NAME" -v "$VOLUME_NAME:/etc/openvpn" -d -p "$PORT:1194/udp" -p 443:443 --cap-add NET_ADMIN --cap-add MKNOD --device /dev/net/tun --restart unless-stopped  "$IMAGE_NAME"
  elif [ -z "$result" ]; then
    docker container start --restart unless-stopped "$CONTAINER_NAME"
  fi
}

function server_down() {
  docker container stop "$CONTAINER_NAME"
}

function server_status() {
    docker run -v "$VOLUME_NAME:/etc/openvpn" --rm -it "$IMAGE_NAME" cat /etc/openvpn/status.log
}

function client_create() {
  docker run -v "$VOLUME_NAME:/etc/openvpn" --rm -it "$IMAGE_NAME" easyrsa build-client-full "$1" nopass
  docker run -v "$VOLUME_NAME:/etc/openvpn" --rm -it "$IMAGE_NAME" ovpn-gen-client "$1"
}

function client_revoke() {
  docker run -v "$VOLUME_NAME:/etc/openvpn" --rm -it "$IMAGE_NAME" ovpn-revoke "$1"
}

function client_list() {
  docker run -v "$VOLUME_NAME:/etc/openvpn" --rm -it "$IMAGE_NAME" ovpn-clients
}

function client_subcommand() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --create )
        client_create "$2"
        exit 0
        ;;
      --revoke )
        client_revoke "$2"
        exit 0
        ;;
      --list)
        client_list
        exit 0
        ;;
      *)
        log_error "command: client $1 $2"
        exit 127
        ;;
    esac
  done
}

COMMAND="$1"
shift

case "$COMMAND" in
  create|new )
    create_server
    exit 0
    ;;
  init-pki|init )
    init_pki
    exit 0
    ;;
  remove|rm )
    echo -n "Do you really want to delete the server (confirm - type \"yes\"): "
    read -r ansver
    if [[ "$ansver" == "yes" ]]; then
      remove_server
    fi
    exit 0
    ;;
  client )
    client_subcommand "${@}"
    exit 0
    ;;
  up|start )
    server_up "${@}"
    exit 0
    ;;
  down|stop )
    server_down "${@}"
    exit 0
    ;;
  status|state )
    server_status "${@}"
    exit 0
    ;;
  help|-h|--help )
    show_help
    exit 0;
    ;;
  *)
    log_error "command: $COMMAND"
    show_help
    exist 127
esac
