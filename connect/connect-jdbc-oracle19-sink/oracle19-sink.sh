#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

export ORACLE_IMAGE="oracle/database:19.3.0-ee"

if test -z "$(docker images -q $ORACLE_IMAGE)"
then
    if [ ! -z "$CI" ]
    then
        if [ ! -f ${DIR}/LINUX.X64_193000_db_home.zip ]
        then
            # running with github actions
            aws s3 cp --only-show-errors s3://kafka-docker-playground/3rdparty/LINUX.X64_193000_db_home.zip .
        fi
    fi
    if [ ! -f ${DIR}/LINUX.X64_193000_db_home.zip ]
    then
        logerror "ERROR: ${DIR}/LINUX.X64_193000_db_home.zip is missing. It must be downloaded manually in order to acknowledge user agreement"
        exit 1
    fi
    log "Building $ORACLE_IMAGE docker image..it can take a while...(more than 15 minutes!)"
    OLDDIR=$PWD
    rm -rf ${DIR}/docker-images
    git clone https://github.com/oracle/docker-images.git

    mv ${DIR}/LINUX.X64_193000_db_home.zip ${DIR}/docker-images/OracleDatabase/SingleInstance/dockerfiles/19.3.0/LINUX.X64_193000_db_home.zip
    cd ${DIR}/docker-images/OracleDatabase/SingleInstance/dockerfiles
    ./buildContainerImage.sh -v 19.3.0 -e
    rm -rf ${DIR}/docker-images
    cd ${OLDDIR}
fi

if [ ! -z "$CONNECTOR_TAG" ]
then
     JDBC_CONNECTOR_VERSION=$CONNECTOR_TAG
else
     JDBC_CONNECTOR_VERSION=$(docker run vdesabou/kafka-docker-playground-connect:${CONNECT_TAG} cat /usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/manifest.json | jq -r '.version')
fi
log "JDBC Connector version is $JDBC_CONNECTOR_VERSION"
if ! version_gt $JDBC_CONNECTOR_VERSION "9.9.9"; then
     if [ ! -z "$CI" ]
     then
          # running with github actions
          aws s3 cp --only-show-errors s3://kafka-docker-playground/3rdparty/ojdbc8.jar .
     fi
     if [ ! -f ${DIR}/ojdbc8.jar ]
     then
          logerror "ERROR: ${DIR}/ojdbc8.jar is missing. It must be downloaded manually in order to acknowledge user agreement"
          exit 1
     fi
     ${DIR}/../../environment/plaintext/start.sh "${PWD}/docker-compose.plaintext.yml"
else
     log "ojdbc jar is shipped with connector (starting with 10.0.0)"
     ${DIR}/../../environment/plaintext/start.sh "${PWD}/docker-compose.plaintext.no-ojdbc.yml"
fi


# Verify Oracle DB has started within MAX_WAIT seconds
MAX_WAIT=2500
CUR_WAIT=0
log "Waiting up to $MAX_WAIT seconds for Oracle DB to start"
docker container logs oracle > /tmp/out.txt 2>&1
while [[ ! $(cat /tmp/out.txt) =~ "DONE: Executing user defined scripts" ]]; do
sleep 10
docker container logs oracle > /tmp/out.txt 2>&1
CUR_WAIT=$(( CUR_WAIT+10 ))
if [[ "$CUR_WAIT" -gt "$MAX_WAIT" ]]; then
     logerror "ERROR: The logs in oracle container do not show 'DONE: Executing user defined scripts' after $MAX_WAIT seconds. Please troubleshoot with 'docker container ps' and 'docker container logs'.\n"
     exit 1
fi
done
log "Oracle DB has started!"

log "Creating Oracle sink connector"

curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
               "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
                    "tasks.max": "1",
                    "connection.user": "myuser",
                    "connection.password": "mypassword",
                    "connection.url": "jdbc:oracle:thin:@oracle:1521/ORCLPDB1",
                    "topics": "ORDERS",
                    "auto.create": "true",
                    "insert.mode":"insert",
                    "auto.evolve":"true"
          }' \
     http://localhost:8083/connectors/oracle-sink/config | jq .


log "Sending messages to topic ORDERS"
docker exec -i connect kafka-avro-console-producer --broker-list broker:9092 --property schema.registry.url=http://schema-registry:8081 --topic ORDERS --property value.schema='{"type":"record","name":"myrecord","fields":[{"name":"id","type":"int"},{"name":"product", "type": "string"}, {"name":"quantity", "type": "int"}, {"name":"price",
"type": "float"}]}' << EOF
{"id": 999, "product": "foo", "quantity": 100, "price": 50}
EOF

sleep 5


log "Show content of ORDERS table:"
docker exec oracle bash -c "echo 'select * from ORDERS;' | sqlplus myuser/mypassword@//localhost:1521/ORCLPDB1" > /tmp/result.log  2>&1
cat /tmp/result.log
grep "foo" /tmp/result.log

