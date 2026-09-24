# lima-docker-lean: Docker на macOS почти без затрат в простое

[English](README.md) · **Русский**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Lima 2.2](https://img.shields.io/badge/Lima-2.2-green)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M5%20tested-black)
![Virtualization.framework](https://img.shields.io/badge/vmType-vz-lightgrey)

Минимальный **Docker-хост для Mac на Apple Silicon**, каждая настройка которого подтверждена
замерами. Построен на [Lima](https://github.com/lima-vm/lima) и Apple Virtualization.framework. В
простое он **ничего не пишет** на диск и занимает около **1% одного ядра**. В отличие от обычной
VM в Lima, он позволяет macOS забрать обратно **примерно половину** RAM, которую VM держит после
нагрузки. Это настоящий Docker Engine с `docker.sock`, поэтому `testcontainers`, `docker compose`,
`buildx` и `werf` работают без изменений.

Это не очередная обёртка, а один шаблон Lima и разбор каждой его строки, вместе с сырыми
результатами бенчмарков.

## Результаты

Apple M5, 16 ГБ, macOS 26.6, Lima 2.2.0, гость 4 vCPU / 6 ГиБ. Одиночные прогоны; см.
[ограничения](docs/ru/analysis.md#ограничения).

| | Обычный Alpine в Lima | **Этот шаблон** |
|---|---|---|
| CPU хоста в простое (пустая VM) | 1,31% ядра | **1,00–1,12%** |
| Запись на диск в простое | ~25 КБ/мин ([почему](docs/ru/analysis.md#диск-с-25-кбмин-до-нуля)) | **0 Б** |
| `limactl restart` → готов | ~26 с | **~14 с** |
| RAM хоста, реально занятая после нагрузки Postgres + FoundationDB | ~4,2 ГБ | **~2,1 ГБ** ([как](docs/ru/analysis.md#6-память-vz-её-не-отдаёт-и-что-с-этим-делать)) |
| pgbench (8 клиентов) / запись в FoundationDB | ~15 тыс. tps / ~246 тыс. ключей/с | так же |

## Быстрый старт

```sh
brew install lima docker            # Lima >= 2.2 и docker CLI (+ плагины compose/buildx)
git clone https://github.com/heaprip/lima-docker-lean && cd lima-docker-lean

limactl start --name=dev ./templates/minimal-docker.yaml
limactl restart dev                 # один раз, чтобы загрузиться с init_on_free=1

docker context create lima-dev --docker "host=unix://$HOME/.lima/dev/sock/docker.sock"
docker context use lima-dev
docker run --rm -p 8080:80 nginx:alpine   # опубликованные порты появляются на localhost
```

Для `testcontainers` укажите в `DOCKER_HOST` тот же сокет (или используйте контекст). Когда не
работаете, `limactl stop dev` сводит затраты к нулю.

## Что делает шаблон

Каждый пункт объяснён и замерен в [анализе](docs/ru/analysis.md):

- **`/var/log` в tmpfs + `commit=60`.** Guest agent Lima каждые 10 с пишет в лог строку
  `SyncTime`, у которой дрейф никогда не сходится, а журнал ext4 раздувает это до ~25 КБ/мин.
- **Параметр ядра `init_on_free=1` + сброс page cache только в простое.** VZ никогда не
  возвращает память гостя, но обнулённые страницы компрессор macOS сжимает почти в ноль.
- **Нет фантомного getty на `ttyAMA0`.** Cloud-образ бесконечно перезапускает getty на
  устройстве, которого в VZ нет. Это была самая большая одиночная утечка CPU.
- **`GRUB_TIMEOUT=0`**, **syslogd в кольцевом буфере на 64 КБ** (просто выключить его нельзя),
  `chronyd` и `cloud-init-hotplugd` выключены.
- **Лимиты Docker:** ограниченные логи контейнеров, GC для BuildKit, `fstrim` при загрузке (диск —
  sparse-файл).
- **Оставлено специально:** `acpid`, без него `limactl stop` превращается в hard kill.

## Коротко о выводах

- **Apple `container machine`** (1.3 / 1.4.1) как Docker-хост пока не годится. Нет публикации
  портов и сокетов, IP новый при каждом старте, а `$HOME` по умолчанию смонтирован на запись.
- **LinuxKit / самодельная microVM:** готового образа для Lima нет, да и выигрывать почти нечего.
  `dockerd`, `containerd` и guest agent занимают почти всю RAM гостя в простое, а службы ОС, которые
  обычно вырезают, вместе весят ~5 МБ.
- **Немутабельный ISO (alpine-lima) или cloud-образ:** после правок они одинаково тихие и
  быстрые, но только в cloud-образе можно менять командную строку ядра, а это нужно для
  `init_on_free`. ISO-вариант лежит в [`templates/minimal-docker-iso.yaml`](templates/minimal-docker-iso.yaml).
- **OrbStack** — единственная альтернатива, которая сама возвращает RAM в macOS. Код закрытый,
  для коммерческого использования он платный, и здесь его не замеряли.
- **FoundationDB никогда не простаивает.** Один `fdbserver` держит VM на ~3–4% ядра, так что
  останавливайте его, когда он не нужен.

## Структура репозитория

```
templates/   minimal-docker.yaml (рекомендуемый), minimal-docker-iso.yaml (немутабельная альтернатива)
docs/en/     analysis.md: полный разбор с методикой и ограничениями (англ.)
docs/ru/     analysis.md: то же по-русски
bench/       idle.sh, disk-writes.sh, wakeups.sh, load.sh, memtest.sh, fdbbench.py
results/     сырые выводы всех прогонов, упомянутых в документации
```

## Как воспроизвести

```sh
./bench/idle.sh dev 120 60      # пустой простой: CPU хоста, I/O диска гостя, память
./bench/load.sh dev             # Postgres + FoundationDB: простой с контейнерами, нагрузка, простой после
./bench/memtest.sh dev          # реальная цена RAM на хосте после нагрузки (останавливает VM!)
```

Комментарии в шаблонах и скриптах — на английском.

## Лицензия

[MIT](LICENSE). Замеры и текст: [@heaprip](https://github.com/heaprip), с помощью Claude.
