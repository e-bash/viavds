Отлично — всё логично, ты всё понял правильно, и давай я упрощу и исправлю концепцию под твою реальную задачу.

Кратко по смыслу — самое важное:

* На **VDS** нам надо разворачивать только сервисную пару поддоменов:

  * `wh.<zone>` — сам сервис **viavds** (приём/буферизация webhook’ов)
  * `ngrok.<zone>` — «ngrok-подобный» публичный адрес через Cloudflare Tunnel (чтобы ты мог пробрасывать локальные порты)
* На **локальной машине** (dev) нужен только `wh.<zone>.loc` (и mkcert для него). Для локального «ngrok» никакой записи в /etc/hosts не нужно — локальный cloudflared соединится с публичным `ngrok.<zone>` на VDS.
* Поэтому в инсталляционной команде **не нужен** какой-то глобальный `--domain vianl.ru`. Вместо этого инсталлеру достаточно двух (пара) параметров: `--wh` и `--ngrok` (и email/пароль/репо и т.д.). Так ты сможешь в любой момент на новом сервере запустить:

```bash
curl -sSL https://raw.githubusercontent.com/e-bash/viavds/main/install/install_viavds.sh \
  | sudo bash -s -- \
    --wh wh.viakz.ru \
    --ngrok ngrok.viakz.ru \
    --email admin@viakz.ru \
    --repo https://github.com/e-bash/viavds.git \
    --postgres-password VeryStrongPass
```

и все подхватится под новой зоной `viakz.ru`. Никаких лишних параметров «главного домена» не нужно.

Ниже — что именно я предлагаю сделать (корректировки и объяснения), и какие команды использовать локально и на сервере.

---

# 1) Какие параметры теперь передаём инсталлеру

Инсталлер должен принимать:

* `--wh <wh.example.tld>` — обязателен, например `wh.vianl.ru` или `wh.viakz.ru`
* `--ngrok <ngrok.example.tld>` — обязателен, например `ngrok.vianl.ru`
* `--email <email>` — для certbot (Let’s Encrypt) при желании
* `--repo <git-url>` — репо, по умолчанию `https://github.com/e-bash/viavds.git`
* `--postgres-password <pass>`
* опция `--cf-token <token>` — (опционально) Cloudflare API token для certbot DNS challenge (если у тебя Cloudflare и ты не хочешь переключать прокси)

Пример старта на VDS:

```bash
curl -sSL "https://raw.githubusercontent.com/e-bash/viavds/main/install/install_viavds.sh" \
  | sudo bash -s -- \
    --wh wh.viakz.ru \
    --ngrok ngrok.viakz.ru \
    --email admin@viakz.ru \
    --repo https://github.com/e-bash/viavds.git \
    --postgres-password VeryStrongPass \
    --cf-token XXXXXX-if-you-have-it
```

---

# 2) Что будет на VDS после установки

* nginx (на хосте) — конфиг для `wh.<zone>`: проксирует на Docker-контейнер `viavds:14127` (HTTP). nginx также может обслуживать публичный статический сайт, если надо — но для минимального развёртывания он конфигурируется для `wh` и для `ngrok` (при необходимости).
* Docker stack:

  * `postgres`
  * `viavds` (nodeJS app + worker)
* Certbot (Let’s Encrypt) будет пытаться получить сертификат для `wh.<zone>` и для `ngrok.<zone>`:

  * если DNS указывает на сервер и `--cf-token` не передан — использует HTTP challenge (certbot --nginx),
  * если `--cf-token` передан — использует Cloudflare DNS challenge (не нужно переключать проксирование в Cloudflare).
* cloudflared установлен и systemd unit подготовлен; **вручную** (один раз) нужно:

  * зайти под `deploy` и выполнить `cloudflared tunnel login`
  * создать туннель `cloudflared tunnel create <name>` и `cloudflared tunnel route dns <name> ngrok.<zone>`
  * включить systemd-сервис `sudo systemctl enable --now cloudflared-tunnel.service`

Важно: `cloudflared tunnel login` требует интерактивной авторизации (открывает страницу Cloudflare в браузере). Это нельзя автоматизировать безопасно без API-credentials.

---

# 3) Что делаем локально (macOS / Windows)

* Для локальной разработки тебе нужно:

  * пробрасывать локальный порт n8n/viavds → публичный `ngrok.<zone>` при помощи `cloudflared` клиента:

    * на локальной машине (macOS) ставишь `cloudflared` (brew install cloudflared), делаешь `cloudflared tunnel run --url http://localhost:14127 --name my-local-tunnel` или используешь уже созданный на VDS tunnel credentials (secure). Обычно workflow:

      1. На VDS создаёшь tunnel и даёшь dev-credentials (файл `.json`) локальной машине.
      2. На локали запускаешь `cloudflared tunnel run --credentials-file ./creds.json --url http://localhost:14127` — и тогда публичный `ngrok.<zone>` будет вести к твоему локальному `:14127`.
  * Для браузера локально нужен только `wh.<zone>.loc`, чтобы тестировать https и веб-интерфейс. Для этого делай mkcert:

    ```bash
    brew install mkcert
    mkcert -install
    mkcert wh.vianl.loc
    ```

    и в локальном nginx используй эти сертификаты. Никаких записей для `ngrok` в `/etc/hosts` не требуется.

