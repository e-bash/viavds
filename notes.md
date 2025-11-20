Отлично — идея с единым доменом `viavds.com` и региональными поддоменами — очень правильная и масштабируемая. Сначала объясню архитектуру доменов и рекомендации по именованию/развитию, затем дам полный обновлённый `README.md` для корня репозитория (готово к вставке).

---

# 1. Концепция доменных имён и масштабирования (идеи и рекомендации)

## Основная идея

Регистрируешь `viavds.com` как брендовый домен и используешь поддомены для каждого **региона / площадки / провайдера**. Для каждого VDS (или географического региона) создаёшь отдельную подзону в виде поддомена верхнего уровня:

* `nl.viavds.com` — VDS в Нидерландах (пустая зона / запись A → IP NL-VDS)
* `kz.viavds.com` — VDS в Казахстане
* `ru.viavds.com` — VDS в России (если понадобится)

На каждом таком региональном хосте разворачиваешь свои **сервисы/поддомены**:

* `wh.nl.viavds.com` — основной сервис `viavds` (webhook proxy & buffer) в Нидерландах
* `ngrok.nl.viavds.com` — публичный адрес для cloudflared-tunnel / ngrok-like туннелей в Нидерландах
* `admin.nl.viavds.com` — панель администрирования (если будет)
* аналогично для kz: `wh.kz.viavds.com`, `ngrok.kz.viavds.com`

## Почему именно так — преимущества

* Чёткая изоляция региона → соответствие локальным законам/латенси/близость к сервисам.
* Единая брендовая зона `viavds.com` поддерживает централизованную политику и управление (Cloudflare).
* Удобно для автоматизации: шаблон создания записи и деплоя одинаков для любой новой площадки.
* Можно использовать wildcard и политики безопасности (Cloudflare, WAF) централизованно.

## Дополнительные имена / рекомендации

* Для внутренних dev/qa: `dev.nl.viavds.com`, `staging.nl.viavds.com`
* Для сервисов мониторинга / metrics: `metrics.nl.viavds.com`
* Для n8n (если ставишь self-hosted): `n8n.nl.viavds.com` (или `workflow.nl.viavds.com`)
* Для health/metrics можно использовать `health.nl.viavds.com` (nginx health-checks, uptime)

## DNS & TLS рекомендации

* Управление зоной `viavds.com` в Cloudflare — удобно: централизованная защита, DNS API, SSL.
* Для поддоменов `nl.viavds.com` и т.п. — достаточно в Cloudflare создавать A записи или CNAME, либо использовать Cloudflare Tunnel route DNS (если вы хотите, чтобы `ngrok.*` указывал на Tunnel).
* Сертификаты:

    * Production: Let's Encrypt (certbot) на хосте nginx **или** использовать Cloudflare Origin CA (Cloudflare выпустит сертификат, который валиден только через Cloudflare — хороший выбор, если весь трафик идёт через Cloudflare).
    * Dev/local: mkcert для `*.loc` и для тестов.
* Рекомендация: для публичных сервисов — использовать **Full (Strict)** SSL в Cloudflare: на сервере поставить Origin certificate или полноценный certbot cert.

## Автоматизация создания нового региона (примерный workflow)

1. Захватить/создать VDS (полный образ, IP).
2. В Cloudflare: добавить записи для новой подсети:

    * `nl.viavds.com` A → VDS IP (или CNAME на сервис)
    * `wh.nl.viavds.com` A → VDS IP (или route через Tunnel)
    * `ngrok.nl.viavds.com` — либо route через Tunnel, либо A → VDS IP
3. Запустить один скрипт `install_viavds.sh --wh wh.nl.viavds.com --ngrok ngrok.nl.viavds.com --email ops@viavds.com --repo ...`
4. Провести cloudflared tunnel login (один раз) и route dns для `ngrok.*`.
5. Настроить мониторинг / backup / alerting.

## Политика именования служб внутри VDS (конвенция)

* Сервис: `wh` (webhook handler)
* Туннель/подключение: `ngrok`
* Панель: `admin`
* Воркфлоу: `n8n`
* Мониторинг: `prom`, `grafana`
  Итого: `service.region.brand.tld` → `service.nl.viavds.com`.

