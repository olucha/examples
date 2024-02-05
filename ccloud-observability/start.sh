#!/bin/bash

NAME=`basename "$0"`
# Setting default QUIET=false to surface potential errors
QUIET="${QUIET:-false}"
[[ $QUIET == "true" ]] && 
  REDIRECT_TO="/dev/null" ||
  REDIRECT_TO="/dev/tty"

# Source library
source ../utils/helper.sh
source ../utils/ccloud_library.sh

check_jq \
  && print_pass "jq found"

[[ -z "$AUTO" ]] && {
  printf "\n====== Confirm\n\n"
  ccloud::prompt_continue_ccloud_demo || exit 1
} 

ccloud::validate_version_cli $CLI_MIN_VERSION \
  && print_pass "Confluent CLI version ok"

ccloud::validate_logged_in_cli \
  && print_pass "Logged into the Confluent CLI" 

print_pass "Prerequisite check pass"

printf "\n====== Starting\n\n"

printf "\n====== Creating new Confluent Cloud stack using the ccloud::create_ccloud_stack function\nSee: %s for details\n" "https://github.com/confluentinc/examples/blob/$CONFLUENT_RELEASE_TAG_OR_BRANCH/utils/ccloud_library.sh"
export EXAMPLE="ccloud-observability"
ccloud::create_ccloud_stack false  \
	&& print_code_pass -c "ccloud::create_ccloud_stack false"

SERVICE_ACCOUNT_ID=$(ccloud:get_service_account_from_current_cluster_name)
CONFIG_FILE=stack-configs/java-service-account-$SERVICE_ACCOUNT_ID.config
export CONFIG_FILE=$CONFIG_FILE
ccloud::validate_ccloud_config $CONFIG_FILE || exit 1

ccloud::generate_configs $CONFIG_FILE \
	&& print_code_pass -c "ccloud::generate_configs $CONFIG_FILE"

DELTA_CONFIGS_ENV=delta_configs/env.delta
printf "\nSetting local environment based on values in $DELTA_CONFIGS_ENV\n"
CMD="source $DELTA_CONFIGS_ENV"
eval $CMD \
    && print_code_pass -c "source $DELTA_CONFIGS_ENV" \
    || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3))

##################################################
# Start up monitoring
##################################################
echo -e "\n====== Create cloud api-key and set environment variables for the Metrics API endpoint /export"
echo "confluent api-key create --resource cloud --description \"confluent-cloud-metrics-api\" -o json"
OUTPUT=$(confluent api-key create --resource cloud --description "confluent-cloud-metrics-api" -o json)
status=$?
if [[ $status != 0 ]]; then
  echo "ERROR: Failed to create an API key.  Please troubleshoot and run again"
  exit 1
fi
echo "$OUTPUT" | jq .
export METRICS_API_KEY=$(echo "$OUTPUT" | jq -r ".api_key")
export METRICS_API_SECRET=$(echo "$OUTPUT" | jq -r ".api_secret")
export CLOUD_CLUSTER=$(confluent kafka cluster describe -o json |  jq -c '[.id]')
export LAG_EXPORTER_ID=$CLUSTER
export CLOUD_CONNECTORS=$(confluent connect cluster list -o json | jq -c '. | map(.id)')
export CLOUD_KSQLDB_APPS=$(confluent ksql cluster list -o json |  jq -c '. | map(.id)')
export CLOUD_SCHEMA_REGISTRY=$(confluent schema-registry cluster describe -o json |  jq -c '[.cluster_id]')
export CLUSTER_REST_ENDPOINT=$(confluent kafka cluster describe -o json |  jq -r '.rest_endpoint')
export ENVIRONMENT=$(confluent environment list -o json|jq -r '.[] | select(.is_current==true) | .id')

rm .env 2>/dev/null