Итого: локально — только mkcert для `wh.*.loc`, а для отладки вебхуков / публичного доступа — используешь cloudflared, который соединится с `ngrok.<zone>` на VDS.

---

# 4) Почему именно так — причины и преимущества

* **Универсальность**: одна команда разворачивает `wh` + `ngrok` для любой зоны (vianl.ru, viakz.ru и т.д.).
* **Разделение обязанностей**: на VDS у тебя общедоступная инфраструктура (nginx, certs, tunnel), локально — только dev-часть (mkcert + proxy).
* **Нет лишних доменов**: ты не будешь создавать глобальный `vianl.ru`/`vianl.loc` и т.д. — только те, которые реально нужны.
* **Cloudflare Tunnel** (`ngrok.<zone>`) решает проблему публичного доступного адреса к локали, не требуя платного ngrok.

---

# 5) Предлагаемые правки к одному-скрипту (коротко)

Я обновлю инсталлер, чтобы:

* принимать `--wh` и `--ngrok` (вместо одного `--domain`),
* создавать nginx-конфиг только для `wh` (и опционально для `ngrok` если нужно),
* автоматически настраивать certbot для обоих поддоменов (CF token или HTTP challenge),
* выводить понятную инструкцию как связать `ngrok` с cloudflared (точные команды `cloudflared tunnel create` / `route dns` / `service enable`),
* не трогать локальные настройки `*.loc` (mkcert остаётся отдельной инструкцией для dev).

Если хочешь — могу прямо сейчас:

1. прислать обновлённую строку запуска (пример выше) и
2. сгенерировать и запушить в репо изменённый `install/install_viavds.sh` (PR или commit) с поддержкой параметров `--wh` и `--ngrok`, а затем дать готовую `curl | sudo bash` команду.

---

# 6) Примеры команд (с учётом поправок)

## 6.1 Развёртывание на новом VDS (пример)

```bash
curl -sSL "https://raw.githubusercontent.com/e-bash/viavds/main/install/install_viavds.sh" \
  | sudo bash -s -- \
    --wh wh.viakz.ru \
    --ngrok ngrok.viakz.ru \
    --email admin@viakz.ru \
    --repo https://github.com/e-bash/viavds.git \
    --postgres-password VeryStrongPass \
    --cf-token XXXXXX    # опционально, если хочешь DNS-challenge
```

## 6.2 Локальная разработка (macOS)

1. Установить mkcert и создать сертификат для `wh.viakz.loc`:

```bash
brew install mkcert
mkcert -install
mkcert wh.viakz.loc
# получишь wh.viakz.loc.pem и wh.viakz.loc-key.pem
```

2. Настроить локальный nginx (пример /etc/nginx/sites-available/wh.viakz.loc):

```nginx
server {
    listen 443 ssl;
    server_name wh.viakz.loc;

    ssl_certificate /path/to/wh.viakz.loc.pem;
    ssl_certificate_key /path/to/wh.viakz.loc-key.pem;

    location / {
        proxy_pass http://127.0.0.1:14127;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

3. Если нужно публичный доступ к локали (для тестирования вебхуков), используй cloudflared:

   * Получи credentials.json, созданный на VDS при `cloudflared tunnel create main-vds`, и положи его локально.
   * Запусти:

```bash
cloudflared tunnel run --credentials-file ./creds.json --url http://localhost:14127
```

Это сделает `ngrok.viakz.ru` (либо другой маршрут) публично доступным и ведущим на твой локальный порт.

---

# 7) Что я сделаю прямо сейчас (если ты скажешь «да, делай»)

* Я обновлю инсталляционный скрипт в repo `e-bash/viavds` (папка `install/`) — чтобы он:

  * принимал `--wh` и `--ngrok`,
  * создавал конфиги nginx только для `wh` (и для `ngrok` в случае необходимости),
  * корректно запускал certbot (CF token опционально),
  * и в конце выдавал минимальную пошаговую инструкцию для cloudflared (создать туннель и route DNS).
* После этого пришлю точную команду `curl | sudo bash` (готовую) и дам финальные инструкции по локальной разработке с mkcert.

---

Если всё устраивает — скажи «да, обнови скрипт» (или просто «делай»), и я внесу изменения в `install/install_viavds.sh` (и пришлю готовую одно-командную строку для развёртывания). Если хочешь сначала посмотреть набросок обновлённого скрипта — могу вставить его тут перед пушем.
