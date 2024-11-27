#!/bin/bash
set -euxo pipefail

USAGE="$0 <project> <docker-tag> <organization> <api-key> <probability>"
PROJECT=${1:?Please provide the GCP project (e.g., mlab-sandbox): ${USAGE}}
DOCKER_TAG=${2:?Please provide the Docker tag to deploy: ${USAGE}}
ORG=${3:?Please provide the organization (e.g., mlab): ${USAGE}}
API_KEY=${4:?Please provide the API key: ${USAGE}}
PROBABILITY=${5:?Please provide the probability: ${USAGE}}

IATA="oma"
VM_ZONE="us-central1-c"
VM_NAME="autonode"
DOCKER_COMPOSE_FILE_PATH="examples/ndt-fullstack.yml"
INTERFACE_NAME="ens4"
INTERFACE_MAXRATE="150000000"
SA_ACCOUNT="autonode@${PROJECT}.iam.gserviceaccount.com"

LOCATE_URL="locate-dot-${PROJECT}.appspot.com"
if [ "$PROJECT" = "mlab-autojoin" ]; then
  LOCATE_URL="locate.measurementlab.net"
fi

if test -f ${DOCKER_COMPOSE_FILE_PATH}; then
  # NOTE: we will treat the M-Lab deployment as authoritative. New schemas will be
  # deployed to GCS.
  # NOTE: backward compatible schema updates will not impact other organization
  # deployments. However, if there are breaking changes, all autonode deployments
  # that are pinned to earlier schemas will break.
  sed -i -e 's/-upload-schema=false/-upload-schema=true/' ${DOCKER_COMPOSE_FILE_PATH}
fi

# Copy the docker compose file to the VM.
gcloud --project ${PROJECT} compute scp --zone ${VM_ZONE} ${DOCKER_COMPOSE_FILE_PATH} autonode@${VM_NAME}:~/docker-compose.yml --tunnel-through-iap

# Setup script. This stops docker compose, creates the required folders,
# creates the .env file and restarts docker compose.
gcloud --project ${PROJECT} compute ssh --zone ${VM_ZONE} autonode@${VM_NAME} --tunnel-through-iap <<EOF
    set -euxo pipefail
    whoami
    # Enable BBR.
    sudo modprobe tcp_bbr

    # Stop the docker compose if it's running.
    docker compose --profile ndt -f docker-compose.yml down

    # Find the external v4 and v6 addresses for this machine.
    IPV4=\$(curl -s ipinfo.io/ip)
    IPV6=\$(curl -s -6 v6.ipinfo.io/ip)

    # Create .env file
    rm .env || true
    echo "DOCKER_TAG=${DOCKER_TAG}" >> .env
    echo "API_KEY=${API_KEY}" >> .env
    echo "ORGANIZATION=${ORG}" >> .env
    echo "PROJECT=${PROJECT}" >> .env
    echo "IATA=${IATA}" >> .env
    echo "LOCATE_URL=${LOCATE_URL}" >> .env
    echo "PROBABILITY=${PROBABILITY}" >> .env
    echo "INTERFACE_NAME=${INTERFACE_NAME}" >> .env
    echo "INTERFACE_MAXRATE=${INTERFACE_MAXRATE}" >> .env
    echo "IPV4=\$IPV4" >> .env
    echo "IPV6=\$IPV6" >> .env
    echo "TYPE=virtual" >> .env
    echo "UPLINK=1g" >> .env

    # Start the docker compose again.
    docker compose --profile ndt -f docker-compose.yml up -d

EOF