echo "CONFIG_FILE=$CONFIG_FILE" >> .env
echo "SERVICE_ACCOUNT_ID=$SERVICE_ACCOUNT_ID" >> .env
echo "METRICS_API_KEY=$METRICS_API_KEY" >> .env
echo "METRICS_API_SECRET=$METRICS_API_SECRET" >> .env
echo "CLOUD_CLUSTER=$CLOUD_CLUSTER" >> .env
echo "LAG_EXPORTER_ID=$LAG_EXPORTER_ID" >> .env
echo "BOOTSTRAP_SERVERS=$BOOTSTRAP_SERVERS" >> .env
echo "SASL_JAAS_CONFIG=$SASL_JAAS_CONFIG" >> .env
echo "CLOUD_CONNECTORS=$CLOUD_CONNECTORS" >> .env
echo "CLOUD_KSQLDB_APPS=$CLOUD_KSQLDB_APPS" >> .env
echo "CLOUD_SCHEMA_REGISTRY=$CLOUD_SCHEMA_REGISTRY" >> .env
echo "CLUSTER_REST_ENDPOINT=$CLUSTER_REST_ENDPOINT" >> .env
echo "ENVIRONMENT=$ENVIRONMENT" >> .env
echo "CLOUD_KEY=$CLOUD_KEY" >> .env
echo "CLOUD_SECRET=$CLOUD_SECRET" >> .env

# Create custom prometheus.yml from prometheus.template.yml.
# The resulting prometheus.yml will necessarily contain secrets, and is .gitignore-d .
# Prometheus does not support env/variables in config yaml, https://github.com/prometheus/prometheus/issues/2357
# Use yq instead to create from template
docker run -i --rm --env-file .env mikefarah/yq '
  (.scrape_configs[] | select(.job_name == "api-keys") | .static_configs.[0].targets) += 
    ("https://api.confluent.cloud/service-quota/v1/applied-quotas/kafka.max_api_keys.per_cluster?scope=kafka_cluster&environment=${ENVIRONMENT}&kafka_cluster=${LAG_EXPORTER_ID}" | envsubst) |
  (.scrape_configs[] | select(.job_name == "connect-tasks") | .static_configs.[0].targets) += 
    ("https://api.confluent.cloud/connect/v1/environments/${ENVIRONMENT}/clusters/${LAG_EXPORTER_ID}/connectors?expand=status" | envsubst) |
  (.scrape_configs[] | select(.job_name == "acls") | .static_configs.[0].targets) += 
    ("${CLUSTER_REST_ENDPOINT}/kafka/v3/clusters/${LAG_EXPORTER_ID}/acls?resource_type=ANY&pattern_type=ANY&operation=ANY&permission=ANY" | envsubst)
' < monitoring_configs/prometheus/prometheus.template.yml > monitoring_configs/prometheus/prometheus.yml

# Create custom config.yml from config.template.yml.
# The resulting config.yml will necessarily contain secrets, and is .gitignore-d .
# JSON Exporter does not support env/variables in config yaml
# Use yq instead to create from template
docker run -i --rm --env-file .env mikefarah/yq '
  with(.modules.[].http_client_config; . |
    .basic_auth.username = env(METRICS_API_KEY) |
    .basic_auth.password = env(METRICS_API_SECRET)
  ) |
  with(.modules["acls"].http_client_config; . |
    .basic_auth.username = env(CLOUD_KEY) |
    .basic_auth.password = env(CLOUD_SECRET)
  )
' < monitoring_configs/json-exporter/config.template.yml > monitoring_configs/json-exporter/config.yml

echo -e "\n====== Starting up Prometheus, Grafana, exporters, and clients"
echo "docker compose up -d"
docker compose up -d
echo -e "\n====== Login to Grafana at http://localhost:3000/ un:admin pw:password"
echo -e "\n====== Query metrics in Prometheus at http://localhost:9090 (verify targets are being scraped at http://localhost:9090/targets/, may take a few minutes to start up)"

echo
echo "Confluent Cloud Environment:"
echo
echo "  export CONFIG_FILE=$CONFIG_FILE"
echo "  export SERVICE_ACCOUNT_ID=$SERVICE_ACCOUNT_ID"
echo "  export METRICS_API_KEY=$METRICS_API_KEY"
echo "  export METRICS_API_SECRET=$METRICS_API_SECRET"
echo "  export CLOUD_CLUSTER=$CLOUD_CLUSTER"
echo "  export LAG_EXPORTER_ID=$LAG_EXPORTER_ID"
echo "  export BOOTSTRAP_SERVERS=$BOOTSTRAP_SERVERS"
echo "  export SASL_JAAS_CONFIG=$SASL_JAAS_CONFIG"
echo "  export CLOUD_CONNECTORS=$CLOUD_CONNECTORS"
echo "  export CLOUD_KSQLDB_APPS=$CLOUD_KSQLDB_APPS"
echo "  export CLOUD_SCHEMA_REGISTRY=$CLOUD_SCHEMA_REGISTRY"
