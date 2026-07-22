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

Панель: `https://<SERVER_IP>:38471/`

## Постоянные данные (вне контейнера)

Все настройки и данные 3X-UI хранятся на диске хоста и **не теряются** при пересоздании или обновлении контейнера:

```
/opt/happdata/
├── db/        → SQLite, настройки панели, клиенты, inbounds
├── cert/      → TLS-сертификаты для Hysteria2 / Trojan
└── backups/   → архивы backup.sh
```

Путь задаётся переменной `DATA_DIR` в `.env` (по умолчанию `/opt/happdata`).

Значения с пробелами в `.env` заключайте в кавычки, например: `SUB_PROFILE_TITLE="Family VPN"`.

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

После первого входа (`admin` / `admin`) **сразу смените пароль**.

### 1. Panel Settings → General

- **Panel port**: `38471` (должен совпадать с `.env`)
- Сохраните

### 2. Panel Settings → Subscription

| Поле | Значение |
|---|---|
| Listen IP | Публичный IP VM (`SERVER_IP` из `.env`) |
| Listen Port | `38471` |
| URI Path | `/sub/family` (или значение `SUB_PATH`) |
| Profile title | `Family VPN` (≤25 символов, для Happ) |
| Update interval | `6` (часов) |

**Routing rules (Happ):**

```bash
bash scripts/generate-routing-deeplink.sh
```

Скопируйте вывод `happ://routing/add/...` в **Panel Settings → Subscription → Routing rules**.

Шаблон правил: [`config/happ-routing.json`](config/happ-routing.json) — RU/private IP напрямую, остальное через proxy. Отредактируйте под себя, затем перегенерируйте deeplink.

### 3. Inbounds

Создайте inbound-ы в панели (**Inbounds → Add inbound**).

#### Hysteria2 — `hy2-main`

| Параметр | Значение |
|---|---|
| Protocol | Hysteria2 |
| Port | `4443` |
| Upload/Download bandwidth | по желанию (напр. 100 Mbps) |
| Obfuscation | включить (password — любой) |
| TLS | self-signed |
| Certificate | `/root/cert/selfsigned.crt` |
| Key | `/root/cert/selfsigned.key` |

> Сертификаты на хосте: `/opt/happdata/cert/` (= `/root/cert/` в контейнере).

#### Shadowsocks 2022 — `ss-fallback`

| Параметр | Значение |
|---|---|
| Protocol | Shadowsocks |
| Port | `8388` |
| Method | `2022-blake3-aes-256-gcm` |
| Password | сгенерировать в панели |

#### VMess TCP — `vmess-tcp`

| Параметр | Значение |
|---|---|
| Protocol | VMess |
| Port | `16888` |
| Network | TCP |
| Security | none (без TLS) |
| UUID | сгенерировать в панели |

#### Trojan (опционально) — `trojan-opt`

| Параметр | Значение |
|---|---|
| Protocol | Trojan |
| Port | `8443` |
| TLS | self-signed (`/root/cert/selfsigned.crt`) |

Если Trojan не нужен, установите `ENABLE_TROJAN=false` в `.env` и не создавайте inbound.

### 4. Клиенты (семья, до 10)

Для каждого inbound → **Clients → Add client**:

| Поле | Рекомендация |
|---|---|
| Email / Remark | `family-alice`, `family-bob`, … |
| Traffic limit | 100–300 GB |
| Expiry | по желанию |
| IP limit | `3` (телефон + ПК + планшет) |

Скопируйте **Subscription link** клиента:

```
https://<SERVER_IP>:38471/sub/family/<subId>
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
2. «+» → **Подписка по URL** → вставьте subscription link.
3. Обновите список (pull-to-refresh).
4. Выберите сервер → **Подключить**.
5. Разрешите VPN-профиль (iOS/Android).

**Приоритет протоколов:**
1. Hysteria2 (`4443`) — основной
2. Shadowsocks (`8388`) — если UDP заблокирован
3. VMess (`16888`) — запасной

После настройки routing rules — обновите подписку в Happ.

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
- `XUI_ENABLE_FAIL2BAN=true` — бан при превышении IP limit
- UFW открывает только нужные порты
- Не проксируйте панель через Traefik на 443 — оставьте прямой доступ

---

## Troubleshooting

| Проблема | Решение |
|---|---|
| Подписка с `127.0.0.1` | Задайте Listen IP = публичный IP в Subscription settings |
| Порт занят | Измените в `.env`, перезапустите: `docker compose up -d` |
| Happ не подключается (HY2) | Попробуйте Shadowsocks или VMess |
| OOM / контейнер падает | Убедитесь в swap; отключите Trojan; оставьте HY2+SS |
| Routing не применяется | Имя профиля в routing JSON = profile-title; обновите подписку |

---

## Фаза 2 (когда появится домен)

1. A-record домена → IP VM
2. Let's Encrypt в 3X-UI (acme.sh)
3. Inbound VLESS + Reality
4. VMess WebSocket + TLS
5. Provider ID → Happ App management
6. Зашифрованные подписки `happ://crypto...`
