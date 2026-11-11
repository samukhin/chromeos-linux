# chromeos-linux

**Оболочка ChromeOS Ash. На обычном Linux. Это плохо.**

![screenshot](./ash.png)

Этот репозиторий берёт готовый бинарник ChromiumOS Chrome и запускает его **напрямую на DRM/KMS** (`--ozone-platform=drm`), уча обычный Linux отвечать на ChromeOS D-Bus API, которые ждёт Ash. Ни X-сервера, ни хостового Wayland-композитора в основе нет.

На выходе — десктопная оболочка ChromeOS: шельф, лаунчер, шторка быстрых настроек, системный трей, Terminal SWA — в качестве вашего Linux-десктопа.

Всё здесь — обычные shell-скрипты, Go и Meson: **Nix не нужен** (старая Nix-упаковка удалена). Целевые системы — x86_64 Ubuntu/Debian и Arch; ничего ультра-Ubuntu-specific в коде нет, требуются рабочие glibc, D-Bus, DRM/KMS и evdev.

## Содержание

1. [Как это устроено](#как-это-устроено)
2. [Требования](#требования)
3. [Структура репозитория](#структура-репозитория)
4. [Быстрый старт](#быстрый-старт)
5. [Что делает `setup-system.sh`](#что-делает-setup-systemsh-root-идемпотентен)
6. [Сессия: что происходит при запуске](#сессия-что-происходит-при-запуске)
7. [Переменные окружения](#переменные-окружения)
8. [Патчи бинарника](#патчи-бинарника-applied-at-build-time)
9. [Режим ChromeOS: lsb-release и mojo](#режим-chromeos-lsb-release-и-mojo)
10. [Что работает / сырые места / что не работает](#что-работает)
11. [Лок-экран и разлочка](#лок-экран-и-разлочка)
12. [Проверка и диагностика](#проверка-и-диагностика)
13. [Обновление ревизии Chrome и хакинг](#обновление-ревизии-chrome)
14. [Ограничения безопасности](#ограничения-безопасности)

## Как это устроено

Ash сам владеет дисплеем через DRM/KMS и сам же хостит Wayland-композитор для гостевых Linux-приложений:

```
┌──────────────── /dev/dri/cardN (KMS) ────────────────────┐
│  Ash Chrome  (dist/chrome/chromeos-ash)                  │
│    --ozone-platform=drm                                   │
│    │                                                      │
│    └── хостит Wayland-композитор (exo)                    │
│          $XDG_RUNTIME_DIR/wayland-0                       │
│             └── sommelier (-X)  →  wayland-1              │
│                    └── Xwayland :10 → Linux-приложения    │
└──────────────────────────────────────────────────────────┘
```

* **Ash — это KMS-клиент**: он открывает `/dev/dri/cardN` (номер карты определяется автоматически по подключённому коннектору, `ASH_DRM_CARD` переопределяет), сам настраивает коннектор/CRTC и рисует десктоп напрямую, без Xorg и без чужого композитора. Поэтому запускать сессию нужно с чистой VT, где никто другой не держит DRM master.
* **Ash же — Wayland-сервер**: Chrome запускается с `--enable-wayland-server --wayland-server-socket=wayland-0`, то есть сам принимает Wayland-соединения.
* **sommelier** кладёт перед ним Xwayland на `:10`, поэтому «управляемые» Linux-приложения (Crostini-обвязка) попадают внутрь рабочего стола Ash, а не наружу. Запускаемые из Ash Linux-приложения обязаны ходить в `:10`; за это отвечает `session/stubs/shell-stub.sh`: он форсит `DISPLAY=:10` для запускаемых приложений.

Второй кусок — **Go-бриджи**. Ash уверен, что живёт в ChromeOS и общается с системными демонами по D-Bus системной шины. Бриджи занимают эти имена и переводят вызовы на Linux:

| Имя на шине | Бинарник | Куда уходит |
|---|---|---|
| `org.chromium.flimflam` | `shill-bridge` | NetworkManager (состояние сети, подключение Ethernet/Wi-Fi) |
| `org.chromium.cras` | `cras-bridge` | PulseAudio/PipeWire через `pactl` (громкость, узлы Speaker/Headphone/Mic) |
| `org.chromium.PowerManager` | `power-bridge` | яркость через sysfs, UPower, `systemctl suspend/reboot` |
| `org.chromium.SessionManager`<br>`org.chromium.UserDataAuth` | `session-bridge` | «запущенная сессия», состояние входа, гостевой профиль `/home/chronos/user` |
| `org.chromium.VmConcierge`, `VmCicerone`,<br>`DlcService`, `ImageLoader`, `debugd` | `crostini-bridge` | локальные `.desktop`-файлы: регистрация в лаунчере и запуск приложений на `:10` |
| `org.chromium.Rmad` | `rmad-bridge` | заглушка RMA-демона |
| `/run/mojo/service_manager.sock` | `mojo-stub` | Mojo service manager (ACCEPT_INVITEE + слив сообщений) |
| — | `register-apps` | разовый helper: пишет `crostini.registry` в `Preferences`, чтобы `.desktop`-файлы появились в лаунчере |

Третий кусок — **сессионные скрипты** в `session/`: поднимают бриджи, готовят профиль, инжектируют UI терминала и крутят Ash в цикле перезапуска.

## Требования

* x86_64 (снапшот ChromiumOS собирается только под это).
* Рабочий D-Bus (системная шина) и рабочий DRM/KMS: `/dev/dri/cardN`, evdev-ввод и udev. X-сервер не нужен.
* Пользователь должен иметь доступ к `/dev/dri/cardN` и `/dev/input/event*` (группы `video`, `render`, `input`) и активную logind-сессию на той же VT.
* `./scripts/doctor.sh` печатает, чего именно не хватает на вашей машине — запускай его первым делом.

**Ubuntu / Debian**

```bash
# сборка
sudo apt install --no-install-recommends \
  golang-go meson ninja-build gawk pkg-config python3 python3-jinja2 gcc make \
  libwayland-dev libwayland-bin wayland-protocols libxkbcommon-dev libdrm-dev \
  libgbm-dev libpixman-1-dev libxcb1-dev libxcb-composite0-dev libxcb-shape0-dev \
  libxcb-xfixes0-dev curl unzip tar perl libc-dev build-essential

# рантайм (libXcomposite — самая частая пропущенная библиотека у Chrome)
sudo apt install --no-install-recommends \
  xwayland x11-xserver-utils dbus \
  libnss3 libnspr4 libcups2 libdbus-1-3 libexpat1 libxkbcommon0 libxcomposite1 \
  libasound2t64 pulseaudio-utils librsvg2-bin \
  network-manager gnome-keyring polkit-gnome xdg-desktop-portal-gtk
```

На Debian 12 пакет называется `libcups2`, на Ubuntu 24.04 — `libcups2t64`; `libasound2`/`libasound2t64` аналогично.

**Arch**

```bash
sudo pacman -S --needed go meson ninja gawk pkgconf python python-jinja gcc make \
  wayland libxkbcommon libdrm libgbm pixman libxcb libxcomposite \
  xorg-xwayland xorg-xrdb xorg-xkbdata dbus \
  nss nspr cups alsa-lib libpulse pipewire-pulse librsvg \
  networkmanager gnome-keyring polkit-gnome xdg-desktop-portal-gtk unzip
```

Зачем что-то из рантайма:

* `xwayland` — без него Linux-приложения внутри Ash не рисуются;
* `x11-xserver-utils` — только `xrdb` (цвета для xterm внутри `:10`); `xrandr`, `xhost`, `xauth` больше не нужны;
* `xorg-xkbdata` (на Debian это `xkb-data`) — данные раскладок для RU/EN;
* `pulseaudio-utils` — `pactl`, через который `cras-bridge` крутит громкость;
* `librsvg2-bin` — `rsvg-convert` для SVG-иконок в лаунчере;
* `network-manager` — `shill-bridge` без NM просто пишет в лог «NM not available»;
* `gnome-keyring`, `polkit-gnome`, `xdg-desktop-portal-gtk` — «сантехника» Linux-приложений (выбор файлов, polkit-промпты, ключница).

## Структура репозитория

```
chromeos-bin/REVISION         пин ревизии снапшота ChromiumOS (1670871)
chromeos-bin/fetch.sh         скачивание + проверка контрольных сумм
chromeos-bin/chrome/          распакованный снапшот (после make fetch, ~870 МБ)

scripts/common.sh             общие хелперы ВСЕХ скриптов: ASH_ROOT, die/log/note (с префиксом вызывающего), need/have
scripts/build-chrome.sh       патчинг бинарника → dist/chrome/
scripts/build-sommelier.sh    сборка sommelier → dist/sommelier/
scripts/build-bridges.sh      сборка Go-бриджей → dist/bin/
scripts/minigbm_shim.c        C-шим libminigbm.so (обёртка над системным libgbm)
scripts/setup-system.sh       разовая установка под root
scripts/doctor.sh             проверка зависимостей + преflight сессии
scripts/verify.sh             проверка артефактов сборки
scripts/smoke-test.sh         проверка бриджей на живой системной шине

session/start-session.sh      точка входа: бриджи + сессия
session/chromeos-linux-session основной сессионный цикл
session/terminal-inject.pl    инжект UI терминала по CDP
session/chromeos-ash-open-url ручной helper: открывает URL в запущенном Ash через CDP (обработчиком по умолчанию НЕ регистрируется)
session/dbus-policies/        D-Bus политика (исходник для setup-system.sh)
session/tmpfiles.d/           шаблон tmpfiles (исходник для setup-system.sh)
session/stubs/shell-stub.sh   заглушки vsh / crosh

dbus-bridges/cmd/*/           исходники бриджей (Go)
terminal/terminal-ui.js       UI терминала, который инжектируется в SWA

Makefile                      цели сборки
dist/                         всё собранное (~900 МБ, не коммитится)
.cache/                       временные файлы сборки (не коммитится)
```

## Быстрый старт

```bash
make                        # скачать снапшот, пропатчить, собрать sommelier и бриджи
sudo ./scripts/setup-system.sh --user "$USER"
./session/start-session.sh
```

Это всё: **интеграции с дисплейным менеджером нет и не будет, systemd-юнитов нет**. `start-session.sh` сам поднимает бриджи (каждый под watchdog-ом перезапуска), затем сессию, и по своему выходу всё убивает.

Запускать `./session/start-session.sh` нужно **с чистой VT**, где никто не держит DRM master: не из X-сеанса и не из другого Wayland-композитора (niri, sway, GNOME, KDE). Скрипт сам проверит карту, ввод, udev и отсутствие известных композиторов; если что-то не так — откажется стартовать с понятным сообщением. X-сервер и `startx` в этой ветке не используются вообще.

Пересборка с нуля: `make clean && make`. Время сборки — около 5 минут, из них 4 — патчинг 603-мегабайтного бинарника.

### Цели Makefile

| Цель | Что делает |
|---|---|
| `make` (= `all`) | `chrome` + `sommelier` + `bridges` |
| `make fetch` | скачать и проверить снапшот ChromiumOS |
| `make chrome` | патчинг бинарника → `dist/chrome/` |
| `make sommelier` | сборка sommelier → `dist/sommelier/` |
| `make bridges` | сборка Go-бриджей → `dist/bin/` |
| `make vendor` | залить Go-зависимости в `dbus-bridges/vendor/` для оффлайн-сборки |
| `make verify` | проверить артефакты: библиотеки, интерпретатор, патчи, парсинг D-Bus-политики |
| `make test` | прогнать бриджи на реальной системной шине (нужна политика из `setup-system.sh`) |
| `make clean` | удалить `dist/` и кэш сборки sommelier/go |
| `make distclean` | + удалить скачанный снапшот |

### Чек-лист для прогона в VM

1. Проверить `./scripts/doctor.sh` — все пункты `ok` (включая `== DRM preflight ==` и `== session preflight ==`).
2. `make` — завершается строкой `bridges -> .../dist/bin/`.
3. `sudo ./scripts/setup-system.sh --user "$USER"` — печатает `setup-system: done`.
4. `./scripts/smoke-test.sh` — 11 passed / 0 failed (можно и без DRM, это только D-Bus).
5. Переключиться на свободную VT (`chvt 2`), убедиться, что `fuser /dev/dri/card*` пуст и `pgrep -x niri` пуст, затем `./session/start-session.sh` — появляется рабочий стол Ash прямо на KMS.

## Что делает `setup-system.sh` (root, идемпотентен)

Один шаг требует root: D-Bus-политика, системные каталоги и «личность» ОС живут в `/etc`. Скрипт безопасно перезапускается и знает, как всё откатить.

| Шаг | Что появляется |
|---|---|
| D-Bus-политика | `/etc/dbus-1/system.d/chromeos-bridges.conf` — копия `session/dbus-policies/chromeos-bridges.conf` с подставленным пользователем; после изменения шина перезапускается |
| Системные каталоги | `/etc/tmpfiles.d/chromeos-linux.conf` + `systemd-tmpfiles --create`: `/var/lib/ash-profile`, `/run/mojo`, `/home/chronos/user`, заглушки termina-DLC и VM-диска, `/var/log/chrome`, `/var/lib/metrics/...`, а также заглушка `/dev/kvm` — **только если KVM на хосте нет** (без неё Chrome считает, что виртуализации нет, и молча не открывает Linux-приложения; при наличии `/sys/class/misc/kvm` строка из конфига выбрасывается, а уже установленная заглушка снимается — она мешала бы udev создать настоящий device-node) |
| Личность ОС | в `/etc/lsb-release` дописываются `DEVICETYPE=CHROMEBOOK` и `CHROMEOS_RELEASE_NAME=Chrome OS` (исходный файл сохраняется в `/etc/lsb-release.chromeos-linux.bak`) |
| Заглушки шелла | симлинки `vsh` и `crosh` → `session/stubs/shell-stub.sh` **и в `/usr/local/bin`, и в `/usr/bin`** (Ash терминала зовёт их по абсолютному пути `/usr/bin/vsh`, `PATH` не ищет — см. преflight в `doctor.sh`) |

Опции:

* `--user NAME` — под каким пользователем крутится Ash (по умолчанию `$SUDO_USER`);
* `--undo` — убрать политику, tmpfiles и заглушки, восстановить `lsb-release` и заменённые `vsh`/`crosh`;
* `--no-mojo` — не прописывать `CHROMEOS_RELEASE_NAME` (см. [раздел про режим ChromeOS](#режим-chromeos-lsb-release-и-mojo));
* `--force` — заменить существующие заглушки `vsh`/`crosh` (в `/usr/local/bin` и `/usr/bin`; старые уходят в `.bak`).

> **Группа `users`.** Скрипт делает `chown "$USER:users"` профиля, а все каталоги из tmpfiles создаются с группой `users`. На Debian/Ubuntu она есть по умолчанию (`USERS_GROUP=users`), на части minimal-установок — нет. Если её не окажется, `setup-system` упадёт на `chown`/`systemd-tmpfiles` с `group 'users' does not exist`: создай её (`sudo groupadd users`) либо заранее поменяй группу во всех строках `session/tmpfiles.d/chromeos-linux.conf` (и в `chown` внутри `scripts/setup-system.sh`).

Почему без systemd не обойтись «вручную»: политика D-Bus подхватывается только при старте демона. На systemd-less системе (или в контейнере) скрипт предупредит, что dbus надо перезапустить или перезагрузиться.

Что **не** делает `setup-system.sh` и не требует: он не ставит юнитов, не трогает `PATH`, не регистрирует сессию у дисплейного менеджера. В `/usr/bin` он пишет **только** две заглушки `vsh`/`crosh` (туда же их ждёт абсолютный путь из бинарника) и ничего больше.

## Сессия: что происходит при запуске

`./session/start-session.sh`:

1. Проверяет системную шину и что профиль (`/var/lib/ash-profile`) записываем — иначе вежливо просит прогнать `setup-system.sh`.
2. Прогоняет DRM-preflight: карта `/dev/dri/cardN` (выбирается автоматически как первая с подключённым коннектором, rw; `ASH_DRM_CARD` переопределяет), читаемые `/dev/input/event*`, `/run/udev/control`, отсутствие известных композиторов, ChromeOS-режим `/etc/lsb-release`; при провале отказывается стартовать.
3. Поднимает бриджи: `shill`, `cras`, `session`, `crostini`, `rmad` (с `PULSE_SERVER=unix:$XDG_RUNTIME_DIR/pulse/native`), `power` и `mojo-stub`. Каждый — под watchdog-ом: падение → перезапуск через 2 с, пять падений подряд → пауза 30 с (типичная причина — политика D-Bus не применена).
4. Запускает `session/chromeos-linux-session` и ждёт его; при выходе убивает бриджи и пробрасывает код возврата.

`chromeos-linux-session` (цикл):

1. Готовит профиль: `mkdir`, `CHROMEOS_SESSION_LOG_DIR`, метки «OOBE пройдено» (`.oobe_completed`, `First Run`, `Local State`), чистка токенов входа, JSON-правки `Preferences` (включён Crostini, `exit_type=Normal`).
2. Прогоняет `register-apps` — пишет Linux-приложения в лаунчер Ash.
3. Запускает в фоне `terminal-inject.pl`: ждёт CDP на `localhost:9222` (до 60 с), открывает `chrome-untrusted://terminal/`, кладёт `terminal/terminal-ui.js` в `localStorage.t` и перезагружает страницу. Это срабатывает потому, что в бинарнике `terminalPrivate.openVmshellProcess(...)` заменён на `eval(localStorage.t||"")`.
4. Поднимает в фоне sommelier + Xwayland на `:10` (ждёт появления `wayland-0` и ответа CDP, выставляет чёрно-белые цвета xterm через `xrdb`).
5. Запускает Chrome с `--ozone-platform=drm --use-angle=gles-egl` (`--enable-wayland-server`, `--no-sandbox`, `--enable-features=Crostini`, отключённые sync/гаия/аккаунты, `--remote-debugging-port=9222`, `--user-data-dir=/var/lib/ash-profile`, `--login-user`/`--login-profile`, GPU-блок `--ignore-gpu-blocklist` + `--disable-gpu-sandbox` + `--enable-logging=stderr` — последний вместе с no-op `RedirectChromeLogging` и есть то, что кладёт ERROR'ы в `ash.log`). `--use-angle=gles-egl` обязателен: на этом снапшоте ANGLE по умолчанию выбирает OpenGL/GLX-бэкенд, который на VT без X-сервера падает с `Could not open the default X display`, после чего Viz убивает браузер (`Software compositing fallback is unavailable`). С `gles-egl` ANGLE работает поверх нативного Mesa EGL/GLES и GBM. `--ash-host-window-bounds` намеренно не передаётся: без него `DisplayManager::InitFromCommandLine()` возвращает false, и Ash выполняет настоящую настройку KMS.
6. Когда Chrome вышел — убивает sommelier/Xwayland, ждёт остаточных процессов `chrome` и начинает заново.

### Дисплейный режим

Дисплей один и он же — DRM/KMS. Никаких «режимов» и выбора `DISPLAY` нет:

| Что нужно | Требование |
|---|---|
| Карта | `/dev/dri/cardN` — первая карта с подключённым коннектором (автоопределение, `ASH_DRM_CARD` переопределяет), rw у пользователя |
| Ввод | читаемые `/dev/input/event*` и работающий `systemd-udevd` |
| DRM master | никто другой не держит карту: не запущены niri/Xorg/sway/Hyprland/weston/GNOME/KDE |
| ChromeOS-режим | `/etc/lsb-release` с `CHROMEOS_RELEASE_NAME=` — иначе `IsRunningAsSystemCompositor()` = false и KMS не настраивается |
| VT | сессия сама уходит в `setsid`; переключение VT/logind-интеграции нет (см. «Ограничения») |

Если на машине уже есть `wayland-0` (например, вы внутри другого Ash) — старые сокеты удаляются, `--enable-wayland-server` Ash займёт этот слот.

Перед подъёмом бриджей `start-session.sh` отцепляет всё дерево сессии от управляющего терминала (`exec setsid --wait`), чтобы чтение `/dev/tty` кем-либо из процессов сессии не могло остановить группой всю оболочку — подробности и разбор инцидента во врезке в «Типовых проблемах».

## Переменные окружения

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `ASH_PROFILE_DIR` | `/var/lib/ash-profile` | профиль и все логи; можно указать каталог, которым вы владеете, если не хотите давать права через `setup-system.sh` |
| `ASH_LOGIN_USER` | `linux@local` | аккаунт, под которым входит Ash (`--login-user`) |
| `ASH_LOGIN_PROFILE` | `test-user` | подкаталог профиля (`--login-profile`) |
| `ASH_DIRECT_LOGIN` | `1` | `0` — не передавать флаги входа вообще |
| `ASH_LOGIN_MANAGER` | `0` | `1` — вместо прямого входа `--login-manager --oobe-skip-to-login` |
| `ASH_DRM_CARD` | автоопределение | DRM-карта, которой владеет Ash (`/dev/dri/cardN` с подключённым коннектором); явное значение отключает автоопределение. Проверяется preflight'ом и используется в `display_alive()` |
| `ASH_MOJO` | `1` | `0` — не запускать `mojo-stub` в `start-session.sh` |
| `ASH_SMOKE_TIMEOUT` | `6` | сколько секунд `make test` ждёт появления имени на шине |
| `ASH_TOUCHPAD_SHIM` | `1` | `0` — не прелоадить `libash-touchpad.so` (тачпад перестанет двигать курсор) |
| `ASH_TOUCHPAD_DEBUG` | `0` | `1` — писать обнаружение тачпада, тапы и клики в `/tmp/ash-touchpad.log`; `2` — ещё и движение (каждый 25-й кадр) |
| `ASH_TERMINAL_UI` | — | путь к `terminal-ui.js` для `terminal-inject.pl` (по умолчанию аргумент из сессии) |
| `ASH_LOG_DIR` | `${TMPDIR:-/tmp}/chromeos-linux` | куда пишут заглушки `vsh`/`crosh` |

## Патчи бинарника (applied at build time)

Снапшот патчится в `scripts/build-chrome.sh`. Каждый патч сверяет ожидаемые байты и **падает с ошибкой**, если бинарник не совпал — молчаливо «починить» чужой бинарник нельзя.

Важно: патчи, нужные только для старого X11-хоста (`DisplayConfigurator::Init`, `RunPendingConfiguration`, `HasInternalDisplay`, X11-движок раскладки и фикс `GetEventPropertiesFromXEvent`), в этой ветке **не применяются**. На DRM нативный display delegate обязан остаться на месте, а реальная настройка KMS — выполняться; `scripts/verify.sh` проверяет, что оригинальные байты на месте.

| Патч | Что делает | Без него |
|---|---|---|
| Терминальный стаб | `chrome.terminalPrivate.openVmshellProcess(...)` → `eval(localStorage.t||"")` | Terminal SWA пытается стартовать VM-шелл и падает |
| Расслабление CSP | `'wasm-unsafe-eval'` → `'unsafe-eval'` (10 мест) | инжектированный UI терминала не выполняется |
| `RedirectChromeLogging` | `ret` (no-op) | Chrome уводит логи в ChromeOS-путь |
| `OnDisconnect` | `ret` (no-op) | крэш при таймауте mojo-канала |
| `IsSystemBlurEnabled` | всегда `true` | blur панели/шторки гейтится не на GPU, а на ОЗУ: `chromeos::features::IsSystemBlurEnabled()` — это буквально `AmountOfTotalPhysicalMemory() > 4GiB` из `/proc/meminfo`, без FeatureList и без флага. На хостах ≤4 ГБ (гости VirtualBox, типовые Haswell-ноутбуки) панель и шторка рисуются непрозрачными, хотя композитор blur умеет рисовать на чём угодно (`viz::SoftwareRenderer::GetBackdropFilterShader` есть). С патчем — blur при любом объёме RAM; на малорамных хостах это стоит части FPS в анимациях |
| `IsSharedImageFormatSupported` | всегда `true` | exo отдаёт `BGRX_8888`, а проверка пропускает только `BGRA_8888` → `CanImportNativePixmap` говорит «нет» и `OzoneImageBackingFactory` не регистрируется: `Could not find SharedImageBackingFactory` |
| `GetNativePixmapSupportType` | всегда `kX11Pixmap` (2) | выбирается ветка `kDMABuf`, требующая `EGL_EXT_image_dma_buf_import`, которой у ANGLE здесь нет → импорт не создаётся |
| `NativePixmapEGLX11Binding::Create` | вырезан встроенный чек `format == kBGRA_8888` (NOP на `je`) | тот же чек, но вызываемый уже **внутри** `Create`: отказ приходит как `ProduceSkiaGanesh failed to create GL representation` (в release это только VLOG, в логе тишина) → белые окна |
| `PopulateMappableDrmFormatsForExo` | из набора кандидатов убраны RGB-порядочные форматы: в rodata-таблице `RGBA_8888`→`BGRA_8888`, `RGBX_8888`→`BGRX_8888`, плюс `jne`→`jmp` пропускает условные `RGBA_F16` и `RGBA_1010102` | exo рекламирует в dmabuf-фидбеке `AB24`/`XB24`/`AB30`/`AB4H` — память R,G,B,A, а импорт идёт через X11-визуал depth-32 (память B,G,R,A), где fourcc теряется → **красный уходит в синий** во всех wayland-клиентах, рисующих через dmabuf (helium, Qt). shm-клиенты (GTK, Xwayland) не страдают — их память и так B,G,R,A |
| `libash-touchpad.so` | `LD_PRELOAD`-шим (`scripts/ash_touchpad_shim.c`): разбирает MT-B поток тачпада и отдаёт `REL_X/REL_Y`, тапы и клики, которые штатный evdev-конвертер понимает | тачпад не двигает курсор: в снапшоте `use_evdev_gestures=false`, и `EV_ABS` отбрасывается |
| crashpad-wrapper | всегда добавляет `--database` | падение на старте crashpad-handler'а |

Отдельно от бинарных патчей важен выбор GL-бэкенда. В снапшоте 1670871 ANGLE по умолчанию на Linux поднимает OpenGL/GLX-бэкенд: в X11-ветке это работало, а на DRM/VT без `DISPLAY` `eglInitialize` падает с `ANGLE Display::initialize error 12289: Could not open the default X display`. GPU-процесс завершается, `VizProcessTransportFactory::DisableGpuCompositing()` упирается в `Software compositing fallback is unavailable` и Ash аварийно завершается (signal 6). Поэтому сессия передаёт `--use-angle=gles-egl`: ANGLE идёт через нативный Mesa EGL/GLES, находит GBM-устройство (`EGL_DEFAULT_DISPLAY`) и GPU-процесс стартует с `init_success:1`. На более старом снапшоте (1040000, ветка `old_drm`) этот флаг не нужен — там по умолчанию уже использовался нативный EGL; поэтому «на другой ветке работало».

Чего патч **не** делает: он не трогает интерпретатор и RPATH. Снапшот уже использует `/lib64/ld-linux-x86-64.so.2` и `RUNPATH=$ORIGIN`, поэтому patchelf не нужен вообще — `ldd` на обычном дистрибутиве всё резолвит, а `libminigbm.so` подхватывается из каталога бинарника.

Отдельно от патчей бинарника собирается **шим `libminigbm.so`** (`scripts/minigbm_shim.c`) — Chrome слинкован против ChromeOS-овского minigbm, а на хосте есть только Mesa `libgbm`, и они не сходятся в двух местах: биты usage (у minigbm есть биты, которых нет у Mesa) и коды типа импорта (`GBM_BO_IMPORT_FD_MODIFIER` = `0x5505` у minigbm против `0x5504` у Mesa → `default: return NULL`). Шим кладётся **вместо** оригинала (он остаётся рядом как `libminigbm.so.orig`), резолвит 19 точек входа в `libgbm.so.1` через `dlopen`, транслирует тип импорта, маскирует usage, при неудаче повторяет импорт без `GBM_BO_USE_SCANOUT`, затем падает обратно на `modifier=0`, затем на legacy `FD`-импорт и пишет трассировку в `/tmp/gbm-shim.log`. Без шима GPU-процесс не находит backing'и для `SharedImage` — см. таблицу GPU-патчей выше, они дополняют его, а не заменяют.

Ретрай без `SCANOUT` нужен для amdgpu/GFX8: Chrome в MINIGBM-сборке просит `SCANOUT|TEXTURING` на **каждый** импорт, а Xwayland с `--glamor` отдаёт буфер, выделенный как render target (micro-tiling `STANDARD`, `tiling_info` бит 12). Mesa такой образ создаёт, но `dri2_validate_usage()` отвергает `PIPE_BIND_SCANOUT`, потому что `is_displayable == false`; для композитора это неважно — буфер всё равно сэмплируется как текстура. Без ретрая GPU-процесс зависал в бесконечном цикле `gbm_wrapper::Device::CreateBufferFromHandle` (см. «Сырые места»); настоящий scanout не затрагивается, потому что буферы самого Ash шим создаёт сам и они displayable.

## Режим ChromeOS: lsb-release и mojo

`CHROMEOS_RELEASE_NAME=Chrome OS` в `/etc/lsb-release` переключает Ash с встроенных fallback-клиентов на настоящие D-Bus-клиенты — то есть на наши бриджи. Побочный эффект: включается режим Mojo IPC ChromeOS, которому нужен собеседник `/run/mojo/service_manager.sock`. Именно поэтому:

* `setup-system.sh` по умолчанию пишет оба ключа (`DEVICETYPE=CHROMEBOOK` + `CHROMEOS_RELEASE_NAME=Chrome OS`);
* `start-session.sh` по умолчанию запускает `mojo-stub`, который делает ACCEPT_INVITEE и сливает сообщения (заглушка, но рабочая).

Отключить: `sudo ./scripts/setup-system.sh --no-mojo` (и при желании `ASH_MOJO=0` перед запуском сессии). Тогда Ash вернётся на встроенные fallback-клиенты, а мосты станут почти не нужны.

**В DRM-ветке `--no-mojo` фактически несовместим с рабочим экраном:** без `CHROMEOS_RELEASE_NAME` `IsRunningAsSystemCompositor()` возвращает false, `DisplayConfigurator` не настраивает KMS, и вы получите чёрный экран. Флаг оставлен для отладки, но `setup-system.sh` теперь печатает об этом предупреждение.

Без `DEVICETYPE=CHROMEBOOK` Ash считает машину «обычным Linux» и ведёт себя заметно скучнее.

## Что работает

Рабочий стол поднимается и вполне пригоден как очень странный Linux-шелл:

* Ash стартует в постоянный ChromeOS-подобный десктоп, OOBE пропущен.
* Шельф, лаунчер, шторка быстрых настроек и системный трей открываются.
* Ставятся все 24 System Web App, включая Terminal, Files, Settings и Camera.
* Terminal SWA поднимает настоящий bash через инжектированный UI.
* Chrome переживает перелогин и ре-экзекуции сессии, не вылетая из дисплейного менеджера.
* Работают бриджи shill, CRAS, powerd, session_manager, UserDataAuth, Crostini, rmad и совместимость Mojo service manager.
* NetworkManager отдаёт шилл-бриджу реальное состояние сети.
* Громкость работает через CRAS-бридж (PulseAudio/PipeWire).
* UPower кормит бридж питания состоянием батареи.
* Яркость работает через sysfs.
* Работает Linux-сантехника: выбор файлов, xdg-desktop-portal-gtk, polkit-промпты, gnome-keyring.
* Работает **нативный лок-экран Ash** (`Ctrl+Shift+L`) и разлочка **любым паролем** (см. «Лок-экран и разлочка»).
* Тачпад двигает курсор, работают тап и физический клик (в т.ч. правый клик двумя пальцами). Это делает `LD_PRELOAD`-шим `scripts/ash_touchpad_shim.c`: в снапшоте нет ChromeOS-libgestures, и штатный evdev-конвертер Ash игнорирует `EV_ABS`; шим превращает MT-поток тачпада в понятные ему `REL_X/REL_Y` и кнопки.
* Переключение RU/EN в шторке быстрых настроек меняет раскладку и для **набора текста** (адресная строка, оконный менеджер, экранная клавиатура), а не только для индикатора в трее — на DRM это делает нативный `XkbKeyboardLayoutEngine`.
* Linux-приложения рендерятся через GPU: sommelier запускает Xwayland с `--force-drm-device` и `--enable-linux-dmabuf`, поэтому клиенты получают `zwp_linux_dmabuf_v1`, а путь dmabuf → exo → `OzoneImageBacking` закрыт тремя GPU-патчами бинарника вместе с шимом `libminigbm.so` (см. «Патчи бинарника»). `glxgears` на `:10` держит ~60 FPS, и сессия при этом не подвисает. X11-окна (xterm, alacritty) открываются и больше не загоняют GPU-процесс в цикл импорта — это ретрай без `SCANOUT` в шиме (см. выше). **`--glamor` передаётся**: Xwayland рендерит через GPU (glamor), так что ускоряются и внутренние 2D-операции X-сервера; подробности и исторический нюанс с мерцанием OBS — в «Сырых местах».

## Сырые места

Работает настолько, чтобы быть полезным, но до Chromebook-grade далеко:

| Область | Состояние |
|---|---|
| DRM/VT | Ash сам держит `/dev/dri/cardN`; переключения VT и интеграции с logind нет. Зависший Chrome не отдаёт карту — спасает только SSH/другая TTY и `pkill` |
| Данные сети/аудио/батареи в трее | Реальные данные есть, но очень ограничены |
| Интеграция Linux-приложений в лаунчер | `.desktop`-файлы пишутся в настройки Crostini, но запускаться могут не все (большинство — да) |
| Эмуляция терминала | Базовый VT100 хватает на fastfetch; для работы бери нормальный терминал |
| Аудио-узлы | Громкость работает, но узлы захардкожены (Speaker/Headphone/Mic), реального discovery PipeWire нет |
| Яркость / SUSPEND | `power-bridge` работает от вашего пользователя: на запись в `/sys/class/backlight/*/brightness` нужны права (добавьте себя в группу `video`), suspend зависит от polkit |
| Гостевой профиль | `/home/chronos/user` — обычная директория, а не cryptohome |
| Лок-экран | Настоящий, но **разлочивается любым паролем** (в т.ч. пустым): `session-bridge` отдаёт фиктивный `StartAuthSessionReply` с password-фактором `local-password` и всегда успешный `AuthenticateAuthFactor`. Системная соль — константа из моста. `ListAuthFactors` возвращает пусто, поэтому в логе безвредный warning `lock_contents_view.cc:937` (поле ввода пароля показывается дефолтно) |
| Трей-иконки приложений | StatusNotifierItem не реализован |
| Прокрутка тачпадом и колесом | Курсор, тап и клик тачпада работают, но two-finger scroll и колесо — нет: в снапшоте отсутствует libgestures, а evdev-конвертер Ash отбрасывает `EV_ABS` и `REL_WHEEL`. Шим `libash-touchpad.so` прокрутку сознательно не эмулирует |
| dmabuf от Xwayland на amdgpu/GFX8 | Продюсер (glamor) отдаёт буфер с micro-tiling `STANDARD`, radeonsi считает его не-displayable, и Mesa отвергает импорт с `GBM_BO_USE_SCANOUT` (сам образ при этом создаётся). Лечится ретраем без `SCANOUT` в шиме; полноценного per-modifier импорта на GFX8 нет — `resource_create_with_modifiers` у radeonsi включается только с GFX9 |
| `--glamor` у Xwayland (ускорение самого X-сервера) | **Включён.** Xwayland рендерит через glamor, поэтому ускоряются не только клиентские GL-приложения, но и 2D-операции самого X-сервера (скроллинг, копии больших окон). Исторический нюанс: в X11-ветке флаг был выключен из-за мерцания превью OBS (chrome композитит поверхность с альфой=0: xterm просвечивает и кадры накапливаются ×1→×2→×3), а железный OBS мог показывать пустую картинку. На DRM-ветке флаг включён; если это мерцание вернётся, первым делом убирайте `--glamor` (тогда Xwayland откатится на `-shm`/`XRGB8888`) |

## Лок-экран и разлочка

Реализован **нативный лок-экран Ash** с разлочкой без пароля. Это настоящий lock-screen ChromeOS (`Ctrl+Shift+L`), а не заглушка: шторка, поле ввода пароля, анимации — всё рисует сам Ash.

Как это устроено:

* `session-bridge` обслуживает D-Bus-интерфейс `org.chromium.UserDataAuth` (`CryptohomeMiscInterface`) — тот же сервис/путь/интерфейс, куда Ash ходит за cryptohome.
* **Пустой proto-ответ = успех.** `HasError` проверяет наличие поля `error`; ответ без него Ash читает как «ошибки нет». На этом построены `AuthenticateAuthFactor`, `ExtendAuthSession` и прочие методы.
* `StartAuthSession` отвечает `user_exists=true` и одним password-фактором (type=1, label `local-password`), чтобы `OnStartAuthSession` наполнил `SessionAuthFactors`. Метка должна быть ровно `local-password` (`kCryptohomeLocalPasswordKeyLabel`), иначе `FindAnyPasswordFactor()` → nullptr → «Could not find Password key» (`auth_performer.cc:225`) и разлочка не проходит.
* Фактор кладётся в **field 9** (`tag 0x4a`), а **не** field 5: `StartAuthSessionReply` содержит два повторных `AuthFactorWithStatus`, и итерирует Ash именно field 9 (у field 5 счётчик в offset `0x20`, у field 9 — в `0x58`; цикл `OnStartAuthSession` читает `0x58`).
* `GetSystemSalt` возвращает фиксированную 20-байтную соль (salt = field 1). Ключ хешируется (`SALTED_SHA256_TOP_HALF`), но проверки пароля нет: любой введённый пароль (в т.ч. пустой) разлочивает.
* Страховка от «застревания» на локе: `pkill -f "dist/chrome/chrome"` (делается руками — такого pkill в коде нет) убивает Chrome; он выходит с ненулевым кодом, и цикл перезапуска в `session/chromeos-linux-session` поднимает его заново через пару секунд (`start-session.sh` при этом просто ждёт сессию и бриджи не трогает). Лок-экран никогда не оставит вас запертым.

`ListAuthFactors` возвращает пусто, поэтому при показе лок-экрана в `ash.log` попадает безвредный warning `lock_contents_view.cc:937 Unable to update auth factors…` — поле ввода пароля рисуется дефолтно, на разлочку он не влияет.

## Что не работает

* Выбор, подключение и отключение Wi-Fi из интерфейса ChromeOS. Вообще, почти все настройки.
* SUSPEND.
* Уведомления в центре уведомлений Ash.
* Вход в аккаунт Google, синк, Phone Hub, Nearby Share и прочие сервисы, привязанные к аккаунту.

## Проверка и диагностика

```bash
./scripts/doctor.sh   # зависимости + преflight сессии: чего не хватает прямо сейчас
make verify           # артефакты: библиотеки, интерпретатор, патчи, парсинг D-Bus-политики
make test             # бриджи на реальной системной шине + реальные вызовы методов
```

Блок `== DRM preflight ==` в `doctor.sh` проверяет то, без чего Ash просто не сможет занять экран:

* **`/dev/dri/card*` отсутствует или не rw** → Chrome не сможет стать DRM-мастером и настроить KMS. Лечение: загрузить драйвер, добавить пользователя в группу `video`.
* **нет читаемых `/dev/input/event*`** → не будет клавиатуры и мыши. Лечение: группа `input`.
* **`/run/udev/control` отсутствует** → `DeviceManagerUdev` не перечислит устройства. Лечение: запустить `systemd-udevd`.
* **`/etc/lsb-release` не в ChromeOS-режиме** → `IsRunningAsSystemCompositor()` = false, `DisplayConfigurator` не трогает KMS, экран остаётся чёрным. Лечение: `sudo ./scripts/setup-system.sh`.
* **запущен niri/Xorg/sway/...** → они держат DRM master. Лечение: остановить их и запускать сессию с чистой VT.
* **`fuser /dev/dri/card*` показывает чужие pid** — предупреждение: возможно, карту уже открыл другой процесс.

Блок `== session preflight ==` в `doctor.sh` ловит «тихие» поломки, которые иначе выглядят как «всё собралось, но почему-то не работает»:

* **`/dev/kvm` отсутствует** → Chrome при старте сессии видит, что виртуализации нет, и **молча** отказывается открывать любые Linux-приложения (в UI нет ошибки — просто не открывается). Заглушки-файлы создаёт `setup-system.sh` (tmpfiles), пересоздаются при каждой перезагрузке — но **только на хостах без KVM**; если KVM есть, `setup-system.sh` заглушку не ставит (а заодно снимает уже установленную — она перекрывает настоящий device-node, и udev не может его создать), и `doctor.sh` это отдельно проверяет.
* **`/usr/bin/vsh` / `/usr/bin/crosh` отсутствуют** → терминал падает с `failed to execvp /usr/bin/vsh`. Ash вызывает их по **абсолютному** пути, `PATH` не ищет, поэтому заглушка обязана лежать именно в `/usr/bin`.
* **D-Bus-политика** не установлена → бриджи не могут занять имена `org.chromium.*`, и шина молча отклоняет всё.
* **systemd-logind** неактивен → suspend/reboot из трея мертвы. Обычно за этим стоит мёртвый polkit: polkitd выходит в момент падения системной шины (теряет `org.freedesktop.PolicyKit1`, а `polkit.service` — static, без `Restart=`), после чего logind зависает, дожидаясь polkit-авторизации. Раньше `setup-system.sh` при каждом изменении политики делал `restart dbus` и ронял polkit вместе с шиной — теперь он применяет политику `reload`-ом (без разрыва соединений) и отдельно поднимает polkit.
* **logind «active», но без D-Bus-имени** → в DRM-режиме Chrome не просит logind о VT (он сам открывает `/dev/dri/cardN`), но активная logind-сессия даёт uaccess-ACL на карту и input-узлы, а через неё же идут suspend/reboot из трея. Если имя `org.freedesktop.login1` пропало (перезапуск шины рвёт соединение, а юнит остаётся «active»), эти вещи ломаются. Лечение: `sudo ./scripts/setup-system.sh` (он сам перезапустит logind) или вручную `sudo systemctl restart systemd-logind`. Проверка: `busctl status org.freedesktop.login1` (должен быть владелец, а не `(activatable)`).

`make test` — самый полезный предварительный прогон: он поднимает каждый бридж, ждёт, пока его имя появится на шине (это возможно только при корректной политике), дёргает `GetVolumeState` и `RetrieveSessionState`, проверяет mojo-сокет и `register-apps`. При провале логи не удаляются, а печатаются.

### Логи

| Файл | Что внутри |
|---|---|
| `/var/lib/ash-profile/ash.log` | stderr Chrome/Ash — первое место, куда смотреть |
| `/var/lib/ash-profile/sommelier.log` | sommelier и Xwayland |
| `/var/lib/ash-profile/*-bridge.log` | по одному на бридж |
| `/var/lib/ash-profile/bridges.log` | записи watchdog-ов о перезапусках |
| `/var/lib/ash-profile/test-user/log/ash` | собственный сессионный лог Chrome |
| `/tmp/gbm-shim.log` | каждый вызов шима `libminigbm.so` (очищается при старте сессии) |
| `/tmp/chromeos-linux/shell-stub.log` | вызовы заглушек `vsh` / `crosh` |

Быстрая диагностика DRM-слоя:

```bash
fuser /dev/dri/card*           # кто держит карту (должно быть пусто до старта)
modetest -M vmwgfx -c          # коннекторы/режимы (libdrm-tests), на других GPU — свой драйвер
cat /sys/class/drm/card*/status
grep -iE 'ozone|drm|gbm|Failed to|Invalid' /var/lib/ash-profile/ash.log
```

Если экран чёрный, а процесс жив — почти всегда либо не ChromeOS-режим `lsb-release`, либо карту уже держит другой композитор, либо `--ash-host-window-bounds` попал в аргументы (тогда KMS не настраивается).

### Типовые проблемы

| Симптом | Причина | Действие |
|---|---|---|
| Бриджи пишут `not allowed to own … due to security policies` | политика не установлена или dbus её отбросил | `sudo ./scripts/setup-system.sh --user "$USER"`, перезапуск dbus/перезагрузка; `make verify` ловит это заранее |
| `DRM mode: no usable /dev/dri/card*` / `not found` / `no read/write access` | нет карты, нет прав или автоопределение не нашло коннектор | загрузи драйвер, `sudo usermod -aG video,render,input $USER`, перелогинься; при необходимости задай `ASH_DRM_CARD` вручную |
| `DRM mode: niri is running and likely holds DRM master` | сессия запущена поверх другого композитора | останови его и запусти с чистой VT |
| Экран чёрный, Chrome жив | не ChromeOS-режим `lsb-release` или передан `--ash-host-window-bounds` | `sudo ./scripts/setup-system.sh`; проверь аргументы в `chromeos-linux-session` |
| `Failed to open primary graphics card` в `ash.log` | нет прав на `/dev/dri/cardN` или карту держит другой процесс | `fuser /dev/dri/card*`, группы `video`/`render` |
| Linux-приложения не рисуются | нет `Xwayland` в `$PATH` | поставь пакет `xwayland` |
| Тачпад не двигает курсор, TrackPoint работает | не собран/не загружен шим, либо `ASH_TOUCHPAD_SHIM=0` | `make chrome` (соберёт `dist/chrome/libash-touchpad.so`); проверь `/tmp/ash-touchpad.log` |
| Не работает прокрутка тачпада и колесо | в снапшоте нет libgestures, `EV_ABS`/`REL_WHEEL` отбрасываются | известное ограничение; шим лечит только указатель, тапы и клики |
| Chrome вылетает сразу | смотри `ash.log`; либо снапшот не тот (только x86_64, только пин из `chromeos-bin/REVISION`) | сверь пины (`./chromeos-bin/fetch.sh --force` перескачает и напечатает sums; `make fetch` аргументов не принимает) |
| `Pactl not found` / громкость не регулируется | нет `pulseaudio-utils` | поставь пакет |
| Яркость не меняется | нет прав на sysfs | `sudo usermod -aG video $USER` и перелогинься |
| `setup-system` падает: `chown … : users` / `group 'users' does not exist` | в системе нет группы `users` | `sudo groupadd users` (или поменяй группу в `session/tmpfiles.d/chromeos-linux.conf`) |
| Linux-приложения не открываются, а `/dev/kvm` есть, но это обычный файл | заглушка перекрыла настоящий device-node KVM (модуль уже загружен) | `sudo ./scripts/setup-system.sh` — снимет заглушку и дёрнет udev; `doctor.sh` показывает это как `placeholder hides the real KVM device` |
| Всё умерло после правки `session/dbus-policies/*.conf` | dbus < 1.15 молча отбрасывает **весь файл** при неизвестном атрибуте | см. врезку ниже |
| Вся сессия зависла в состоянии `T` сразу после запуска GUI-приложения от root (`synaptic` через `pkexec`) | в сессии нет polkit-агента: pkexec спрашивает пароль текстовым агентом на управляющем терминале, а цепочка сессии — фоновая группа tty1, и ядро шлёт SIGTSTP/SIGTTIN во всю группу | см. врезку ниже |

> **Врезка про D-Bus-политику.** Debian/Ubuntu поставляют dbus 1.14, который не знает, например, `receive_sender_prefix`. Ошибка разбора через `<includedir>` — это не предупреждение, а тихое удаление файла из конфигурации, после чего *ни одно* имя `org.chromium.*` занять нельзя. Поэтому: проверяйте правки политики через `make verify` (он реально поднимает `dbus-daemon` на файле) и держите в голове, что поддерживаются только классические атрибуты `own`, `own_prefix`, `send_destination`, `send_destination_prefix`, `send_interface`, `receive_sender`.

> **Врезка про зависание всей сессии (состояние `T`).** Сессия наследует управляющий терминал VT, оставаясь при этом *фоновой* группой этого tty. Читать/писать `/dev/tty` из фоновой группы нельзя: ядро шлёт SIGTTIN/SIGTSTP **всей** группе. Типичный триггер — `pkexec` без запущенного polkit-агента: его внутренний текстовый агент лезет на терминал за паролем, и целиком встаёт всё — Chrome, бриджи, скрипты. Поэтому `session/start-session.sh` делает `exec setsid --wait "$0"`: всё дерево сессии уходит в отдельную сессию **без** управляющего терминала, чтение `/dev/tty` возвращает `ENXIO`, и посторонний читатель роняет только себя. `--wait` тут не косметика: без него, если процесс уже лидер группы, `setsid` форкается, родитель выходит, и вызывающая оболочка теряет сессию. Чего это **не** лечит: без агента `pkexec` теперь быстро откажется с ошибкой вместо запроса пароля — агента запускай сам (`polkit-gnome-authentication-agent-1`, `lxpolkit`, что угодно своё; в скрипты он не добавлен). Восстановление после зависания: `kill -KILL` на pkexec-цепочку (например `pkill -x synaptic-pkexec`), затем `kill -CONT -- -<PGID>`.

> **Врезка про восстановление DRM-сессии.** VT-switching и logind-интеграции у этой ветки нет: Chrome открывает карту сам и не отдаёт её при `Ctrl+Alt+F2`. Поэтому при зависании переключайтесь на другую TTY по SSH или через `chvt` с соседнего терминала и убивайте процессы:
>
> ```bash
> pkill -f 'dist/chrome/chrome'
> pkill -f 'session/chromeos-linux-session'
> pkill -f 'session/start-session.sh'
> chvt 1
> ```
>
> `stop_compositor()` в сессии убивает только `Xwayland :10`, а не любой `Xwayland`, чтобы не задеть чужой хост-композитор.

## Обновление ревизии Chrome

`chromeos-bin/REVISION` задаёт ревизию снапшота, а `chromeos-bin/fetch.sh` — контрольные суммы (size, md5 из метаданных GCS, sha256) для неё.

Чтобы перейти на другой снапшот:

1. измени `chromeos-bin/REVISION`;
2. выполни `./chromeos-bin/fetch.sh --force` — он напечатает новые md5/sha256;
3. впиши их в пины в начале `fetch.sh`;
4. прогони `make` — патчи бинарника зашумят, если новый бинарник структурно отличается (это ожидаемо: смещения ищутся по символам, но проверочные байты должны совпасть).

Архив sommelier пинится отдельно в `scripts/build-sommelier.sh` (тоже sha256, т.к. Nix-хеш того репозитория — это NAR-хеш распакованного дерева и вне Nix непригоден).

## Хакинг

* **Поменять патч** — правь `scripts/build-chrome.sh`; там же хелперы `sym_va`, `verify_and_patch`, `va_to_offset`. Новая проверка байтов обязательна, иначе патч применится к неожиданному месту.
* **Добавить бридж** — положи `dbus-bridges/cmd/<name>-bridge/main.go`, добавь имя в `BRIDGES` в `session/start-session.sh` и блок `<policy>` в `session/dbus-policies/chromeos-bridges.conf`, затем `sudo ./scripts/setup-system.sh --user "$USER"`.
* **Оффлайн-сборка** — `make vendor` кладёт зависимости в `dbus-bridges/vendor/`, после чего `go build` идёт без сети.
* **Свой профиль** — `ASH_PROFILE_DIR=$HOME/.local/share/chromeos-ash ./session/start-session.sh`; учти, что путь `/home/chronos/user`, сокет `/run/mojo` и D-Bus-политика всё равно системные.
* **Отладка терминала** — `ASH_TERMINAL_UI=/путь/к/ui.js` или просто правь `terminal/terminal-ui.js` (он читается при каждой инжекции, то есть после перезапуска сессии).

## Ограничения безопасности

Это игрушка для отладки, а не продукт:

* Chrome запускается с `--no-sandbox` (и `--disable-*-sandbox`).
* D-Bus-политика разрешает **любому локальному пользователю** занять имена `org.chromium.*` — то есть любому юзеру машины доступны методы, которые Ash считает «системными».
* Сессия работает на голом DRM/KMS и не интегрирована с logind/VT: зависший Chrome удерживает карту, пока его не убьют извне.
* CDP-порт `9222` открыт на localhost на всё время работы сессии.

Запускайте это в VM или на машине, которую не жалко.

## Ссылки

* [ChromeOS D-Bus system_api](https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/system_api/dbus/)
* [Исходники Ash-клиентов D-Bus](https://source.chromium.org/chromiumos/chromiumos/codesearch/+/main:src/chromeos/ash/components/dbus/)
* [chromeos-session — референс по сессии](https://github.com/0xbaaaadf8/chromeos-session)
