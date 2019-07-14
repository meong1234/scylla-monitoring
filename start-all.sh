#!/usr/bin/env bash

CURRENT_VERSION=`cat CURRENT_VERSION.sh`
if [ "$CURRENT_VERSION" = "master" ]; then
    echo ""
    echo "*****************************************************"
    echo "* WARNING: You are using the unstable master branch *"
    echo "* Check the README.md file for the stable releases  *"
    echo "*****************************************************"
    echo ""
fi

if [ "$1" = "--version" ]; then
    cat CURRENT_VERSION.sh
    exit
fi

if [ "$1" = "-e" ]; then
. enterprise_versions.sh
else		
. versions.sh
fi
if [ "`id -u`" -eq 0 ]; then
    echo "Running as root is not advised, please check the documentation on how to run as non-root user"
else
    GROUPID=`id -g`
    USER_PERMISSIONS="-u $UID:$GROUPID"
fi
PROMETHEUS_RULES="$PWD/prometheus/prometheus.rules.yml"
VERSIONS=$DEFAULT_VERSION
usage="$(basename "$0") [-h] [--version] [-e] [-d Prometheus data-dir] [-G path to grafana data-dir] [-s scylla-target-file] [-n node-target-file] [-l] [-v comma separated versions] [-j additional dashboard to load to Grafana, multiple params are supported] [-c grafana environment variable, multiple params are supported] [-b Prometheus command line options] [-g grafana port ] [ -p prometheus port ] [-a admin password] [-m alertmanager port] [ -M scylla-manager version ] [-D encapsulate docker param] [-r alert-manager-config] [-R prometheus-alert-file] [-N manager target file] -- starts Grafana and Prometheus Docker instances"
PROMETHEUS_VERSION=v2.10.0

SCYLLA_TARGET_FILE=$PWD/prometheus/scylla_servers.yml
SCYLLA_MANGER_TARGET_FILE=$PWD/prometheus/scylla_manager_servers.yml
GRAFANA_ADMIN_PASSWORD=""
ALERTMANAGER_PORT=""
DOCKER_PARAM=""
DATA_DIR=""

while getopts ':hled:g:p:v:s:n:a:c:j:b:m:r:R:M:G:D:N:' option; do
  case "$option" in
    h) echo "$usage"
       exit
       ;;
    v) VERSIONS=$OPTARG
       ;;
    M) MANAGER_VERSION=$OPTARG
       ;;
    d) DATA_DIR=$OPTARG
       ;;
    G) EXTERNAL_VOLUME="-G $OPTARG"
       ;;
    r) ALERT_MANAGER_RULE_CONFIG="-r $OPTARG"
       ;;
    R) PROMETHEUS_RULES=`readlink -m $OPTARG`
       ;;
    g) GRAFANA_PORT="-g $OPTARG"
       ;;
    m) ALERTMANAGER_PORT="-p $OPTARG"
       ;;
    p) PROMETHEUS_PORT=$OPTARG
       ;;
    s) SCYLLA_TARGET_FILE=$OPTARG
       ;;
    n) NODE_TARGET_FILE=$OPTARG
       ;;
    l) DOCKER_PARAM="$DOCKER_PARAM --net=host"
       ;;
    a) GRAFANA_ADMIN_PASSWORD="-a $OPTARG"
       ;;
    j) GRAFANA_DASHBOARD_ARRAY+=("$OPTARG")
       ;;
    c) GRAFANA_ENV_ARRAY+=("$OPTARG")
       ;;
    D) DOCKER_PARAM="$DOCKER_PARAM $OPTARG"
       ;;
    b) PROMETHEUS_COMMAND_LINE_OPTIONS_ARRAY+=("$OPTARG")
       ;;
    N) SCYLLA_MANGER_TARGET_FILE="$OPTARG"
       ;;
    :) printf "missing argument for -%s\n" "$OPTARG" >&2
       echo "$usage" >&2
       exit 1
       ;;
   \?) printf "illegal option: -%s\n" "$OPTARG" >&2
       echo "$usage" >&2
       exit 1
       ;;
  esac
done

if [ -z $NODE_TARGET_FILE ]; then
   NODE_TARGET_FILE=$SCYLLA_TARGET_FILE
fi

if [ ! -f $SCYLLA_TARGET_FILE ]; then
    echo "Scylla target file '${SCYLLA_TARGET_FILE}' does not exist, you can use prometheus/scylla_servers.example.yml as an example."
    exit 1
fi

if [ ! -f $NODE_TARGET_FILE ]; then
    echo "Node target file '${NODE_TARGET_FILE}' does not exist"
    exit 1
fi

if [ ! -f $SCYLLA_MANGER_TARGET_FILE ]; then
    echo "Scylla-Manager target file '${SCYLLA_MANGER_TARGET_FILE}' does not exist, you can use prometheus/scylla_manager_servers.example.yml as an example."
    exit 1
fi

SCYLLA_TARGET_FILE="-v "$(readlink -m $SCYLLA_TARGET_FILE)":/etc/scylla.d/prometheus/scylla_servers.yml:Z"
SCYLLA_MANGER_TARGET_FILE="-v "$(readlink -m $SCYLLA_MANGER_TARGET_FILE)":/etc/scylla.d/prometheus/scylla_manager_servers.yml:Z"
NODE_TARGET_FILE="-v "$(readlink -m $NODE_TARGET_FILE)":/etc/scylla.d/prometheus/node_exporter_servers.yml:Z"

