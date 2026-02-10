#!/bin/bash

# VOLTTRON Core + Web Service Setup Script
# Prompts user for VOLTTRON_HOME and starts the platform with web service

echo "=========================================="
echo "VOLTTRON Core + Web Service Setup"
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

# Install volttron-lib-web (avoiding dependency conflicts)
if [ -d "../volttron-lib-web" ]; then
  echo "  [+] Found local volttron-lib-web, installing from path..."
  pip install --no-deps -e ../volttron-lib-web
else
  echo "  [-] Installing volttron-lib-web from GitHub develop branch..."
  pip install --no-deps git+https://github.com/riley206-pnnl/volttron-lib-web.git@develop
fi

# Install volttron-lib-web runtime dependencies
echo "  [+] Installing volttron-lib-web dependencies..."
pip install jinja2 passlib "PyJWT>=2.0.0" treelib werkzeug ws4py requests argon2-cffi

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

# Prompt for instance name
read -p "Enter instance name (default: volttron1): " INSTANCE_NAME
INSTANCE_NAME=${INSTANCE_NAME:=volttron1}

# Prompt for web bind address
read -p "Enter web bind address (default: http://0.0.0.0:8081): " WEB_BIND_ADDRESS
WEB_BIND_ADDRESS=${WEB_BIND_ADDRESS:=http://0.0.0.0:8081}

# Prompt for web secret key
read -p "Enter web secret key (press Enter for auto-generated): " WEB_SECRET_KEY
WEB_SECRET_KEY=${WEB_SECRET_KEY:=$(openssl rand -hex 32)}

echo ""
echo "Configuration:"
echo "  Instance Name: $INSTANCE_NAME"
echo "  Web Address:   $WEB_BIND_ADDRESS"
echo ""

# Create VOLTTRON config
cat > "$VOLTTRON_HOME/config" << EOF
[volttron]
instance-name=$INSTANCE_NAME
messagebus=zmq
vip-address=tcp://127.0.0.1:22916
EOF

# Create service_config.yml for web service
cat > "$VOLTTRON_HOME/service_config.yml" << EOF
volttron.services.web:
  enabled: true
  kwargs:
    bind_web_address: $WEB_BIND_ADDRESS
    web_secret_key: "$WEB_SECRET_KEY"
EOF

echo "[OK] Configuration files created"
echo ""

# Save VOLTTRON_HOME to a file for subsequent commands
echo "export VOLTTRON_HOME=\"$VOLTTRON_HOME\"" > .volttron_env

# --- Start VOLTTRON ---
echo "Starting VOLTTRON..."
export VOLTTRON_HOME="$VOLTTRON_HOME"

# Remove stale PID file so we can detect when the new instance writes it
PID_FILE="$VOLTTRON_HOME/VOLTTRON_PID"
rm -f "$PID_FILE"

volttron -vv -l volttron.log &>/dev/null &
VOLTTRON_PID=$!
disown

echo ""
echo "Waiting for VOLTTRON platform to be ready..."

# Wait for platform to write its PID file (signals core services are up).
# Default 120s; override with VOLTTRON_STARTUP_TIMEOUT env var.
MAX_WAIT=${VOLTTRON_STARTUP_TIMEOUT:-120}
COUNTER=0
PLATFORM_READY=false
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
    echo "[OK] VOLTTRON platform is ready! (${COUNTER}s)"
    PLATFORM_READY=true
    break
  fi

  sleep 1
  COUNTER=$((COUNTER + 1))
  echo -n "."
done

echo ""

if [ "$PLATFORM_READY" != true ]; then
  echo "[WARNING] VOLTTRON did not become ready within ${MAX_WAIT} seconds"
  echo ""
  echo "Last 30 lines of volttron.log:"
  echo "---"
  tail -n 30 volttron.log 2>/dev/null || echo "  (log file not found)"
  echo "---"
  echo ""
  echo "  The platform process (PID $VOLTTRON_PID) is still running."
  echo "  It may finish starting — check with: pixi run vctl status"
  echo ""
  echo "To stop VOLTTRON:"
  echo "  pixi run vctl shutdown --platform"
  exit 1
fi

# --- Wait for web service ---
# Extract port from bind address (e.g. "http://0.0.0.0:8081" -> "8081")
WEB_PORT="${WEB_BIND_ADDRESS##*:}"

echo "Waiting for web service on port $WEB_PORT..."

WEB_WAIT=${VOLTTRON_WEB_TIMEOUT:-30}
WEB_COUNTER=0
WEB_READY=false
while [ $WEB_COUNTER -lt $WEB_WAIT ]; do
  # Check if the process is still alive
  if ! kill -0 "$VOLTTRON_PID" 2>/dev/null; then
    echo ""
    echo "[ERROR] VOLTTRON process died while starting web service"
    echo ""
    echo "Last 30 lines of volttron.log:"
    echo "---"
    tail -n 30 volttron.log 2>/dev/null || echo "  (log file not found)"
    echo "---"
    exit 1
  fi

  # Check if something is listening on the web port
  if ss -tlnH 2>/dev/null | grep -q ":${WEB_PORT} " || \
     netstat -tln 2>/dev/null | grep -q ":${WEB_PORT} "; then
    echo ""
    echo "[OK] Web service is listening on $WEB_BIND_ADDRESS (${WEB_COUNTER}s)"
    WEB_READY=true
    break
  fi

  sleep 1
  WEB_COUNTER=$((WEB_COUNTER + 1))
  echo -n "."
done

echo ""

if [ "$WEB_READY" != true ]; then
  echo "[WARNING] Web service did not start within ${WEB_WAIT} seconds"
  echo "  The platform is running but the web service may still be initializing."
  echo "  Check volttron.log for web-related errors."
  echo ""
fi

# --- Summary ---
echo "=========================================="
echo "  VOLTTRON is running"
echo "=========================================="
echo "  PID:          $VOLTTRON_PID"
echo "  VOLTTRON_HOME: $VOLTTRON_HOME"
echo "  Log file:     volttron.log"
if [ "$WEB_READY" = true ]; then
  echo "  Web Admin:    $WEB_BIND_ADDRESS/admin"
fi
echo ""
echo "To check status:"
echo "  pixi run vctl status"
echo ""
echo "To stop VOLTTRON:"
echo "  pixi run vctl shutdown --platform"
