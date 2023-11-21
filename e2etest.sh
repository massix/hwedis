#!/usr/bin/env bash

set -eu

DOCKER_BIN=$(which docker)
WEBSOCAT_BIN=$(which websocat)

# type DockerCommand = String
# type PId = Int
# type HostName = String
# type Port = Int
# type ClientId = String
# type ExitCode = Int

# compose_as_plugin :: IO Bool
function compose_as_plugin() {
  ${DOCKER_BIN} compose > /dev/null 2> /dev/null
}

# compose_standalone :: IO Bool
function compose_standalone() {
  which docker-compose > /dev/null 2> /dev/null
}

# docker_cmd :: IO String
function docker_cmd() {
  if compose_as_plugin; then
    echo "${DOCKER_BIN} compose"
  elif compose_standalone; then
    echo "`which docker-compose`"
  else
    echo ""
  fi
}

# start_redis :: DockerCommand -> IO ()
function start_redis() {
  dock="$1"

  ${dock} up -d
}

# stop_redis :: DockerCommand -> IO ()
function stop_redis() {
  dock="$1"

  ${dock} down
}

# start_hwedis :: String -> IO PId
function start_hwedis() {
  cabal run > "$1" 2>&1 &
  echo "$!"
}

# stop_pid :: PId -> IO ()
function stop_pid() {
  kill -SIGTERM "$1"
}

# send_message :: String -> HostName -> Port -> ClientId -> IO String
function send_message() {
  echo -n "$1" | ${WEBSOCAT_BIN} -t "ws://$2:$3" -H "user-agent: $4" 2> /dev/null
}

# assert :: String -> String -> Bool
function assert() {
  if [[ ! "x${1}" == "x${2}" ]]; then
    echo "Expected: \"$2\", Received: \"$1\"" > /dev/stderr
    return 1
  else
    return 0
  fi
}

# perma_reader :: HostName -> Port -> ClientId -> FilePath -> IO PId
function perma_reader() {
  ${WEBSOCAT_BIN} -U -n -t "ws://$1:$2" -H "user-agent: $3" > "$4" &
  echo "$!"
}

# is_in_file :: String -> FilePath -> IO Bool
function is_in_file() {
  grep "$1" "$2" > /dev/null
}

# main :: IO ExitCode
function main() {
  local dcmd=`docker_cmd`
  local logfile="hwedis.log"
  local readerfile="reader.log"
  local host="127.0.0.1"
  local port=9092
  local exitCode=0

  # Exit condition
  if [[ "x${dcmd}" == "x" ]]; then
    echo "No docker-compose found"
    exit 1
  fi

  # Prepare environment
  start_redis "$dcmd"
  hwedis_pid=`start_hwedis "${logfile}"`
  sleep 2

  # Create the reader
  reader_pid=`perma_reader $host $port "reader" "$readerfile"`
  sleep 2

  # Create an object
  recv=`send_message "C::someobje::firstKey::firstValue" $host $port "client-1"`
  if ! assert "$recv" "C::someobje"; then
    exitCode=1
  fi

  # Create a second object
  recv=`send_message "C::secondob::someKey::someValue" $host $port "client-1"`
  if ! assert "$recv" "C::secondob"; then
    exitCode=1
  fi

  # List all the objects
  # Quite ugly but we do not know the order in which Hwedis will give us the objects..
  recv=`send_message "L" $host $port "client-125"`
  if ! assert "$recv" "L::secondob::someKey::someValue||someobje::firstKey::firstValue" 2> /dev/null; then
    if ! assert "$recv" "L::someobje::firstKey::firstValue||secondob::someKey::someValue"; then
      exitCode=1
    fi
  fi

  # Get it
  recv=`send_message "G::someobje" $host  $port "client-1"`
  if ! assert "$recv" "G::someobje::firstKey::firstValue"; then
    exitCode=1
  fi

  # Update it
  recv=`send_message "U::someobje::firstKey::modified firstValue::secondKey::secondValue" $host $port "client-2"`
  if ! assert "$recv" "U::someobje"; then
    exitCode=1
  fi

  # Get it again
  recv=`send_message "G::someobje" $host $port "client-2"`
  if ! assert "$recv" "G::someobje::firstKey::modified firstValue::secondKey::secondValue"; then
    exitCode=1
  fi

  # Delete it
  recv=`send_message "D::someobje" $host $port "client-3"`
  if ! assert "$recv" "D::someobje"; then
    exitCode=1
  fi

  # Try to get a non-existing object
  recv=`send_message "G::nonexist" $host $port "client-1"`
  if ! assert "$recv" "#f"; then
    exitCode=1
  fi

  # Try to delete a non-existing object
  recv=`send_message "D::nonexist" $host $port "client-1"`
  if ! assert "$recv" "#f"; then
    exitCode=1
  fi

  stop_pid $reader_pid
  stop_pid $hwedis_pid
  stop_redis "$dcmd"

  # Verify that the reader received the right messages
  for msg in "C::someobje" "C::secondob" "U::someobje" "D::someobje"; do
    if ! is_in_file "${msg}" "$readerfile"; then
      echo "Message ${msg} not found in $readerfile"
      exitCode=1
    fi
  done

  rm -f "$readerfile"
  rm -f "$logfile"

  return $exitCode
}

main
