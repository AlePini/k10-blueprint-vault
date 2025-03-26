#!/bin/bash
version=0.1.0

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_SKIP_VERIFY="true"
export INIT_OUT_PATH="./init-recovery.log"
export VAULT_INIT_ARGS=""
export KEY_SHARES="5"
export KEY_THRESHOLD="3"
export NAMESPACE="vault"
export CONTEXT=""
export KUBECTL_ARGS=""

# -----------------------------
#            Options
# -----------------------------

# Parse flags and options
while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do case $1 in
  -V | --version )
    echo "$version"
    exit
    ;;
  -h | --help )
    echo "version: $version"
    echo "Usage: \$ vault-init.sh -u username -p password -n namespace"
    echo "* -u | --user: Name of user with snapshot permission. *Required"
    echo "* -p | --password: Password of user with snapshot permission. *Required"
    echo "  -n | --namespace: Namespace used to create a Secret with provided username and password. Default is \"$NAMESPACE\""
    echo "  -c | --context: Kubernetes context used for all kubectl operations. Default is \"$CONTEXT\""
    echo "  -o | --output-file: Path where recovery keys and root token will be stored. Default is \"$INIT_OUT_PATH\""
    echo "  -s | --key-shares: Number of key shares to create. Default is \"$KEY_SHARES\""
    echo "  -t | --key-threshold: Number of key required before vault can be unseald. Default is \"$KEY_THRESHOLD\""
    exit
    ;;
  -u | --user )
    shift; SNAP_USER=$1
    ;;
  -p | --password )
    shift; SNAP_PASSWORD=$1
    ;;
  -n | --namespace )
    shift; NAMESPACE=$1
    KUBECTL_ARGS="$KUBECTL_ARGS --namespace $NAMESPACE"
    ;;
  -c | --context )
    shift; CONTEXT=$1
    KUBECTL_ARGS="$KUBECTL_ARGS --context $CONTEXT"
    ;;
  -o | --output-file )
    shift; INIT_OUT_PATH=$1
    ;;
  -s | --key-shares )
    shift; KEY_SHARES=$1
    VAULT_INIT_ARGS="$VAULT_INIT_ARGS -key-shares=$KEY_SHARES"
    ;;
  -t | --key-threshold )
    shift; KEY_THRESHOLD=$1
    VAULT_INIT_ARGS="$VAULT_INIT_ARGS -key-threshold=$KEY_THRESHOLD"
    ;;
esac; shift; done
if [[ "$1" == '--' ]]; then shift; fi

# Get required args from stdin, if not found
if [[ -z $SNAP_USER ]]; then
  read -p "User: " SNAP_USER
fi
if [[ -z $SNAP_PASSWORD ]]; then
  read -s -p "Password: " SNAP_PASSWORD
  echo
fi

# Check if provided option values are correct
if [[ $KEY_SHARES -eq 0 || $KEY_THRESHOLD -eq 0 ]]; then
  echo
  echo "! Number of key shares or threshould cannot be 0"
  exit 1
fi
if [[ $KEY_SHARES -lt $KEY_THRESHOLD ]]; then
  echo
  echo "! Number of key shares cannot be less than threshold number"
  echo "Key Shares: $KEY_SHARES"
  echo "Key Threshold: $KEY_THRESHOLD"
  exit 1
fi

# Check if vault and kubectl are installed
if [[ ! $(type -P "vault") ]]; then
  echo
  echo "! Vault is not installed!"
  echo "Use this documentation: https://developer.hashicorp.com/vault/docs/install"
  exit 1
fi
if [[ ! $(type -P "kubectl") ]]; then
  echo
  echo "! Kubectl is not installed!"
  echo "Use this documentation: https://kubernetes.io/docs/tasks/tools/"
  exit 1
fi

# Debug print for important vars
echo "Vault address: $VAULT_ADDR"
echo "Skip verify TLS: $VAULT_SKIP_VERIFY"
echo "Output path for init command: $INIT_OUT_PATH"
if [[ -n $VAULT_INIT_ARGS ]]; then
  echo "Vault init arguments: $VAULT_INIT_ARGS"
fi
if [[ -n $KUBECTL_ARGS ]]; then
  echo "Kubectl command arguments: $KUBECTL_ARGS"
fi


# TODO echo "Creating Port Forwarding to localhost:8200"
kubectl port-forward $KUBECTL_ARGS pods/vault-0 8200:8200 > /dev/null &
export KUBE_PF_VAULT0=$!

# Now testing if Vault is reachable
if [[ "$(curl -s -o /dev/null -L --insecure --max-time 10 --connect-timeout 5 --retry 5 --retry-connrefused -w ''%{http_code}'' $VAULT_ADDR)" != "200" ]]; then
  echo
  echo "! Vault is not reachable at $VAULT_ADDR"
  kill $KUBE_PF_VAULT0
  exit 1
fi

# -------------------------------------
#            Init and Config
# -------------------------------------
echo "Initializing first Vault at $VAULT_ADDR... (can take few minutes)"
vault operator init $VAULT_INIT_ARGS > $INIT_OUT_PATH
cat $INIT_OUT_PATH

vault status
if [[ $? -eq 2 ]]; then
  echo "Trying to unseal vault with keys..."
  for ((i = 1 ; i <= $KEY_THRESHOLD ; i++)); do
    KEY=$(cat $INIT_OUT_PATH | sed -n -e "s/^.*Unseal Key $i: //p")
    vault operator unseal $KEY | grep "Unseal Progress"
  done

  sleep 5

  # Check if is still sealed
  echo
  vault status
  if [[ $? -eq 2 ]]; then echo "!! VAULT STILL NOT UNSEALED"; exit 1; fi

  echo "Remember to unseal other replica pods!"
fi

echo "Trying to login with Root Token at $VAULT_ADDR..."
export ROOT_TOKEN=$(bat $INIT_OUT_PATH | sed -n -e 's/^.*Initial Root Token: //p')
vault login $ROOT_TOKEN

echo "Creating snapshot policy..."
cat <<EOF > snapshot.hcl
path "sys/storage/raft/snapshot" {
  capabilities = ["read", "update"]
}
path "sys/storage/raft/snapshot-force" {
  capabilities = ["read", "update"]
}
EOF
vault policy write snapshot snapshot.hcl

echo "Creating User '$SNAP_USER'..."
vault auth enable userpass
vault write auth/userpass/users/$SNAP_USER token_policies="snapshot" password="$SNAP_PASSWORD"

echo "Creating secret in kubernetes cluster..."
kubectl delete secret $KUBECTL_ARGS hashicorp-vault-userpass
kubectl create secret generic $KUBECTL_ARGS hashicorp-vault-userpass \
  --from-literal=username=$SNAP_USER \
  --from-literal=password=$SNAP_PASSWORD

# -------------------------
#            END
# -------------------------
echo
echo "Remember to unseal other replica pods!"
kill $KUBE_PF_VAULT0