if [[ $DOCKER_PARAM = *"--net=host"* ]]; then
    if [ ! -z "$ALERTMANAGER_PORT" ] || [ ! -z "$GRAFANA_PORT" ] || [ ! -z $PROMETHEUS_PORT ]; then
        echo "Port mapping is not supported with host network, remove the -l flag from the command line"
        exit 1
    fi
    HOST_NETWORK=1
fi

echo "Wait for alert manager container to start"

AM_ADDRESS=`./start-alertmanager.sh $ALERTMANAGER_PORT -D "$DOCKER_PARAM" $ALERT_MANAGER_RULE_CONFIG`
if [ $? -ne 0 ]; then
    echo "$AM_ADDRESS"
    exit 1
fi
if [ -z $PROMETHEUS_PORT ]; then
    PROMETHEUS_PORT=9090
    PROMETHEUS_NAME=aprom
else
    PROMETHEUS_NAME=aprom-$PROMETHEUS_PORT
fi

docker container inspect $PROMETHEUS_NAME > /dev/null 2>&1
if [ $? -eq 0 ]; then
    printf "\nSome of the monitoring docker instances ($PROMETHEUS_NAME) exist. Make sure all containers are killed and removed. You can use kill-all.sh for that\n"
    exit 1
fi


# Exit if Docker engine is not running
if [ ! "$(docker ps)" ]
then
        echo "Error: Docker engine is not running"
        exit 1
fi

for val in "${PROMETHEUS_COMMAND_LINE_OPTIONS_ARRAY[@]}"; do
    PROMETHEUS_COMMAND_LINE_OPTIONS+=" -$val"
done

mkdir -p $PWD/prometheus/build/
sed "s/AM_ADDRESS/$AM_ADDRESS/" $PWD/prometheus/prometheus.yml.template > $PWD/prometheus/build/prometheus.yml

if [ -z $HOST_NETWORK ]; then
    PORT_MAPPING="-p $PROMETHEUS_PORT:9090"
fi

if [ -z $DATA_DIR ]
then
    USER_PERMISSIONS=""
else
    if [ -d $DATA_DIR ]; then
        echo "Loading prometheus data from $DATA_DIR"
    else
        echo "Creating data directory $DATA_DIR"
        mkdir -p $DATA_DIR
    fi
    DATA_DIR="-v "$(readlink -m $DATA_DIR)":/prometheus/data:Z"
fi

docker run -d $DOCKER_PARAM $USER_PERMISSIONS \
     $DATA_DIR \
     -v $PWD/prometheus/build/prometheus.yml:/etc/prometheus/prometheus.yml:Z \
     -v $PROMETHEUS_RULES:/etc/prometheus/prometheus.rules.yml:Z \
     $SCYLLA_TARGET_FILE \
     $SCYLLA_MANGER_TARGET_FILE \
     $NODE_TARGET_FILE \
     $PORT_MAPPING --name $PROMETHEUS_NAME prom/prometheus:$PROMETHEUS_VERSION  --config.file=/etc/prometheus/prometheus.yml $PROMETHEUS_COMMAND_LINE_OPTIONS >& /dev/null

if [ $? -ne 0 ]; then
    echo "Error: Prometheus container failed to start"
    echo "For more information use: docker logs $PROMETHEUS_NAME"
    exit 1
fi
if [ "$VERSIONS" = "latest" ]; then
	VERSIONS=$LATEST
else
	if [ "$VERSIONS" = "all" ]; then
		VERSIONS=$ALL
	fi
fi

# Number of retries waiting for a Docker container to start
RETRIES=7

# Wait till Prometheus is available
printf "Wait for Prometheus container to start."
TRIES=0
until $(curl --output /dev/null -f --silent http://localhost:$PROMETHEUS_PORT) || [ $TRIES -eq $RETRIES ]; do
    printf '.'
    ((TRIES=TRIES+1))
    sleep 5
done
echo

if [ ! "$(docker ps -q -f name=$PROMETHEUS_NAME)" ]
then
        echo "Error: Prometheus container failed to start"
        echo "For more information use: docker logs $PROMETHEUS_NAME"
        exit 1
fi

# Can't use localhost here, because the monitoring may be running remotely.
# Also note that the port to which we need to connect is 9090, regardless of which port we bind to at localhost.
DB_ADDRESS="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $PROMETHEUS_NAME):9090"

for val in "${GRAFANA_ENV_ARRAY[@]}"; do
        GRAFANA_ENV_COMMAND="$GRAFANA_ENV_COMMAND -c $val"
done

for val in "${GRAFANA_DASHBOARD_ARRAY[@]}"; do
        GRAFANA_DASHBOARD_COMMAND="$GRAFANA_DASHBOARD_COMMAND -j $val"
done

./start-grafana.sh -p $DB_ADDRESS -D "$DOCKER_PARAM" $GRAFANA_PORT $EXTERNAL_VOLUME -m $AM_ADDRESS -M $MANAGER_VERSION -v $VERSIONS $GRAFANA_ENV_COMMAND $GRAFANA_DASHBOARD_COMMAND $GRAFANA_ADMIN_PASSWORD
