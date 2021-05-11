#!/usr/bin/env bash

# Default hook functions named starting with _, e.g. _init(), _start(), etc.
# Specific roles can override the default hooks like:
#   start() {
#     _start
#     ...
#   }
#
# Specific hooks will be executed if exist, otherwise the default ones.

readonly APPCTL_ERR_CODES="
EC_CHECK_INACTIVE
EC_CHECK_PORT_ERR
EC_CHECK_PROTO_ERR
EC_ENV_ERR
EC_CHECK_HTTP_REQ_ERR
EC_CHECK_HTTP_CODE_ERR
"

command=$1
args="${@:2}"

buildErrorCodes() {
  local i=0 code; for code in ${@:2}; do
    readonly ${code}=$(( $1 + $i ))
    i=$(( $i + 1 ))
  done
}

isDev() {
  [ "$APPCTL_ENV" == "dev" ]
}

log() {
  if [ "$1" == "--debug" ]; then
    isDev || return 0
    shift
  fi
  logger -S 5000 -t appctl --id=$$ -- "[cmd=$command args='$args'] $@"
}
 
retry() {
  local tried=0
  local maxAttempts=$1
  local interval=$2
  local stopCodes=$3
  local cmd="${@:4}"
  local retCode=0
  while [ $tried -lt $maxAttempts ]; do
    $cmd && return 0 || {
      retCode=$?
      if [[ ",$stopCodes," == *",$retCode,"* ]]; then
        log "'$cmd' returned with stop code '$retCode'. Stopping ..."
        return $retCode
      fi
    }
    sleep $interval
    tried=$((tried+1))
  done

  log "'$cmd' still returned errors after $tried attempts. Stopping ..."
  return $retCode
}

rotate() {
  local maxFilesCount=5 method=cp
  if [ "$1" = "-m" ]; then method=mv; shift; fi
  for path in $@; do
    for i in $(seq 1 $maxFilesCount | tac); do
      if [ -f "${path}.$i" ]; then mv ${path}.$i ${path}.$(($i+1)); fi
    done
    if [ -f "$path" ]; then $method $path ${path}.1; fi
  done
}

execute() {
  local cmd=$1; log --debug "Executing command ..."
  [ "$(type -t $cmd)" = "function" ] || cmd=_$cmd
  $cmd ${@:2}
}

applyEnvFiles() {
  local f; for f in $(find /opt/app/current/bin/envs -name "*.env"); do . $f; done
}

applyRoleScripts() {
  local fileNames="${NODE_CTL:-*-ctl}"
  local f; for f in $(find /opt/app/current/bin/node/ -name "$fileNames.sh"); do . $f; done
}

checkEnv() {
  test -n "$1"
}

checkMounts() {
  test -n "${MY_HYPER_TYPE}" || {
    log "ERROR: MY_HYPER_TYPE variable is required to be set. "
    return 1
  }
  test -n "${DATA_MOUNTS+x}" || {
    log "ERROR: DATA_MOUNTS variable is required to be set. "
    return 1
  }
  case $MY_HYPER_TYPE in
  kvm)
      local dataDir; for dataDir in $DATA_MOUNTS; do
        grep -qs " $dataDir " /proc/mounts || {
          log "ERROR: Failed to mount disk . "
          return 1
        }
      done
  ;;
  lxc)
      local dataDir; for dataDir in $DATA_MOUNTS; do
        dataDir=$(echo $dataDir|tr -s [:space:])
        if [ -d $dataDir ]; then
	         : 
       	else
	         log "ERROR: $dataDir is not found in this container . "
	         return 1
       	fi
      done
  ;;
  *)
      log "ERROR: unrecognized hyper type: $MY_HYPER_TYPE. "
      return 1
  ;;
  esac
}

getServices() {
  if [ "$1" = "-a" ]; then
    echo $SERVICES
  else
    echo $SERVICES | xargs -n1 | awk -F/ '$2=="true"' | xargs
  fi
}

isSvcEnabled() {
  local svc="${1%%/*}"
  [ "$(echo $(getServices -a) | xargs -n1 | awk -F/ '$1=="'$svc'" {print $2}')" = "true" ]
}

checkActive() {
  systemctl is-active -q $1
}

