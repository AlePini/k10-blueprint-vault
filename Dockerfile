FROM hashicorp/vault:1.18 AS VAULT_IMAGE
FROM ghcr.io/kanisterio/kanister-tools:0.113.0

USER root

# Install vault-cli
COPY --from=VAULT_IMAGE /bin/vault /usr/local/bin/vault

CMD ["tail", "-f", "/dev/null"]
