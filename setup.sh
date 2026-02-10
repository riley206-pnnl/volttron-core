#!/bin/bash

# VOLTTRON Core Setup Script
# Prompts user for VOLTTRON_HOME and starts the platform

echo "=========================================="
echo "VOLTTRON Core Setup"
echo "=========================================="
echo ""

# Check for running VOLTTRON processes
if pgrep -f "volttron -vv" > /dev/null; then
  echo "[WARNING] VOLTTRON process(es) already running"
  echo ""
  read -p "Kill existing VOLTTRON processes? (y/N): " KILL_VOLTTRON
  if [[ "$KILL_VOLTTRON" =~ ^[Yy]$ ]]; then
    echo "Killing existing VOLTTRON processes..."
    pkill -9 -f volttron
    sleep 2
    echo "[OK] Processes killed"
  else
    echo "Exiting. Please stop existing VOLTTRON processes first."
    exit 1
  fi
  echo ""
fi

# Check for and install local volttron libraries if available
echo "Checking for local volttron libraries..."

if [ -d "../volttron-lib-zmq" ]; then
  echo "  [+] Found local volttron-lib-zmq, installing from path..."
  pip install -e ../volttron-lib-zmq
else
  echo "  [-] Installing volttron-lib-zmq from GitHub develop branch..."
  pip install git+https://github.com/riley206-pnnl/volttron-lib-zmq.git@develop
fi

if [ -d "../volttron-lib-auth" ]; then
  echo "  [+] Found local volttron-lib-auth, installing from path..."
  pip install -e ../volttron-lib-auth
else
  echo "  [-] Installing volttron-lib-auth from GitHub develop branch..."
  pip install git+https://github.com/riley206-pnnl/volttron-lib-auth.git@develop
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

# Remove stale PID file so we can detect when the new instance writes it
PID_FILE="$VOLTTRON_HOME/VOLTTRON_PID"
rm -f "$PID_FILE"

volttron -vv -l volttron.log &>/dev/null &

VOLTTRON_PID=$!
disown

echo ""
echo "Waiting for VOLTTRON to be ready..."

# Wait for platform to write its PID file (signals core services are up).
# Default 120s; override with VOLTTRON_STARTUP_TIMEOUT env var.
MAX_WAIT=${VOLTTRON_STARTUP_TIMEOUT:-120}
COUNTER=0
while [ $COUNTER -lt $MAX_WAIT ]; do
  # Fail fast if the process died
  if ! kill -0 "$VOLTTRON_PID" 2>/dev/null; then
    echo ""
    echo "[ERROR] VOLTTRON process exited unexpectedly"
    echo ""
    echo "Last 30 lines of volttron.log:"
    echo "---"
    tail -n 30 volttron.log 2>/dev/null || echo "  (log file not found)"
    echo "---"
    exit 1
  fi

  # Platform writes VOLTTRON_PID file after auth, message bus, and
  # config store are all running — that is the readiness signal.
  if [ -f "$PID_FILE" ]; then
    echo ""
    echo "[OK] VOLTTRON is ready!"
    break
  fi

  sleep 1
  COUNTER=$((COUNTER + 1))
  echo -n "."
done

echo ""

if [ $COUNTER -eq $MAX_WAIT ]; then
  echo "[WARNING] VOLTTRON did not become ready within ${MAX_WAIT} seconds"
  echo ""
  echo "Last 30 lines of volttron.log:"
  echo "---"
  tail -n 30 volttron.log 2>/dev/null || echo "  (log file not found)"
  echo "---"
  echo ""
  echo "  The platform process (PID $VOLTTRON_PID) is still running."
  echo "  It may finish starting — check with: pixi run vctl status"
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