checkEndpoint() {
  local proto=${1%%:*} addr=${1#*:} host=${2-$MY_IP} port=${1##*:}
  if [[ "$addr" == *:* ]]; then host=${addr%:*}; fi
  if [ "$proto" = "tcp" ]; then
    nc -z -w5 $host $port
  elif [ "$proto" = "http" ]; then
    local code
    code="$(curl -s -m5 -o /dev/null -w "%{http_code}" $host:$port)" || {
      log "ERROR: HTTP $code - failed to check http://$host:$port ($?)."
      return $EC_CHECK_HTTP_REQ_ERR
    }
    [[ "$code" =~ ^(200|302|401|403|404)$ ]] || {
      log "ERROR: unexpected HTTP code $code."
      return $EC_CHECK_HTTP_CODE_ERR
    }
  else
    return $EC_CHECK_PROTO_ERR
  fi
}

isNodeInitialized() {
  test -f $APPCTL_NODE_FILE
}

isClusterInitialized() {
  # Be aware that this doesn't work for nodes without /data volumes.
  test -f $APPCTL_CLUSTER_FILE
}

initSvc() {
  systemctl unmask -q ${1%%/*}
}

_checkSvc() {
  checkActive ${1%%/*} || {
    log "Service '$1' is inactive."
    return $EC_CHECK_INACTIVE
  }
  local endpoints=$(echo $1 | awk -F/ '{print $3}')
  local endpoint; for endpoint in ${endpoints//,/ }; do
    checkEndpoint $endpoint || {
      log "Endpoint '$endpoint' is unreachable."
      return $EC_CHECK_PORT_ERR
    }
  done
}

_startSvc() {
  systemctl start ${1%%/*}
}

_stopSvc() {
  systemctl stop ${1%%/*}
}

restartSvc() {
  execute stopSvc $1
  execute startSvc $1
}

maskSvc() {
  execute stopSvc $1
  systemctl mask ${1%%/*}
}

### app management

_preCheck() {
  checkEnv "$MY_IP"
}

_initNode() {
  systemd-detect-virt -cq || checkMounts
  rm -rf /data/lost+found
  mkdir -p /data/appctl/{data,logs}
  chown -R syslog.svc /data/appctl/logs
  find /opt/app/current/conf/sysctl -name '*.conf' -exec ln -snf {} /etc/sysctl.d/ \;
  sysctl --system
  find /opt/app/current/conf/systemd -mindepth 1 -maxdepth 1 -type f \( -name '*.service' -or -name '*.timer' \) -exec ln -snf {} /lib/systemd/system/ \;
  find /opt/app/current/conf/systemd -mindepth 1 -maxdepth 1 -type d -name '*.service.d' -exec ln -snf {} /etc/systemd/system/ \;
  systemctl daemon-reload
  find /opt/app/current/conf/logrotate -type f -exec ln -snf {} /etc/logrotate.d/ \;
  find /opt/app/current/conf/rsyslog -name '*.conf' -type f -exec ln -snf {} /etc/rsyslog.d/ \;
  restartSvc rsyslog
  local svc; for svc in $(getServices -a); do initSvc $svc; done
  touch $APPCTL_NODE_FILE
}

_initCluster() {
  isNodeInitialized || execute initNode
  touch $APPCTL_CLUSTER_FILE
}

_revive() {
  local svc; for svc in $(getServices); do
    execute checkSvc $svc || restartSvc $svc || log "ERROR: failed to restart '$svc' ($?)."
  done
}

_check() {
  if isClusterInitialized && isNodeInitialized; then
    local svc; for svc in $(getServices); do
      execute checkSvc $svc
    done
  else
    log "Skipped as cluster or node is not initialized."
  fi
}

_init() {
  isClusterInitialized || execute initCluster
}

_start() {
  isNodeInitialized || execute initNode
  local svc; for svc in $(getServices); do
    log "starting $svc ..."
    execute startSvc $svc
  done
}

_stop() {
  local svc; for svc in $(getServices -a | xargs -n1 | tac); do
    log "stopping $svc ..."
    execute stopSvc $svc
  done
}

_restart() {
  execute stop
  execute start
}

_reload() {
  if isNodeInitialized; then
    local svcs="${@:-$(getServices -a)}"
    local svc; for svc in $(echo $svcs | xargs -n1 | tac); do execute stopSvc $svc; done
    local svc; for svc in $svcs; do
      if isSvcEnabled $svc; then execute startSvc $svc; fi
    done
  else
    log "skipped as node is not initialized."
  fi
}

_destroy() {
  log "Masking all services ..."
  local svc; for svc in $(getServices -a | xargs -n1 | tac); do maskSvc $svc; done
  find /opt/app/current/bin/tmpl/ -type f -name '*.sh' -delete
  if isDev; then if test -d /data; then rm -rf /data/*; fi; fi
}

applyEnvFiles
applyRoleScripts
buildErrorCodes 128 $APP_ERR_CODES
buildErrorCodes 200 $APPCTL_ERR_CODES

isDev && set -x
set -eo pipefail

execute preCheck
execute $command $args
