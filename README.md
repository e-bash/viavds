```bash
curl -sSL "https://raw.githubusercontent.com/e-bash/viavds/main/install/install_viavds.sh" | sudo bash -s -- \
  --domain vianl.ru \
  --wh wh.vianl.ru \
  --email admin@vianl.ru \
  --repo https://github.com/e-bash/viavds.git \
  --postgres-password VeryStrongPasswordHere \
  --cf-token xxxxxx-xxxxxxxxxxxxxx   # optional: Cloudflare API token if you want DNS challenge
```