---

# 2. Архитектура развертывания (схема, кратко)

* Edge DNS + CDN: Cloudflare (зона `viavds.com`)
* На каждом VDS:

    * nginx (на хосте) — SSL termination (Let’s Encrypt / Origin CA) + reverse-proxy
    * Docker stack: PostgreSQL, viavds, возможно n8n (по желанию), другие вспомогательные сервисы
    * cloudflared (systemd) — нужен для создания публичных туннелей `ngrok.*`
    * Monitoring agent (node_exporter / netdata) + backup scripts

Поток вебхуков:

```
Интернет -> Cloudflare -> (A запись или Tunnel) -> nginx(host) -> docker:viavds -> Postgres
```

Если локальная машина хочет пробросить порт публично:

```
локаль -> cloudflared client -> cloudflared tunnel (VDS) -> ngrok.region.viavds.com -> клиент извне
```

---

# 3. Как развивать (практически)

* Шаблоны: держать шаблон `docker-compose.yml` и `install_viavds.sh` в репо — запускаешь на новом VDS и всё поднимается.
* CI/CD: настроить GitHub Actions:

    * Сборка Docker-образов → push в GHCR/DockerHub
    * После push — deploy hook (ssh или CI runner) на конкретную региональную ветку/тег
* Мониторинг/ALERTS:

    * Prometheus + Grafana, Alertmanager, уведомления в Telegram/Slack
* Бэкапы:

    * nightly `pg_dump` в облако (S3/Backblaze) или rsync на другой хост
* Security:

    * Cloudflare Access или IP allow for admin UI
    * Rotate secrets (Vault / AWS Secrets / GitHub Secrets)
* Multi-region data strategy:

    * Для webhook queue — каждый регион хранит локальную копию (Postgres). Если нужна централизованная аналитика — выгружать в центральный BI (ETL).
* High-availability:

    * Для критичных workflow: репликация Postgres (primary-replica) или управляемый Postgres в облаке.
* Cost control:

    * Шаблонизируй размеры VDS и разделяй домашний/dev/production.

---

# 4. README.md — полный, обновлённый (готово к вставке)

Скопируй этот блок в `README.md` в корень репозитория `e-bash/viavds`. Он содержит описание проекта, архитектуру, быструю установку, параметры запуска, env-переменные и инструкции по развёртыванию регионов.

````markdown
# viavds — webhook proxy & buffer (multi-region)

`viavds` — это сервис-прокс и буфер webhook'ов: принимает все HTTP(S)-запросы на произвольные endpoints, логирует и сохраняет их в очередь (PostgreSQL) и доставляет/проксирует по правилам (routing rules). Проект рассчитан на развёртывание в нескольких регионах (мульти-ВДС) под единым брендовым доменом `viavds.com` (например `nl.viavds.com`, `kz.viavds.com`).

Основные сценарии:
- приём webhook’ов от внешних сервисов (МойСклад, SIP-уведомления и т. п.)
- буферизация и гарантированная доставка (retry, DLQ)
- гибкая маршрутизация входящих запросов (proxy | respond | drop | transform)
- локальная разработка через `cloudflared` (публичный туннель `ngrok.region.viavds.com`)
- запуск в Docker (рекомендованный) или локально без Docker

---

# Быстрый старт (на новом VDS)

> Рекомендуется: управлять зоной `viavds.com` через Cloudflare.

На новый VDS выполните одну команду (пример). Скрипт поднимет Docker, nginx, certbot, cloudflared, клонирует репо и запустит стек.

```bash
curl -sSL "https://raw.githubusercontent.com/e-bash/viavds/master/install/install_viavds.sh" \
  | sudo bash -s -- \
    --wh wh.nl.viavds.com \
    --ngrok ngrok.nl.viavds.com \
    --email ops@viavds.com \
    --repo https://github.com/e-bash/viavds.git \
    --postgres-password VeryStrongPasswordHere \
    [--cf-token YOUR_CLOUDFLARE_DNS_TOKEN]
````

Параметры:

* `--wh` — основной поддомен сервиса (обязателен). Пример: `wh.nl.viavds.com`
* `--ngrok` — поддомен для туннелей (обязателен). Пример: `ngrok.nl.viavds.com`
* `--email` — email для certbot / Let's Encrypt
* `--repo` — URL репозитория (по умолчанию: `https://github.com/e-bash/viavds.git`)
* `--postgres-password` — пароль для Postgres (в docker-compose)
* `--cf-token` — (опционально) Cloudflare API token с правом `Zone:DNS:Edit` для DNS-challenge с certbot

