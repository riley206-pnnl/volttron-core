#!/bin/bash

# VOLTTRON Core + Web Service Setup Script
# All settings can be passed as environment variables for non-interactive use.
#
# Environment variables:
#   VOLTTRON_HOME              — platform home directory (default: ./volttron_home)
#   VOLTTRON_INSTANCE_NAME     — instance name (default: volttron1)
#   VOLTTRON_WEB_BIND_ADDRESS  — web bind address (default: http://0.0.0.0:8081)
#   VOLTTRON_WEB_SECRET_KEY    — web secret key (default: auto-generated)
#   VOLTTRON_STARTUP_TIMEOUT   — seconds to wait for platform startup (default: 120)
#   VOLTTRON_WEB_TIMEOUT       — seconds to wait for web service (default: 30)

echo "=========================================="
echo "VOLTTRON Core + Web Service Setup"
echo "=========================================="
echo ""

# Check for running VOLTTRON processes
if pgrep -f "volttron -vv" > /dev/null; then
  echo "[WARNING] VOLTTRON process(es) already running"
  echo ""
  if [ -t 0 ]; then
    read -p "Kill existing VOLTTRON processes? (y/N): " KILL_VOLTTRON
  else
    echo "Non-interactive mode: auto-killing existing VOLTTRON processes"
    KILL_VOLTTRON="y"
  fi
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
pip install jinja2 jinja2-cli passlib "PyJWT>=2.0.0" treelib werkzeug ws4py requests argon2-cffi

echo ""

# --- Configuration (env vars with optional interactive fallback) ---

DEFAULT_VOLTTRON_HOME="$(pwd)/volttron_home"
if [ -z "$VOLTTRON_HOME" ]; then
  if [ -t 0 ]; then
    read -p "Enter VOLTTRON_HOME directory (default: $DEFAULT_VOLTTRON_HOME): " VOLTTRON_HOME
  fi
  VOLTTRON_HOME=${VOLTTRON_HOME:=$DEFAULT_VOLTTRON_HOME}
fi

if [ -z "$VOLTTRON_INSTANCE_NAME" ]; then
  if [ -t 0 ]; then
    read -p "Enter instance name (default: volttron1): " VOLTTRON_INSTANCE_NAME
  fi
  VOLTTRON_INSTANCE_NAME=${VOLTTRON_INSTANCE_NAME:=volttron1}
fi

if [ -z "$VOLTTRON_WEB_BIND_ADDRESS" ]; then
  if [ -t 0 ]; then
    read -p "Enter web bind address (default: http://0.0.0.0:8081): " VOLTTRON_WEB_BIND_ADDRESS
  fi
  VOLTTRON_WEB_BIND_ADDRESS=${VOLTTRON_WEB_BIND_ADDRESS:=http://0.0.0.0:8081}
fi

if [ -z "$VOLTTRON_WEB_SECRET_KEY" ]; then
  if [ -t 0 ]; then
    read -p "Enter web secret key (press Enter for auto-generated): " VOLTTRON_WEB_SECRET_KEY
  fi
  VOLTTRON_WEB_SECRET_KEY=${VOLTTRON_WEB_SECRET_KEY:=$(openssl rand -hex 32)}
fi

echo ""
echo "Configuration:"
echo "  VOLTTRON_HOME: $VOLTTRON_HOME"
echo "  Instance Name: $VOLTTRON_INSTANCE_NAME"
echo "  Web Address:   $VOLTTRON_WEB_BIND_ADDRESS"
echo ""

# Create directory if it doesn't exist
mkdir -p "$VOLTTRON_HOME"

# Create VOLTTRON config
cat > "$VOLTTRON_HOME/config" << EOF
[volttron]
instance-name=$VOLTTRON_INSTANCE_NAME
messagebus=zmq
vip-address=tcp://127.0.0.1:22916
EOF

# Create service_config.yml for web service
cat > "$VOLTTRON_HOME/service_config.yml" << EOF
volttron.services.web:
  enabled: true
  kwargs:
    bind_web_address: $VOLTTRON_WEB_BIND_ADDRESS
    web_secret_key: "$VOLTTRON_WEB_SECRET_KEY"
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

LOG_FILE="$(pwd)/volttron.log"
STDERR_LOG="$(pwd)/volttron_stderr.log"

volttron -vv -l "$LOG_FILE" >/dev/null 2>"$STDERR_LOG" &
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
    # Show stderr first — this catches import errors / tracebacks that
    # happen before the log file is even opened.
    if [ -s "$STDERR_LOG" ]; then
      echo "stderr output:"
      echo "---"
      tail -n 40 "$STDERR_LOG"
      echo "---"
      echo ""
    fi
    if [ -s "$LOG_FILE" ]; then
      echo "Last 30 lines of volttron.log:"
      echo "---"
      tail -n 30 "$LOG_FILE"
      echo "---"
    fi
    if [ ! -s "$STDERR_LOG" ] && [ ! -s "$LOG_FILE" ]; then
      echo "  No log output found. Try running volttron directly to see errors:"
      echo "    pixi run volttron -vv"
    fi
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
  if [ -s "$STDERR_LOG" ]; then
    echo "stderr output:"
    echo "---"
    tail -n 40 "$STDERR_LOG"
    echo "---"
    echo ""
  fi
  echo "Last 30 lines of volttron.log:"
  echo "---"
  tail -n 30 "$LOG_FILE" 2>/dev/null || echo "  (log file not found)"
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
WEB_PORT="${VOLTTRON_WEB_BIND_ADDRESS##*:}"

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
    if [ -s "$STDERR_LOG" ]; then
      echo "stderr output:"
      echo "---"
      tail -n 40 "$STDERR_LOG"
      echo "---"
      echo ""
    fi
    echo "Last 30 lines of volttron.log:"
    echo "---"
    tail -n 30 "$LOG_FILE" 2>/dev/null || echo "  (log file not found)"
    echo "---"
    exit 1
  fi

  # Check if something is listening on the web port
  if ss -tlnH 2>/dev/null | grep -q ":${WEB_PORT} " || \
     netstat -tln 2>/dev/null | grep -q ":${WEB_PORT} "; then
    echo ""
    echo "[OK] Web service is listening on $VOLTTRON_WEB_BIND_ADDRESS (${WEB_COUNTER}s)"
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
echo "  PID:           $VOLTTRON_PID"
echo "  VOLTTRON_HOME: $VOLTTRON_HOME"
echo "  Log file:      $LOG_FILE"
if [ "$WEB_READY" = true ]; then
  echo "  Web Admin:     $VOLTTRON_WEB_BIND_ADDRESS/admin"
fi
echo ""
echo "To check status:"
echo "  pixi run vctl status"
echo ""
echo "To stop VOLTTRON:"
echo "  pixi run vctl shutdown --platform"
