#!/usr/bin/env bash

set -o errexit

export DEMO_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

while getopts ":a:p:t:" opt; do
  case ${opt} in
    a )
      IP=${OPTARG}
      ;;
    p )
      HTTP_PORT=${OPTARG}
      ;;
    t )
      TLS_PORT=${OPTARG}
      ;;
    \? ) echo "Usage: $(basename $0) [-a IPADRESS] [-p STARTING_HTTP_PORT] [-t STARTING_TLS_PORT]"
         echo " If no address is provided, 192.168.130.1 is used"
	 echo " If no starting port is provided 8080 and 8443 are used"
         echo " Port numbers are increased by 100 for each subsequent cluster"
	 exit 0
   esac
done

# this can be done on mac with `kern.maxfiles=` but is not required.
echo " It is recommended to increase OS file watches before running the demo, e.g.:"
# echo " $ sudo sysctl -w fs.inotify.max_user_watches=2097152"
# echo " $ sudo sysctl -w fs.inotify.max_user_instances=256"

IP=${IP:-192.168.130.1}
HTTP_PORT=${HTTP_PORT:-8080}
TLS_PORT=${TLS_PORT:-8443}

RUN_DIR=${DEMO_DIR}/.demo
REGISTRATION_OPERATOR=/Users/varshaprasadnarsing/go/src/github.com/varshaprasad96/registration-operator
mkdir -p ${RUN_DIR}

wait_command() {
  local command="$1";
  local wait_seconds="${2:-40}"; # 40 seconds as default timeout
  until [[ $((wait_seconds--)) -eq 0 ]] || eval "$command 2>/dev/null" ; do sleep 1 && echo -n "."; done
  echo ""
  ((++wait_seconds))
}

# hub cluster configuration
yq ".networking.apiServerAddress = \"${IP}\"" ${DEMO_DIR}/kind.cfg  > ${RUN_DIR}/hub.cfg
yq -i ".nodes[0].extraPortMappings[0].hostPort = ${HTTP_PORT}" ${RUN_DIR}/hub.cfg
yq -i ".nodes[0].extraPortMappings[1].hostPort = ${TLS_PORT}" ${RUN_DIR}/hub.cfg

# spoke 1 configuration
yq ".networking.apiServerAddress = \"${IP}\"" ${DEMO_DIR}/kind.cfg  > ${RUN_DIR}/spoke1.cfg
yq -i ".nodes[0].extraPortMappings[0].hostPort = $((HTTP_PORT + 100))" ${RUN_DIR}/spoke1.cfg
yq -i ".nodes[0].extraPortMappings[1].hostPort = $((TLS_PORT + 100))" ${RUN_DIR}/spoke1.cfg

# spoke 2 configuration
yq ".networking.apiServerAddress = \"${IP}\"" ${DEMO_DIR}/kind.cfg  > ${RUN_DIR}/spoke2.cfg
yq -i ".nodes[0].extraPortMappings[0].hostPort = $((HTTP_PORT + 200))" ${RUN_DIR}/spoke2.cfg
yq -i ".nodes[0].extraPortMappings[1].hostPort = $((TLS_PORT + 200))" ${RUN_DIR}/spoke2.cfg

echo "Creating kind clusters"
kind create cluster --name hub --kubeconfig ${RUN_DIR}/hub.kubeconfig --config ${RUN_DIR}/hub.cfg
kind create cluster --name spoke1 --kubeconfig ${RUN_DIR}/spoke1.kubeconfig --config ${RUN_DIR}/spoke1.cfg
kind create cluster --name spoke2 --kubeconfig ${RUN_DIR}/spoke2.kubeconfig --config ${RUN_DIR}/spoke2.cfg
echo "clusters deployed successfully"

echo "Deploying OCM registration operator"
pushd ${RUN_DIR}

pushd ${REGISTRATION_OPERATOR}
echo "deploying hub and spoke clusters"
export IMAGE_TAG=v0.10.0
KUBECONFIG=${RUN_DIR}/hub.cfg make deploy-hub
KUBECONFIG=${RUN_DIR}/spoke1.cfg  MANAGED_CLUSTER_NAME=spoke1 make deploy-spoke
KUBECONFIG=${RUN_DIR}/spoke2.cfg  MANAGED_CLUSTER_NAME=spoke2 make deploy-spoke

echo "OCM deployed successfully"

popd
popd

wait_command '[ $(KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get csr -o name | wc -l) -eq 2 ]'
if [ $(KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get csr -o name | wc -l) -ne 2 ]; then
  echo "CSR missing for the registration of the spoke clusters"
  exit 1
fi

KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get csr -o name | xargs kubectl certificate approve --kubeconfig=${RUN_DIR}/hub.kubeconfig
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl patch managedclusters spoke1 --type='merge' -p '{"spec":{"hubAcceptsClient":true}}'
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl patch managedclusters spoke2 --type='merge' -p '{"spec":{"hubAcceptsClient":true}}'

caBundle1=$(KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get managedclusters spoke1 -o jsonpath='{.spec.managedClusterClientConfigs[].caBundle}')
url1=$(KUBECONFIG=${RUN_DIR}/spoke1.kubeconfig kubectl config view -o jsonpath='{.clusters[].cluster.server}')
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl patch managedclusters spoke1 --type='merge' -p "{\"spec\":{\"managedClusterClientConfigs\": [{\"caBundle\":\"${caBundle1}\", \"url\":\"${url1}\"}]}}"

caBundle2=$(KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get managedclusters spoke2 -o jsonpath='{.spec.managedClusterClientConfigs[].caBundle}')
url2=$(KUBECONFIG=${RUN_DIR}/spoke2.kubeconfig kubectl config view -o jsonpath='{.clusters[].cluster.server}')
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl patch managedclusters spoke2 --type='merge' -p "{\"spec\":{\"managedClusterClientConfigs\": [{\"caBundle\":\"${caBundle2}\", \"url\":\"${url2}\"}]}}"