**После установки:**

1. Войти под `deploy` и выполнить `cloudflared tunnel login` (интерактивная авторизация) и `cloudflared tunnel create` / `route dns` для `ngrok.*`.
2. При необходимости выполнить `certbot` вручную, если DNS не был настроен до запуска.

---

# Архитектура

```
Internet -> Cloudflare -> (A record / Cloudflare Tunnel) -> nginx (host) -> docker:viavds -> Postgres
```

* Cloudflare: DNS, WAF, SSL (Full/Full-Strict)
* nginx: TLS termination и reverse-proxy (на хосте)
* Docker stack: `viavds`, `postgres`, (опционально) `n8n`, `redis`
* cloudflared: systemd-туннель на VDS для `ngrok.*`

---

# Особенности и возможности

* Приём *любых* HTTP методов и путей (`app.all('*')`) и запись raw payload в Postgres.
* Правила маршрутизации (`route_rules`) хранятся в базе и поддерживают:

    * matcher: methods, path_regex, headers, query, body_contains
    * action: proxy | respond | drop | enqueue | transform
    * retry: max_attempts, backoff_ms
* Worker использует `FOR UPDATE SKIP LOCKED` для безопасной параллельной обработки.
* Dead-letter queue (DLQ) и попытки retry.
* Настраиваемый retention & cleanup.
* Поддержка трансформаций (ограниченно и sandboxed при необходимости).
* Admin API для CRUD правил (защищённый).

---

# Переменные окружения (`.env`)

Пример `.env` (в корне репо; скрипт автогенерирует базовую версию):

```env
NODE_ENV=production
PORT=14127
HOST=0.0.0.0

DATABASE_HOST=postgres
DATABASE_PORT=5432
DATABASE_NAME=viavds
DATABASE_USER=viavds
DATABASE_PASS=VeryStrongPasswordHere

WORKER_BATCH_SIZE=20
WORKER_LOOP_DELAY_MS=500
WORKER_MAX_ATTEMPTS=5
WORKER_BACKOFF_MS=2000

RETENTION_DAYS=30
CLEANUP_INTERVAL_MINUTES=1440

BASIC_AUTH_USER=admin
BASIC_AUTH_PASS=ChangeMe123!
HMAC_SECRET=ChangeMeSuperSecret

MAX_PAYLOAD_SIZE=5242880

CLOUDFLARE_TUNNEL_NAME=main-vds

LOG_LEVEL=info
```

Ключевые переменные:

* `DATABASE_URL` (если используешь в виде строки) или `DATABASE_*` поля.
* `WORKER_*` — параметры batch-processing.
* `RETENTION_DAYS` — удалять/архивировать старые вебхуки.
* `BASIC_AUTH_*` — доступ к admin endpoints (обязательно сменить в проде).
* `CLOUDFLARE_TUNNEL_NAME` — имя tunnel для cloudflared.

---

# Docker / docker-compose (пример)

В репо присутствует `docker-compose.yml`. Типовая инструкция:

```bash
# В директории репо
docker compose build
docker compose up -d
# посмотреть логи
docker compose logs -f viavds
```

Если используешь GitHub Actions — собирай образ и пушь в registry, затем `docker compose pull` на хосте.

---

# Настройка Cloudflare Tunnel (ngrok-like)

1. На VDS (после установки cloudflared) выполните:

```bash
sudo su - deploy
cloudflared tunnel login
cloudflared tunnel create main-vds
cloudflared tunnel route dns main-vds ngrok.nl.viavds.com
# затем запустить сервис (systemd)
sudo systemctl enable --now cloudflared-tunnel.service
```

2. На локальной машине возьми credentials файл (из `/home/deploy/.cloudflared/`), положи его локально `creds.json` и запускай:

