#!/bin/bash
set -euxo pipefail

USAGE="$0 <project> <organization> <iata> <api-key>"
PROJECT=${1:?Please provide the GCP project (e.g., mlab-sandbox): ${USAGE}}
ORG=${2:?Please provide the organization (e.g., mlab): ${USAGE}}
IATA=${3:?Please provide the IATA code (e.g., lga): ${USAGE}}
API_KEY=${4:?Please provide the API key: ${USAGE}}

VM_ZONE="us-central1-a"
VM_NAME="autonode"
DOCKER_COMPOSE_FILE_PATH="examples/ndt-fullstack.yml"
LOCATE_URL="locate-dot-${PROJECT}.appspot.com"
SA_ACCOUNT="autonode@${PROJECT}.iam.gserviceaccount.com"

# NOTE: We don't use the VM's default credentials because we want to simulate
# how a non-GCP user would set up an autonode. Instead, we generate a temporary
# key for the autonode service account that will only exist until the next
# deployment.

# Delete any existing keys for the autonode SA. Ignore failures due to
# system-managed keys that cannot be deleted.
for key in $(gcloud iam service-accounts keys list \
    --iam-account=${SA_ACCOUNT} | \
    cut -f1 -d " " | tail -n +2)
do
    gcloud iam service-accounts keys delete --iam-account=${SA_ACCOUNT} ${key} -q || true
done

# Create a new key.
gcloud iam service-accounts keys create key.json \
    --iam-account=${SA_ACCOUNT}
SA_KEY=$(<key.json)

# Copy the docker compose file to the VM.
gcloud --project ${PROJECT} compute scp ${DOCKER_COMPOSE_FILE_PATH} ${VM_NAME}:~/docker-compose.yml --tunnel-through-iap

# Setup script. This stops docker compose, creates the required folders, writes
# the SA key, re-creates the .env file and restarts docker compose.
gcloud --project ${PROJECT} compute ssh --zone ${VM_ZONE} ${VM_NAME} --tunnel-through-iap <<EOF
    set -euxo pipefail
    # Create volume folders if not present.
    mkdir -p autocert autonode certs html schemas resultsdir

    # Stop the docker compose if it's running.
    docker compose -f docker-compose.yml down

    # Create .env file
    rm .env || true
    echo "API_KEY=${API_KEY}" >> .env
    echo "ORGANIZATION=${ORG}" >> .env
    echo "PROJECT=${PROJECT}" >> .env
    echo "IATA=${IATA}" >> .env
    echo "LOCATE_URL=${LOCATE_URL}" >> .env

    # Write service account key to the expected file.
    echo "${SA_KEY}" > certs/service-account-autojoin.json

    # Start the docker compose again.
    docker compose -f docker-compose.yml up -d
EOF

