#!/usr/bin/env bash
# Regenerate a Vault root token using any 3 unseal (Shamir) keys.
# Writes the new token to ~/.vault-token so the vault CLI picks it up.
#
# Requires:
#   - VAULT_ADDR pointing at an unsealed Vault (default http://127.0.0.1:8200)
#   - 3 of the 5 unseal keys the user still controls
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

echo "Initializing root-token generation..." >&2
init_json="$(vault operator generate-root -init -format=json)"
nonce="$(echo "$init_json" | jq -r .nonce)"
otp="$(echo "$init_json" | jq -r .otp)"
echo "nonce=$nonce" >&2

encoded=""
for i in 1 2 3; do
  read -r -s -p "Unseal key $i: " key; echo
  out="$(vault operator generate-root -nonce="$nonce" -format=json "$key")"
  encoded="$(echo "$out" | jq -r .encoded_token)"
  complete="$(echo "$out" | jq -r .complete)"
  progress="$(echo "$out" | jq -r '"\(.progress)/\(.required)"')"
  echo "  progress=$progress" >&2
  [[ "$complete" == "true" ]] && break
done

if [[ -z "$encoded" || "$encoded" == "null" ]]; then
  echo "ERROR: generation did not complete — check key correctness and retry" >&2
  echo "Canceling the in-progress generation..." >&2
  vault operator generate-root -cancel >/dev/null || true
  exit 1
fi

new_token="$(vault operator generate-root -decode="$encoded" -otp="$otp")"
printf '%s' "$new_token" > ~/.vault-token
chmod 600 ~/.vault-token

echo "New root token written to ~/.vault-token" >&2
echo "Verifying..." >&2
vault token lookup | head -5

# Revoke any OTHER root tokens — each previous regenerate-root run left a
# still-valid root behind. Anyone who kept a copy keeps unrestricted access.
echo "Revoking stale root tokens (keeping current)..." >&2
export VAULT_TOKEN="$new_token"
my_acc="$(vault token lookup -format=json | jq -r '.data.accessor')"
revoked=0
while IFS= read -r acc; do
  [[ -z "$acc" || "$acc" == "$my_acc" ]] && continue
  info="$(vault token lookup -accessor -format=json "$acc" 2>/dev/null || true)"
  [[ -z "$info" ]] && continue
  path="$(echo "$info" | jq -r '.data.path')"
  pols="$(echo "$info" | jq -r '.data.policies | join(",")')"
  if [[ "$path" == "auth/token/root" && "$pols" == "root" ]]; then
    vault token revoke -accessor "$acc" >/dev/null && {
      echo "  revoked stale root ${acc:0:12}..." >&2
      revoked=$((revoked+1))
    }
  fi
done < <(vault list -format=json auth/token/accessors | jq -r '.[]')
echo "Stale root tokens revoked: $revoked" >&2