```bash
cloudflared tunnel run --credentials-file ./creds.json --url http://localhost:14127
```

После этого `ngrok.nl.viavds.com` будет вести на локальный порт.

---

# Разворачивание новой площадки (шаблон)

Процесс создания нового региона (пример: Казахстан — `kz.viavds.com` → `wh.kz.viavds.com`, `ngrok.kz.viavds.com`):

1. Создать VDS (kz).
2. В Cloudflare создать записи:

    * `kz.viavds.com` A → IP
    * `wh.kz.viavds.com` A → IP  (или route через tunnel)
    * `ngrok.kz.viavds.com` A → IP  (или route через tunnel)
3. На VDS запустить:

```bash
curl -sSL "https://raw.githubusercontent.com/e-bash/viavds/master/install/install_viavds.sh" \
  | sudo bash -s -- \
    --wh wh.kz.viavds.com \
    --ngrok ngrok.kz.viavds.com \
    --email ops@viavds.com \
    --repo https://github.com/e-bash/viavds.git \
    --postgres-password VeryStrongPass \
    --cf-token <opt:cloudflare_token>
```

4. Сделать `cloudflared tunnel login` и `route dns`.

---

# Мониторинг, бэкапы и поддержка

* Мониторинг: node_exporter / Prometheus + Grafana. Собирать метрики: queue depth (`webhooks_raw` count of `status='new'`), worker errors, Postgres metrics.
* Бэкапы: nightly `pg_dump` в S3 / external storage; хранить не менее 14 дней (или по регламенту).
* Логи: Docker logs + логирование delivery попыток в таблице `deliveries`. Настроить logrotate для nginx и системных логов.
* Алёрты: на превышение очереди, падение worker, свободное место диска < 20%.

---

# Безопасность и best practices

* Админ-API доступны только через Cloudflare Access / IP whitelist / VPN.
* Подпись вебхуков: проверяй HMAC (X-Signature) если провайдер даёт подпись (например, МойСклад).
* Не хранить секреты в репозитории; использовать Vault / GitHub Secrets / encrypted .env.
* Ratelimit на nginx / Cloudflare WAF правила для защиты от DDoS.
* Регулярные обновления образов и системы через CI/CD и patching schedule.

---

# Contribution & Development

* Разработка локально: используй mkcert для `wh.<project>.loc` и локальный nginx reverse-proxy.
* Запуск локального стека: `docker compose up -d` (поднять Postgres, viavds).
* Тесты: unit tests для matcher/transform; integration tests для worker flow.
* PR workflow: push → GH Actions build → tests → image build → manual deploy.

---

# Contact / Ops

* E-mail: [ops@viavds.com](mailto:ops@viavds.com) (вставь реальный)
* Telegram: @yourops (при необходимости)

````

---

# 5. Дополнительно: шаблон команды для массового создания регионов
Если у тебя будет скрипт автоматического provisioning (Terraform / Ansible), используй шаблон:

```bash
# Provision + deploy region
REGION=nl
VDS_IP=45.114.60.50
WH=wh.${REGION}.viavds.com
NG=ngrok.${REGION}.viavds.com
ssh root@$VDS_IP "bash -s" < <(curl -sSL https://raw.githubusercontent.com/e-bash/viavds/master/install/install_viavds.sh) --wh $WH --ngrok $NG --email ops@viavds.com --repo https://github.com/e-bash/viavds.git --postgres-password VeryStrongPass
````

---

# 6. Заключение и следующий шаг

План масштабирования у тебя уже выстроен: единый бренд `viavds.com`, региональные поддомены, шаблон установки и cloudflared для публичных туннелей. Следующие шаги, которые я могу сделать прямо сейчас по твоему запросу:

* Подготовить готовый `README.md` (я уже сгенерировал выше — скажи, заливать ли прямо в репо).
* Добавить в репо `install` документацию и примеры команд (если хочешь — я подготовлю PR/patch в виде text, а ты закоммитишь).
* Подготовить GitHub Actions workflow для сборки/публикации образов.

Как хочешь действовать дальше? Вставить README в репо и/или сгенерировать PR с installer + readme (я дам команды, чтобы ты сам применил), или сделать ещё что-то?
