# happroxy — семейный VPN-сервер для [Happ](https://www.happ.su/main/ru)

[3X-UI](https://github.com/MHSanaei/3x-ui) в Docker на Ubuntu 24.04: подписки, split-tunnel для РФ, HTTPS через Traefik.

---

## Содержание

1. [Архитектура](#архитектура)
2. [Быстрый старт](#быстрый-старт)
3. [HTTPS и Traefik](#https-и-traefik)
4. [URL и доступ](#url-и-доступ)
5. [Настройка 3X-UI](#настройка-3x-ui)
6. [Happ](#happ)
7. [Маршрутизация (RU)](#маршрутизация-ru)
8. [Скрипты](#скрипты)
9. [Эксплуатация](#эксплуатация)
10. [Устранение неполадок](#устранение-неполадок)
11. [Фаза 2](#фаза-2)

---

## Архитектура

```
Клиент Happ
    │
    ├── HTTPS ──► Traefik (web, :443, LE) ──► 3X-UI панель :38471
    │              └── /sub/ ───────────────► подписка :2096
    │
    └── VPN ──► SERVER_IP напрямую (не через Traefik):
                VLESS Reality :4433 │ SS :8388 │ VMess :16888 │ HY2 :4443
```


| Компонент    | Где                                           |
| ------------ | --------------------------------------------- |
| Код, compose | `/opt/happroxy` (git pull)                    |
| Данные 3X-UI | `/opt/happdata` (`DATA_DIR`)                  |
| Traefik      | Docker-сеть `web`, resolver `le` (на этой VM) |


**Занятые порты VM (не трогать):** 80, 443, 8080, 8000, 9443, 10086, 17998 — Traefik, Portainer, wg-dashboard.

**Порты happroxy:**


| Сервис            | `.env`        | Порт  |
| ----------------- | ------------- | ----- |
| Панель            | `PANEL_PORT`  | 38471 |
| Подписка (внутр.) | `SUB_PORT`    | 2096  |
| VLESS Reality     | `VLESS_PORT`  | 4433  |
| Shadowsocks       | `SS_PORT`     | 8388  |
| VMess             | `VMESS_PORT`  | 16888 |
| Hysteria2         | `HY2_PORT`    | 4443  |
| Trojan (опц.)     | `TROJAN_PORT` | 8443  |


---



## Быстрый старт

```bash
git clone <repo-url> /opt/happroxy
cd /opt/happroxy
sudo bash scripts/install.sh
```

`install.sh` спросит **публичный IP** и (опционально) **домен** для HTTPS, затем:
Docker, swap 2G, `/opt/happdata`, UFW, self-signed cert, `docker compose up -d`.

Без интерактива (CI / скрипты): задайте `SERVER_IP` и при необходимости `PANEL_DOMAIN` в `.env`, затем:

```bash
HAPPROXY_NON_INTERACTIVE=1 sudo bash scripts/install.sh --non-interactive
```

После установки — [настройка 3X-UI](#настройка-3x-ui). Если домен не задавали — [HTTPS](#https-и-traefik) позже через `setup-https.sh`.

---



## HTTPS и Traefik

Панель и подписка — **через Traefik** (TLS Let's Encrypt). Прокси-трафик (VLESS/SS/VMess/HY2) — **на IP сервера**, порты из `.env`.

### DNS


| Тип | Имя             | Значение      |
| --- | --------------- | ------------- |
| A   | `vpn` (или `@`) | `<SERVER_IP>` |


Пример: `vpn.example.com` → IP вашей VM.

### Установка / повторная настройка

```bash
cd /opt/happroxy
git pull
sudo bash scripts/setup-https.sh --domain vpn.example.com --docker-labels
```

Или без флага `--domain` — скрипт спросит FQDN и путь к `acme.json` (интерактивно).

Скрипт: `PANEL_DOMAIN` в `.env`, Traefik labels (`[docker-compose.traefik.yml](docker-compose.traefik.yml)`), HTTPS `subURI` в SQLite.

### Проверка

```bash
bash scripts/verify-traefik.sh   # сеть web, labels, правила
bash scripts/show-urls.sh        # реальные URL панели и подписки
```

В Traefik → HTTP Routers: `happroxy-panel@docker`, `happroxy-sub@docker`.

### Перезапуск (с Traefik)

```bash
docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d --force-recreate
```

> `repair-panel.sh` и `update.sh` автоматически используют Traefik overlay, если в `.env` задан `PANEL_DOMAIN`.



### Сертификаты для Hysteria2

Traefik хранит LE в `acme.json`. Для inbounds:

```bash
sudo bash scripts/sync-traefik-certs.sh
docker restart happroxy_3xui
```

В inbound HY2/Trojan: `/root/cert/fullchain.pem`, `/root/cert/privkey.pem`.

**Cron (inbounds):**

```cron
0 4 * * * root cd /opt/happroxy && bash scripts/sync-traefik-certs.sh && docker restart happroxy_3xui
```



### Переменные `.env` (HTTPS)


| Переменная              | Пример                              |
| ----------------------- | ----------------------------------- |
| `SERVER_IP`             | публичный IPv4 VM                   |
| `PANEL_DOMAIN`          | `vpn.example.com`                   |
| `USE_HTTPS`             | `true`                              |
| `TRAEFIK_CERT_RESOLVER` | `le`                                |
| `TRAEFIK_ACME_FILE`     | путь к `acme.json` Traefik на хосте |


File-provider Traefik (опционально): `[config/traefik/happroxy.yml](config/traefik/happroxy.yml)`.

---



## URL и доступ

```bash
bash scripts/show-urls.sh
```


| Что                           | URL                                                                    |
| ----------------------------- | ---------------------------------------------------------------------- |
| Панель                        | `https://<PANEL_DOMAIN><webBasePath>/` — путь из БД, **не всегда** `/` |
| Подписка                      | `https://<PANEL_DOMAIN>/sub/family/<subId>`                            |
| Панель напрямую (без Traefik) | `http://<SERVER_IP>:38471<webBasePath>/`                               |


**404 на** `https://domain/` — норма: откройте URL из `show-urls.sh` или:

```bash
sudo bash scripts/repair-panel.sh --reset-web-path
```

---



## Настройка 3X-UI

Панель на **русском**. Первый вход: `admin` / `admin` → сразу смените пароль.

### Панель → Подписка


| Поле                     | Значение                                 |
| ------------------------ | ---------------------------------------- |
| **Включить подписку**    | да                                       |
| **Прослушивание IP**     | **пусто**                                |
| **Порт подписки**        | `2096`                                   |
| **URI-путь**             | `/sub/family/`                           |
| **URI обратного прокси** | `https://<PANEL_DOMAIN>/sub/family/`     |
| **Заголовок подписки**   | `Семейный VPN` (= `Name` в routing JSON) |
| **Интервал обновления**  | `6` ч                                    |




### Входящие подключения


| Имя             | Протокол         | Порт  | Примечание                                        |
| --------------- | ---------------- | ----- | ------------------------------------------------- |
| `vless-reality` | VLESS + Reality  | 4433  | **рекомендуемый** (`setup-vless-reality.sh`)      |
| `hy2-main`      | Hysteria2        | 4443  | TLS: `/root/cert/fullchain.pem` + `privkey.pem`   |
| `ss-fallback`   | Shadowsocks 2022 | 8388  | fallback до миграции (`2022-blake3-aes-256-gcm`)  |
| `vmess-tcp`     | VMess TCP        | 16888 | без TLS, legacy                                   |


У каждого inbound: **Стратегия адреса** → `<PANEL_DOMAIN>` (или IP без домена).

**Trojan :8443** — не создавайте без cert; сломанный inbound ломает Xray → `repair-panel.sh`.

### Клиенты (до 10)

Email-метки (`family-alice`, …), лимит IP `3`, привязка к inbounds. Sub-ссылка: **Клиенты → Sub-ссылки**.

---



## Happ

1. «+» → **Подписка по URL** → plain URL или `happ://crypt5/...` (см. ниже)
2. Обновить список (pull-to-refresh)
3. Подключиться

**Порядок протоколов (если что-то не работает):**

1. **VLESS Reality** `4433` — основной (Phase 2)
2. **Shadowsocks** `8388` — fallback, пока `ENABLE_LEGACY_INBOUNDS=true`
3. **VMess** `16888`
4. **Hysteria2** `4443` — нужен UDP + TLS (после `sync-traefik-certs.sh`)

### Encrypted subscription (Phase 2)

```bash
bash scripts/generate-crypto-subscription.sh
```

Выдаёт `happ://crypt5/...` — адрес подписки скрыт от пользователя. Раздайте семье **crypto-ссылку**, не plain HTTPS URL.

После смены subId или миграции — перегенерировать и переимпортировать в Happ.

После правок routing — **обновить подписку** в Happ.

---



## Маршрутизация (RU)

Шаблон: `[config/happ-routing.json](config/happ-routing.json)` — RU/private напрямую, остальное через VPN.

```bash
bash scripts/generate-routing-deeplink.sh
```

Вставьте `happ://routing/add/...` в **Подписка → Правила маршрутизации**. Скрипт добавляет `SERVER_IP/32` и `<PANEL_DOMAIN>` в direct (панель доступна при включённом Happ).

`Name` в JSON = **Заголовок подписки** в панели.

---



## Скрипты


| Скрипт                         | Назначение                                      |
| ------------------------------ | ----------------------------------------------- |
| `fix-happ-eof.sh`            | Happ EOF: подписка только SS + инструкции |
| `disable-vless-inbound.sh`   | Отключить VLESS в подписке |
| `fix-vless-client.sh`        | VLESS не коннектится: sync UUID + опционально новый порт |
| `migrate-vless-port.sh`      | Перенос VLESS Reality на другой TCP-порт                 |
| `watch-vless-connect.sh`     | Смотреть, доходят ли клиенты на VLESS-порт               |
| `print-client-port-test.sh`  | Сгенерировать тест портов для Windows (PowerShell)       |
| `setup-vless-reality.sh`       | VLESS Reality inbound (Phase 2)                 |
| `generate-crypto-subscription.sh` | `happ://crypt5/...` encrypted sub            |
| `migrate-phase2.sh`            | Отключить SS/VMess/HY2 после проверки VLESS     |
| `install.sh`                   | Первичная установка (интерактивно: IP + домен)  |
| `setup-https.sh`               | Домен + Traefik labels + HTTPS subURI           |
| `repair-panel.sh`              | SQLite: subListen, subURI, удаление Trojan:8443 |
| `show-urls.sh`                 | Panel + subscription URL (webBasePath)          |
| `verify-traefik.sh`            | Labels, сеть `web`, правила Traefik             |
| `generate-routing-deeplink.sh` | Happ routing deeplink                           |
| `diagnose-client.sh`           | Нет интернета на клиенте                        |
| `sync-traefik-certs.sh`        | LE из acme.json → `/opt/happdata/cert/`         |
| `healthcheck.sh`               | Порты, контейнер, подписка                      |
| `backup.sh` / `update.sh`      | Бэкап / обновление образа                       |
| `configure-firewall.sh`        | UFW                                             |
| `validate.sh`                  | Проверка репозитория                            |
| `acceptance-test.sh`           | Чеклист перед выдачей семье                     |


Запуск: `bash scripts/<имя>.sh` (не `./`, если нет execute bit).

---



## Эксплуатация



### Проверки

```bash
bash scripts/validate.sh
bash scripts/healthcheck.sh
bash scripts/acceptance-test.sh
```



### Бэкап / восстановление

```bash
bash scripts/backup.sh
# архив: /opt/happdata/backups/happroxy_YYYYMMDD_HHMMSS.tar.gz
```

Восстановление:

```bash
docker compose -f docker-compose.yml -f docker-compose.traefik.yml down
sudo tar -xzf /opt/happdata/backups/happroxy_....tar.gz -C /opt/happdata
# .env из архива → /opt/happroxy/.env при необходимости
docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d
```



### Cron

```cron
# /etc/cron.d/happroxy
0 3 * * * root cd /opt/happroxy && bash scripts/backup.sh >> /var/log/happroxy-backup.log 2>&1
*/15 * * * * root cd /opt/happroxy && bash scripts/healthcheck.sh >> /var/log/happroxy-health.log 2>&1
0 4 * * * root cd /opt/happroxy && bash scripts/sync-traefik-certs.sh && docker restart happroxy_3xui
0 4 * * 0 root cd /opt/happroxy && bash scripts/update.sh >> /var/log/happroxy-update.log 2>&1
```



### Данные на диске

```
/opt/happdata/
├── db/        SQLite, настройки, клиенты
├── cert/      TLS для HY2/Trojan
└── backups/   архивы backup.sh
```

Значения с пробелами в `.env` — в кавычках: `SUB_PROFILE_TITLE="Семейный VPN"`.

---



## Устранение неполадок


| Проблема                                             | Решение                                                                                                           |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Crash loop / `bind: cannot assign requested address` | `sudo bash scripts/repair-panel.sh`                                                                               |
| Нет роутеров в Traefik                               | `docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d --force-recreate` + `verify-traefik.sh` |
| `https://domain/` → 404                              | `bash scripts/show-urls.sh` или `--reset-web-path`                                                                |
| Happ «Ошибка запуска ядра: EOF»                       | `sudo bash scripts/fix-happ-eof.sh`; manual `ss://`; очистить routing в Happ |
| Нет интернета в Happ (VLESS)                         | `sudo bash scripts/fix-vless-client.sh --migrate-port 8444`; `watch-vless-connect.sh`                           |
| VLESS: пакетов нет на порту                          | `print-client-port-test.sh` на ПК; SS OK → миграция порта                                                         |
| Нет vless:// в подписке                              | `sudo bash scripts/setup-vless-reality.sh`, обновить подписку                                                   |
| HY2 `n/a`                                            | SS/VMess; для HY2 — `sync-traefik-certs.sh`, insecure в Happ                                                      |
| Панель недоступна при Happ на ПК                     | `generate-routing-deeplink.sh` → обновить подписку                                                                |
| Подписка с `127.0.0.1`                               | `repair-panel.sh`, проверить **URI обратного прокси**                                                             |
| Xray не стартует                                     | Trojan :8443 без cert — удалить inbound                                                                           |
| Routing не применяется                               | `Name` = **Заголовок подписки**                                                                                   |


Логи: `docker logs happroxy_3xui --tail 50`

---



## Фаза 2

### Быстрый путь

```bash
sudo bash scripts/setup-vless-reality.sh      # VLESS inbound
bash scripts/diagnose-client.sh               # vless:// в подписке
# Проверить VLESS в Happ на всех устройствах
bash scripts/generate-crypto-subscription.sh  # happ://crypt5/...
sudo bash scripts/migrate-phase2.sh --dry-run
sudo bash scripts/migrate-phase2.sh --apply   # отключить SS/VMess/HY2
```

### Статус

- [x] VLESS + Reality (`setup-vless-reality.sh`, порт `4433`)
- [x] Happ encrypted subscriptions (`generate-crypto-subscription.sh`)
- [x] Миграция на единый inbound (`migrate-phase2.sh`)
- [ ] Provider ID / App management — после регистрации на [happ-proxy.com](https://happ-proxy.com)
- [ ] VMess WebSocket + TLS — отложено, если VLESS не подойдёт на части устройств

Переменные `.env`: `VLESS_PORT`, `REALITY_*`, `ENABLE_LEGACY_INBOUNDS` (по умолчанию `true` до миграции).

---



## Структура репозитория

```
happroxy/
├── docker-compose.yml
├── docker-compose.traefik.yml
├── .env.example
├── config/
│   ├── happ-routing.json
│   ├── inbound-vless-reality.json.template
│   └── traefik/happroxy.yml      # опционально, file provider
└── scripts/
    ├── lib/                      # load-env, prompt, data-dir, db, compose, public-url
    ├── install.sh
    ├── setup-https.sh
    ├── repair-panel.sh
    ├── show-urls.sh
    ├── verify-traefik.sh
    └── ...
```

