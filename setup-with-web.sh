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

# Start VOLTTRON
echo "Starting VOLTTRON..."
export VOLTTRON_HOME="$VOLTTRON_HOME"
volttron -vv -l volttron.log &>/dev/null &

VOLTTRON_PID=$!
disown

echo ""
echo "Waiting for VOLTTRON to be ready..."

# Wait for VOLTTRON to be ready (max 60 seconds)
MAX_WAIT=60
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

# Check if web service is running
sleep 2
if ss -tuln 2>/dev/null | grep -q "${WEB_BIND_ADDRESS##*:}" || netstat -tuln 2>/dev/null | grep -q "${WEB_BIND_ADDRESS##*:}"; then
  echo "[OK] Web service is listening on $WEB_BIND_ADDRESS"
  echo ""
  echo "Web Admin Page:"
  echo "  $WEB_BIND_ADDRESS/admin"
  echo ""
else
  echo "[WARNING] Web service may not be running"
  echo "  Check volttron.log for errors"
  echo ""
fi

echo "To check status:"
echo "  pixi run vctl status"
echo ""
echo "To stop VOLTTRON:"
echo "  pixi run vctl shutdown --platform"
