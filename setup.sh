#!/bin/bash

# VOLTTRON Core Setup Script
# Prompts user for VOLTTRON_HOME and starts the platform

echo "=========================================="
echo "VOLTTRON Core Setup"
echo "=========================================="
echo ""

# Check for and install local volttron libraries if available
echo "Checking for local volttron libraries..."

if [ -d "../volttron-lib-zmq" ]; then
  echo "  [+] Found local volttron-lib-zmq, installing from path..."
  pip install -e ../volttron-lib-zmq
else
  echo "  [-] Installing volttron-lib-zmq from PyPI..."
  pip install volttron-lib-zmq
fi

if [ -d "../volttron-lib-auth" ]; then
  echo "  [+] Found local volttron-lib-auth, installing from path..."
  pip install -e ../volttron-lib-auth
else
  echo "  [-] Installing volttron-lib-auth from PyPI..."
  pip install volttron-lib-auth
fi

echo ""

# Prompt for VOLTTRON_HOME
DEFAULT_VOLTTRON_HOME="$(pwd)/volttron_home"
read -p "Enter VOLTTRON_HOME directory (default: $DEFAULT_VOLTTRON_HOME): " VOLTTRON_HOME
VOLTTRON_HOME=${VOLTTRON_HOME:=$DEFAULT_VOLTTRON_HOME}

echo ""
echo "Using VOLTTRON_HOME: $VOLTTRON_HOME"
echo ""

# Create directory if it doesn't exist
mkdir -p "$VOLTTRON_HOME"

# Save VOLTTRON_HOME to a file for subsequent commands
echo "export VOLTTRON_HOME=\"$VOLTTRON_HOME\"" > .volttron_env

# Start VOLTTRON
echo "Starting VOLTTRON..."
export VOLTTRON_HOME="$VOLTTRON_HOME"
volttron -vv -l volttron.log &>/dev/null &

VOLTTRON_PID=$!

echo ""
echo "Waiting for VOLTTRON to be ready..."

# Wait for VOLTTRON to be ready (max 30 seconds)
MAX_WAIT=30
COUNTER=0
while [ $COUNTER -lt $MAX_WAIT ]; do
  if vctl status &>/dev/null; then
    echo "[OK] VOLTTRON is ready!"
    break
  fi
  sleep 1
  COUNTER=$((COUNTER + 1))
  echo -n "."
done

echo ""

if [ $COUNTER -eq $MAX_WAIT ]; then
  echo "[WARNING] VOLTTRON did not respond within ${MAX_WAIT} seconds"
  echo "  Check volttron.log for errors"
else
  echo "[OK] VOLTTRON started successfully"
fi

echo "  PID: $VOLTTRON_PID"
echo "  Log file: volttron.log"
echo ""
echo "To check status:"
echo "  pixi run vctl status"
echo ""
echo "To stop VOLTTRON:"
echo "  pixi run vctl shutdown --platform"
