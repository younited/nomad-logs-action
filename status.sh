#!/usr/bin/env bash

set -o errexit
set -o pipefail

# Required environment variables
# NOMAD_JOB=""
# NOMAD_TOKEN=""
# NOMAD_ADDR=""
# NOMAD_NAMESPACE=""
# PARAMETERIZED_JOB="(true|false)"

function eval_variable {
  local var=$(eval "${1}")
  attempt_counter=0
  max_attempts=5

  until [[ ! -z "${var}" ]]; do
    if [[ "${attempt_counter}" -eq "${max_attempts}" ]]; then
      # Max attempts reached after 30 seconds
      exit 1
    fi
    attempt_counter=$((${attempt_counter} + 1))
    sleep 5
    local var=$(eval "${1}")
  done
  echo "${var}"
}

function wait_for_dead_job {
  local job_status=$(eval "${1}")
  attempt_counter=0
  max_attempts=9

  until [[ "${job_status}" =~ "dead" ]]; do
    if [[ "${attempt_counter}" -eq "${max_attempts}" ]]; then
      # Max attempts reached after 60 seconds
      exit 1
    fi
    attempt_counter=$((${attempt_counter} + 1))
    sleep 6
    local job_status=$(eval "${1}")
  done
}

TASK_CONTENT=()
TASK_STATUS=()
# Base url to access to the Nomad server
BASE_URL='curl -s -H "X-Nomad-Token: $NOMAD_TOKEN" $NOMAD_ADDR/v1'
# Nomad paths
PATH_DEPLOYMENT='job/$NOMAD_JOB/deployment'
PATH_ALLOCATIONS='job/$NOMAD_JOB/allocations'
PATH_LOGS='client/fs/logs'
# JQ filters
JQ_JOB_VERSION='jq -r ".JobVersion"'
JQ_JOB_STATUS='jq -r ".Status"'
JQ_ALLOC_MAP='jq --arg job_version "$job_version" -r ".[] |
  select(.JobVersion == $job_version) |
  {id: .ID, group: .TaskGroup, tasks: [.TaskStates|keys[]]}"'
JQ_ALLOC_MAP_PARAM='jq ".[] | {id: .ID, group: .TaskGroup, tasks: [.TaskStates|keys[]]}"'
JQ_TASK_DETAILS='jq --arg task "$task" -r ".TaskStates.\"$task\""'
JQ_DECODE_LOGS='jq -r ".Data | @base64d"'
# Build requests
REQ_JOB_VERSION="${BASE_URL}/${PATH_DEPLOYMENT}'?'namespace=${NOMAD_NAMESPACE}"'|'"${JQ_JOB_VERSION}"
REQ_FILTER_ALLOC="${BASE_URL}/${PATH_ALLOCATIONS}'?'namespace=${NOMAD_NAMESPACE}"'|'"${JQ_ALLOC_MAP}"
REQ_JOB_STATUS_PARAM="${BASE_URL}/job/${NOMAD_JOB}'?'namespace=${NOMAD_NAMESPACE}"'|'"${JQ_JOB_STATUS}"
REQ_FILTER_ALLOC_PARAM="${BASE_URL}/${PATH_ALLOCATIONS}'?'namespace=${NOMAD_NAMESPACE}"'|'"${JQ_ALLOC_MAP_PARAM}"

if [[ -z "${PARAMETERIZED_JOB}" || "${PARAMETERIZED_JOB}" == "false" ]]; then
  # Get latest job version from deployment
  job_version=$(eval_variable "${REQ_JOB_VERSION}")
  # Filter allocation by job version, then extract allocation id, taskgroup and task.
  filter_alloc=$(eval_variable "${REQ_FILTER_ALLOC}")
elif [[ "${PARAMETERIZED_JOB}" == "true" ]]; then
  # Filter allocation from parameterized job, then extract allocation id, taskgroup and task.
  wait_for_dead_job "${REQ_JOB_STATUS_PARAM}"
  filter_alloc=$(eval_variable "${REQ_FILTER_ALLOC_PARAM}")
fi

