# happroxy — сервер прокси для клиента [Happ](https://www.happ.su/main/ru)

Развёртывание [3X-UI](https://github.com/MHSanaei/3x-ui) в Docker на Ubuntu 24.04 с подписками для семейного использования (до 10 пользователей).

## Быстрый старт

```bash
git clone <repo-url> happroxy
cd happroxy
sudo bash scripts/install.sh
```

Скрипт `install.sh`:
- проверяет Docker (не переустанавливает, если уже есть);
- создаёт **постоянное хранилище** `/opt/happdata` (БД, сертификаты, бэкапы);
- создаёт swap 2 GB (важно при 1 GB RAM);
- генерирует `.env` и self-signed сертификат;
- проверяет конфликты портов;
- настраивает UFW;
- запускает `docker compose up -d`.

Панель: `http://<SERVER_IP>:38471/` (HTTP) или `https://<PANEL_DOMAIN>/` после [перехода на HTTPS](#https-и-домен-idpro13ru)

### HTTPS и домен idpro13.ru

На VM уже работает **Traefik** (порты 80/443). Панель и подписка выводятся на домен через Traefik; **Let's Encrypt** — для HY2/Trojan inbounds.

**Рекомендуемый поддомен:** `vpn.idpro13.ru` (основной `idpro13.ru` остаётся свободным).

#### 1. DNS

У регистратора домена:

| Тип | Имя | Значение |
|-----|-----|----------|
| A | `vpn` | `31.15.19.102` (ваш `SERVER_IP`) |

Проверка: `dig +short vpn.idpro13.ru` → IP сервера.

#### 2. Traefik — Docker labels (ваша конфигурация)

Ваш Traefik (`/opt/webserver/reverse-proxy`):
- сеть **`web`**, resolver **`le`**, TLS challenge
- только **Docker provider** (file provider не нужен)

```bash
cd /opt/happroxy
git pull

# DNS: A vpn.idpro13.ru → SERVER_IP

sudo bash scripts/setup-https.sh --domain vpn.idpro13.ru --docker-labels
```

Скрипт:
- пропишет `PANEL_DOMAIN` в `.env`;
- подключит контейнер к сети `web` с labels ([`docker-compose.traefik.yml`](docker-compose.traefik.yml));
- обновит **URI обратного прокси** → `https://vpn.idpro13.ru/sub/family/`;
- попытается скопировать LE-сертификат из `acme.json` для Hysteria2.

Откройте **`https://vpn.idpro13.ru/`** — Traefik выпустит сертификат. Затем:

```bash
sudo bash scripts/sync-traefik-certs.sh
docker restart happroxy_3xui
```

Ручной перезапуск с Traefik overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d
```

Альтернатива (file provider, если добавите `--providers.file` в Traefik): [`config/traefik/happroxy.yml`](config/traefik/happroxy.yml), resolver `le`, upstream `172.18.0.1`.

#### 3. Панель 3X-UI

| Поле | Значение |
|------|----------|
| **URI обратного прокси** | `https://vpn.idpro13.ru/sub/family/` |
| **Прослушивание IP** | пусто |

**Входящие** → у каждого подключения **Стратегия адреса** → пользовательский: `vpn.idpro13.ru`.

Hysteria2 / Trojan — пути к сертификату:

```
/root/cert/fullchain.pem
/root/cert/privkey.pem
```

(после `sudo bash scripts/sync-le-certs.sh` — настоящий LE, без `insecure` в Happ).

#### 4. Happ

1. Удалите старую подписку с `http://IP:...`
2. Добавьте: `https://vpn.idpro13.ru/sub/family/<subId>`
3. Обновите routing: `bash scripts/generate-routing-deeplink.sh` → вставить в панель → обновить подписку в Happ

#### 5. Автопродление (inbounds, из Traefik acme.json)

```cron
0 4 * * * root cd /opt/happroxy && bash scripts/sync-traefik-certs.sh && docker restart happroxy_3xui
```

Панель и подписка на HTTPS обновляются Traefik автоматически (его ACME).

#### Переменные `.env`

| Переменная | Пример |
|------------|--------|
| `PANEL_DOMAIN` | `vpn.idpro13.ru` |
| `USE_HTTPS` | `true` |
| `LE_CERT_DIR` | `/etc/letsencrypt/live/vpn.idpro13.ru` |

### Панель недоступна / crash loop

```bash
cd /opt/happroxy
git pull
sudo bash scripts/repair-panel.sh
```

Скрипт автоматически: останавливает контейнер, чинит `subListen`/подписку в SQLite, удаляет сломанный Trojan:8443, перезапускает сервис.

## Постоянные данные (вне контейнера)

Все настройки и данные 3X-UI хранятся на диске хоста и **не теряются** при пересоздании или обновлении контейнера:

```
/opt/happdata/
├── db/        → SQLite, настройки панели, клиенты, inbounds
├── cert/      → TLS-сертификаты для Hysteria2 / Trojan
└── backups/   → архивы backup.sh
```

Путь задаётся переменной `DATA_DIR` в `.env` (по умолчанию `/opt/happdata`).

Значения с пробелами в `.env` заключайте в кавычки, например: `SUB_PROFILE_TITLE="Семейный VPN"`.

Код проекта (`happroxy/`) можно обновлять через `git pull` — данные остаются в `/opt/happdata`.

## Занятые порты на этой VM (не использовать)

| Сервис | Порты |
|---|---|
| traefik_proxy | 80, 443, 8080 |
| portainer | 8000, 9443 |
| wgdashboard | 10086, 17998 |

## Порты happroxy

| Сервис | Переменная | Порт |
|---|---|---|
| Панель 3X-UI | `PANEL_PORT` | 38471 |
| Подписка 3X-UI | `SUB_PORT` | 2096 |
| Hysteria2 | `HY2_PORT` | 4443 (UDP+TCP) |
| Shadowsocks 2022 | `SS_PORT` | 8388 |
| VMess TCP | `VMESS_PORT` | 16888 |
| Trojan (опц.) | `TROJAN_PORT` | 8443 |

Измените порты в `.env`, если заняты.

## Структура проекта

```
happroxy/                    # код и docker-compose (можно обновлять)
├── docker-compose.yml
├── .env.example          → скопируйте в .env
├── config/
│   └── happ-routing.json
└── scripts/
    └── ...

/opt/happdata/               # данные (независимо от контейнера)
├── db/
├── cert/
└── backups/
```

---

## Настройка 3X-UI

Панель на **русском языке** (переключатель языка в интерфейсе, если нужно: **Русский**).

После первого входа (`admin` / `admin`) **сразу смените пароль** в **Настройки панели → Учетная запись**.

### 1. Настройки панели → Панель

| Поле в панели | Значение |
|---|---|
| **Порт панели** | `38471` (должен совпадать с `.env`) |

Нажмите **Сохранить**, затем **Перезапустить панель** (если панель предложит).

### 2. Настройки панели → Подписка

| Поле в панели | Значение |
|---|---|
| **Включить подписку** | включено |
| **Прослушивание IP** | **оставить пустым** (иначе bind error на публичный IP) |
| **Порт подписки** | `2096` (внутренний, по умолчанию — не менять) |
| **URI-путь** | `/sub/family/` (со слэшем в конце) |
| **URI обратного прокси** | `https://vpn.idpro13.ru/sub/family/` (или `http://<SERVER_IP>:2096/sub/family/` без домена) |
| **Заголовок подписки** | `Семейный VPN` (≤25 символов, для Happ) |
| **Интервалы обновления подписки** | `6` (часов) |

> **Важно:** в **Прослушивание IP** нельзя указывать публичный IP VM (`31.x.x.x`). Это поле — для *привязки* сокета на локальном интерфейсе. Публичный адрес задаётся через **URI обратного прокси** и **Стратегию адреса** у входящих подключений.

**Правила маршрутизации (Happ):**

```bash
bash scripts/generate-routing-deeplink.sh
```

Скопируйте вывод `happ://routing/add/...` в поле **Правила маршрутизации** (вкладка **Подписка**).

Шаблон правил: [`config/happ-routing.json`](config/happ-routing.json) — RU/private IP напрямую, остальное через proxy. Отредактируйте под себя, затем перегенерируйте deeplink.

### 3. Входящие подключения

Создайте подключения: **Входящие → Создать подключение**.

#### Hysteria2 — `hy2-main`

| Поле в панели | Значение |
|---|---|
| Протокол | Hysteria2 |
| **Порт** | `4443` |
| Пропускная способность | по желанию (напр. 100 Mbps) |
| Обфускация | включить (пароль — любой) |
| **Безопасность** / TLS | self-signed |
| **Путь к сертификату** | `/root/cert/selfsigned.crt` |
| **Путь к приватному ключу** | `/root/cert/selfsigned.key` |

> Сертификаты на хосте: `/opt/happdata/cert/` (= `/root/cert/` в контейнере).  
> Проверка: `ls /opt/happdata/cert/` — должны быть `selfsigned.crt` и `selfsigned.key`.

#### Shadowsocks 2022 — `ss-fallback`

| Поле в панели | Значение |
|---|---|
| Протокол | Shadowsocks |
| **Порт** | `8388` |
| **Метод** | `2022-blake3-aes-256-gcm` |
| **Пароль** | сгенерировать в панели |

#### VMess TCP — `vmess-tcp`

| **Поле в панели** | Значение |
|---|---|
| Протокол | VMess |
| **Порт** | `16888` |
| **Транспорт** | TCP |
| **Безопасность** | none (без TLS) |
| UUID | сгенерировать в панели |

#### Trojan (опционально, по умолчанию выключен)

| Поле в панели | Значение |
|---|---|
| Протокол | Trojan |
| **Порт** | `8443` |
| **Безопасность** → TLS | включено |
| **Путь к сертификату** | `/root/cert/selfsigned.crt` |
| **Путь к приватному ключу** | `/root/cert/selfsigned.key` |

Если сертификаты не указаны, Xray **не запустится** (`both file and bytes are empty`).  
Рекомендация: **не создавайте Trojan** на первом этапе — достаточно Hysteria2 + Shadowsocks + VMess.  
Если Trojan уже создан с ошибкой — **удалите** его в **Входящие** или исправьте пути к сертификатам.

### 4. Клиенты (семья, до 10)

**Клиенты → Добавить клиента** (или добавьте клиента при создании подключения):

| Поле в панели | Рекомендация |
|---|---|
| **Email** | `family-alice`, `family-bob`, … (любой текст-метка) |
| **Лимит трафика (ГБ)** | 100–300 |
| **Срок действия** | по желанию |
| **Лимит IP** | `3` (телефон + ПК + планшет) |

Привяжите клиента к нужным входящим подключениям.

Скопируйте **URL подписки** клиента (**Клиенты → Sub-ссылки** или **Подробнее** у клиента):

```
https://vpn.idpro13.ru/sub/family/<subId>
```

или (без домена):

```
http://<SERVER_IP>:2096/sub/family/<subId>
```

### 5. Проверка подписки

Откройте ссылку в браузере (принять self-signed). В ответе должны быть строки:

```
hy2://...
ss://...
vmess://...
```

Адрес в ссылках — **публичный IP**, не `127.0.0.1`.

---

## Подключение в Happ

1. Установите [Happ](https://www.happ.su/main/ru) на устройство.
2. «+» → **Подписка по URL** → вставьте URL подписки.
3. Обновите список (pull-to-refresh).
4. Выберите сервер → **Подключить**.
5. Разрешите VPN-профиль (iOS/Android).

**Приоритет протоколов:**
1. Hysteria2 (`4443`) — основной
2. Shadowsocks (`8388`) — если UDP заблокирован
3. VMess (`16888`) — запасной

После настройки правил маршрутизации — обновите подписку в Happ.

---

## Эксплуатация

### Проверка состояния

```bash
chmod +x scripts/*.sh
bash scripts/validate.sh          # статическая проверка репозитория
bash scripts/healthcheck.sh       # после запуска контейнера
bash scripts/acceptance-test.sh   # полный чеклист перед выдачей ключей семье
```

### Бэкап

```bash
bash scripts/backup.sh
```

Архивы: `/opt/happdata/backups/happroxy_YYYYMMDD_HHMMSS.tar.gz`

**Восстановление:**

```bash
docker compose down
sudo tar -xzf /opt/happdata/backups/happroxy_YYYYMMDD_HHMMSS.tar.gz -C /opt/happdata
# .env из архива — при необходимости скопируйте в каталог happroxy/
docker compose up -d
```

### Обновление 3X-UI

```bash
bash scripts/update.sh
```

### Cron (на VM)

```cron
# /etc/cron.d/happroxy
0 3 * * * root cd /opt/happroxy && bash scripts/backup.sh >> /var/log/happroxy-backup.log 2>&1
*/15 * * * * root cd /opt/happroxy && bash scripts/healthcheck.sh >> /var/log/happroxy-health.log 2>&1
0 4 * * 0 root cd /opt/happroxy && bash scripts/update.sh >> /var/log/happroxy-update.log 2>&1
```

Замените `/opt/happroxy` на путь к репозиторию.

---

## Безопасность

- Панель на нестандартном порту `38471`
- Сильный пароль администратора (генерируется в `install.sh`)
- `XUI_ENABLE_FAIL2BAN=true` — бан при превышении лимита IP
- UFW открывает только нужные порты
- Не проксируйте панель через Traefik на 443 — оставьте прямой доступ

---

## Устранение неполадок

| Проблема | Решение |
|---|---|
| `both file and bytes are empty` / `in-8443-tcp` | Trojan (8443) без TLS-сертификата — **удалите** inbound или укажите `/root/cert/selfsigned.crt` + `.key` |
| `bind: cannot assign requested address` + публичный IP | `sudo bash scripts/repair-panel.sh` |
| `Error starting sub server` | То же — **Прослушивание IP** должно быть пустым; перезапустите панель |
| Xray не стартует после добавления inbound | Проверьте лог: чаще всего TLS без сертификата на Trojan/HY2 |
| Подписка с `127.0.0.1` | Заполните **URI обратного прокси**; у inbound → **Стратегия адреса для ссылок** → пользовательский IP |
| Порт занят | Измените в `.env`, перезапустите: `docker compose up -d` |
| Happ не подключается (HY2) | Попробуйте Shadowsocks или VMess |
| OOM / контейнер падает | Убедитесь в swap; оставьте HY2 + SS |
| Маршрутизация не применяется | Имя профиля в routing JSON = **Заголовок подписки**; обновите подписку |
| Панель недоступна при включённом Happ на ПК | IP сервера шёл в туннель — `bash scripts/generate-routing-deeplink.sh` → обновить подписку |
| healthcheck: Panel HTTP 404 | Часто норма (кастомный путь панели); смотрите `sudo bash scripts/diagnose-client.sh` |
| **Нет интернета на клиенте при подключённом Happ** | См. раздел ниже; на сервере: `sudo bash scripts/diagnose-client.sh` |
| Shadowsocks/VMess deprecated | Предупреждение Xray 26.x — не критично; в фазе 2 перейти на VLESS |

### Панель пропала после подключения Happ на том же ПК

**Причина:** при `GlobalProxy: true` браузер открывает `http://IP:38471/` **через VPN-туннель на этот же сервер** — получается петля, страница не открывается. Сервер при этом работает.

**Сразу:**
1. **Отключите Happ** на ПК — панель снова откроется.
2. Или зайдите с **телефона без VPN** / по **SSH** на сервер.

**Постоянное решение — IP сервера в Direct (напрямую):**

```bash
cd /opt/happroxy
bash scripts/generate-routing-deeplink.sh
```

Скопируйте новый `happ://routing/add/...` в **Настройки панели → Подписка → Правила маршрутизации**, сохраните, в Happ **обновите подписку**.

Скрипт добавляет в маршрутизацию `31.x.x.x/32` (ваш `SERVER_IP`) — трафик к панели и подписке идёт **мимо** туннеля.

**Проверка с сервера** (если кажется, что «всё упало»):

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:38471/
docker ps | grep happroxy
```

### Нет интернета на клиенте (Happ подключён)

**Что происходит:** при подключённом Happ **весь** трафик идёт через VPN (режим TUN), даже если routing rules пустые. Если туннель не работает — интернет **полностью** пропадает.

**Шаг 1 — сразу на ПК:**
1. **Отключите Happ** — интернет должен вернуться за 1–2 сек.
2. Если не вернулся — перезапустите Happ / сбросьте сетевой адаптер Windows.

**Шаг 2 — на сервере (SSH с телефона или другого ПК):**
```bash
cd /opt/happroxy
sudo bash scripts/diagnose-client.sh
sudo bash scripts/repair-panel.sh   # если Xray в ошибке
```

**Шаг 3 — упростить до рабочего минимума:**

1. **Настройки панели → Подписка → Правила маршрутизации** — **очистите** (временно!) и сохраните.
2. В Happ **обновите подписку**.
3. Подключитесь к серверу **VMess (16888)** или **Shadowsocks (8388)**, не Hysteria2.
4. Если VMess/SS работает — интернет есть; потом снова добавьте routing через `generate-routing-deeplink.sh`.

**Частые причины:**

| Причина | Что делать |
|---|---|
| Xray не запущен (Trojan 8443 без cert) | `sudo bash scripts/repair-panel.sh` |
| Выбран Hysteria2, UDP/сертификат не проходит | Переключиться на **Shadowsocks** |
| Routing `GlobalProxy: true`, прокси мёртв | Временно убрать routing rules |
| Подписка с `127.0.0.1` | `sudo bash scripts/repair-panel.sh` + обновить подписку |
| Inbound «Слушать» = `127.0.0.1` | Очистить поле **Слушать** во входящих |
| Клиент отключён / лимит трафика | **Клиенты** → проверить статус |

**Порядок теста протоколов в Happ:**
1. Shadowsocks `8388`
2. VMess `16888`
3. Hysteria2 `4443` (последним)

---

## Фаза 2 (когда появится домен)

1. A-record домена → IP VM
2. Let's Encrypt в 3X-UI (acme.sh)
3. Inbound VLESS + Reality
4. VMess WebSocket + TLS
5. Provider ID → Happ App management
6. Зашифрованные подписки `happ://crypto...`