for id in $(echo "${filter_alloc}" | jq -r ".id"); do
  job_alloc_tasks=$(echo "${filter_alloc}" | jq --arg id "${id}" -r '. | select (.id == $id) | .tasks[]')
  job_alloc_group=$(echo "${filter_alloc}" | jq --arg id "${id}" -r '. | select (.id == $id) | .group')
  alloc_short_id=$(echo "${id}" | awk -F '-' '{print $1}')
  TASK_CONTENT+=$(printf "\n\nAllocation \"${alloc_short_id}\" (group ${job_alloc_group}):\n")

  for task in $job_alloc_tasks; do
    REQ_TASK_DETAILS="${BASE_URL}/allocation/${id}'?'namespace=${NOMAD_NAMESPACE}"'|'"${JQ_TASK_DETAILS}"
    while true; do
      task_details=$(eval_variable "${REQ_TASK_DETAILS}")
      get_task_state=$(echo "${task_details}" | jq -r ".State")
      get_exit_code=$(echo "${task_details}" | jq -r "[.Events[].Details.exit_code // empty]|unique|.[]")
      get_events_type=$(echo "${task_details}" | jq -r "[.Events[].Type|select(length > 0)]|unique|.[]")

      if [[ "${get_task_state}" == "running" || "${get_exit_code}" == 0 ]]; then
        if [[ -z "${PARAMETERIZED_JOB}" || "${PARAMETERIZED_JOB}" == "false" ]]; then
          TASK_CONTENT+=$(printf "\n✅ Task ${task} successfully deployed.\n")
        elif [[ "${PARAMETERIZED_JOB}" == "true" ]]; then
          REQ_STDOUT_LOGS="${BASE_URL}/${PATH_LOGS}/${id}'?'namespace=${NOMAD_NAMESPACE}'&'task=${task}'&'type=stdout"'|'"${JQ_DECODE_LOGS}"
          stdout_logs=$(eval_variable "${REQ_STDOUT_LOGS}")
          TASK_CONTENT+=$(printf "\n✅ Task ${task} successfully deployed:\n${stdout_logs}\n")
        fi
        TASK_STATUS+=_success
        break

      elif [[ ! "${get_task_state}" == "running" && "${get_exit_code}" == 1 ]]; then
        ignore_envoy='tail | grep -Fv -e "[info]" -e "deprecated"'
        REQ_ERR_LOGS="${BASE_URL}/${PATH_LOGS}/${id}'?'namespace=${NOMAD_NAMESPACE}'&'task=${task}'&'type=stderr"'|'"${JQ_DECODE_LOGS}"'|'"${ignore_envoy}"
        err_logs=$(eval_variable "${REQ_ERR_LOGS}")
        TASK_CONTENT+=$(printf "\n❌ Task ${task} failed:\n${err_logs}\n")
        TASK_STATUS+=_failure
        break

      elif [[ ! "${get_task_state}" == "running" && "${get_exit_code}" == 137 ]]; then
        if [[ -z "${PARAMETERIZED_JOB}" || "${PARAMETERIZED_JOB}" == "false" ]]; then
          TASK_CONTENT+=$(printf "\n❌ Task ${task} killed due to out-of-limit resources usage.\n")
          TASK_STATUS+=_failure
        fi
        break

      elif [[ ! "${get_task_state}" == "running" && "${get_events_type}" =~ "Driver Failure" ]]; then
        err_driver=$(echo "${task_details}" | jq -r "[.Events[].DriverError|select(length > 0)]|unique|.[]")
        TASK_STATUS+=_failure
        TASK_CONTENT+=$(printf "\n❌ Task ${task} failed:\n${err_driver}\n")
        break
      fi
      sleep 1
    done
  done
done

# Set action outputs
output_status=$(printf "%s\n" "${TASK_STATUS}" | tr "_" "\n" | sort -u | uniq)
output_content=$(printf "%s\n" "${TASK_CONTENT}" | sed '/./,$!d')
output_content="${output_content//'%'/'%25'}"
output_content="${output_content//$'\n'/'%0A'}"
output_content="${output_content//$'\r'/'%0D'}"

echo "::set-output name=content::${output_content}"
if [[ "${output_status}" =~ "failure" ]]; then
  echo "::set-output name=status::failure"
  exit 1
else
  echo "::set-output name=status::success"
fi
