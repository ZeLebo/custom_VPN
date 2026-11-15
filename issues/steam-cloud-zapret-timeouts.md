# Zapret general-alt4 / IPSet any нарушает скачивание Steam Cloud

Дата: 2026-11-15. Статус: требуется исправление в CustomVPN.

Пользователь подтвердил: после отключения Zapret сохранения скачались. В `cloud_log.txt` зафиксировано успешное скачивание оставшихся файлов Balatro и Nodebuster. Связь сбоя с включённым Zapret подтверждена контрольным действием пользователя; точный дефект движка, стратегии или перехвата ещё не локализован.

## Что требуется исправить

При включённом Zapret Steam Cloud должен скачивать и отправлять игровые сохранения. Сохранить обход блокировок для сервисов, которым он нужен, существующие правила сайтов и VPN. Исправление должно устранять причину в соответствующем слое CustomVPN/Zapret, а не требовать постоянного отключения Zapret или Steam Cloud.

Пользователь поручил исправление отдельному чату Codex из корня этого проекта. Изменения кода и локальные проверки входят в задачу. Перед установкой новой сборки или изменением системных сетевых настроек нужен конкретный план и согласование согласно AGENTS-инструкциям пользователя.

## Подтверждённые наблюдения

1. На других Mac и Windows в той же сети сохранения скачиваются. На проблемном Mac отключение и полное закрытие VPN, а также выключение автопоиска прокси Wi-Fi не исправили синхронизацию.
2. При сбое работали отдельные процессы `zapret-control` и `utunws`. Контроллер установлен как LaunchDaemon `io.github.flowseal.zapretmac`; его жизненный цикл отличается от окна CustomVPN и VPN-туннеля.
3. Активные настройки: `enabled=true`, `strategy=general-alt4`, `ipset=any`. В `/var/run/zapret-macos.conf` есть общий профиль `--filter-tcp=80,443,8443` с `--dpi-desync=fake,multisplit` и `--dpi-desync-fooling=badseq`. Проблемные Cloud-домены не найдены в списках исключений.
4. В установленном `run.sh` PF anchor `com.apple/zapret-macos` перенаправляет исходящий трафик физического интерфейса на `utun50` (`10.77.0.2`), включая TCP 443. Поэтому привязка диагностического запроса к `en0` сама по себе не исключает обработку Zapret. Живые правила PF напрямую не прочитаны: `sudo -n pfctl` потребовал пароль. Перехват установлен по скрипту запуска, runtime-конфигурации и работающему движку.
5. После ручного отключения Zapret пользователем Steam успешно скачал реальные Cloud-файлы, включая ранее проблемные Azure/Aliyun. Диагностирующий чат сам не переключал Zapret, не менял сеть и не запускал игры.

## Доказательства из Steam

Источник: `~/Library/Application Support/Steam/logs/cloud_log.txt`. Время локальное, Asia/Novosibirsk.

До отключения, пример Balatro:

```text
[2026-11-15 00:04:34] [AppID 2379780] Download Timeout for file Balatro/settings.jkr
[2026-11-15 00:04:34] [AppID 2379780] Download Timeout for file Balatro/1/profile.jkr
[2026-11-15 00:05:35] [AppID 2379780] Download Timeout for file Balatro/3/meta.jkr
[2026-11-15 00:05:35] [AppID 2379780] Download complete, result Timeout
[2026-11-15 00:08:15] [AppID 3107330] Download Timeout for file Nodebuster/save.dat
[2026-11-15 00:08:15] [AppID 3107330] Download complete, result Timeout
```

Перед таймаутами Azure клиент писал `HTTP download ... failed to issue.`

После отключения пользователем:

```text
[2026-11-15 10:41:11] [AppID 3107330] Download OK for file Nodebuster/save.dat
[2026-11-15 10:41:11] [AppID 3107330] Download OK for file Nodebuster/options.dat
[2026-11-15 10:41:11] [AppID 3107330] Download complete, result OK
[2026-11-15 10:41:11] [AppID 3107330] Successfully synced to ChangeNumber 8
[2026-11-15 10:41:15] [AppID 2379780] Download OK for file Balatro/settings.jkr
[2026-11-15 10:41:15] [AppID 2379780] Download OK for file Balatro/1/profile.jkr
[2026-11-15 10:41:15] [AppID 2379780] Download OK for file Balatro/2/profile.jkr
[2026-11-15 10:41:15] [AppID 2379780] Download OK for file Balatro/2/save.jkr
[2026-11-15 10:41:15] [AppID 2379780] Download OK for file Balatro/1/meta.jkr
[2026-11-15 10:41:17] [AppID 2379780] Download OK for file Balatro/3/meta.jkr
[2026-11-15 10:41:17] [AppID 2379780] Download complete, result OK
[2026-11-15 10:41:17] [AppID 2379780] Successfully synced to ChangeNumber 31
```

Проблемные хосты: `steamcloudsweden.blob.core.windows.net` и `steamcloud-bkk.oss-ap-southeast-7.aliyuncs.com`. До этого часть файлов успешно скачивалась с `steamcloud-eu-ams.storage.googleapis.com`, `steamcloud-hk.storage.googleapis.com` и `steamcloud-bkk.s3.dualstack.ap-southeast-7.amazonaws.com`.

Контроль без NotProton от 2026-11-14 воспроизвёл те же таймауты в чистом нативном Steam. С 2026-11-15 Steam снова работает с NotProton `highball-native-r31-20261114`; успешный цикл 10:41 прошёл уже в этом состоянии. Разработку NotProton/Highball менять для данной задачи не требуется.

## Текущее состояние и ограничения воспроизведения

После успешного цикла контроллер получил новый запрос `enabled=true`: файл запроса изменён в 10:41:25, статус `running` записан в 10:41:26. Во время подготовки issue процесс `utunws` снова работал с `general-alt4` / `any`. Не считать выключенное состояние постоянным и не переключать службу без проверки текущего состояния и согласования.

Уже скачанные файлы теперь находятся локально. Сообщение «всё синхронизировано» без передачи данных не доказывает исправление: нужен настоящий обмен файлами при включённом Zapret. Не удалять локальные данные или Cloud-кеш ради воспроизведения.

В диагностике запрос без авторизации к объекту Azure сбрасывался при обычном TLS 1.3. С TLS 1.2 сервер возвращал HTTP 409; curl/OpenSSL с TLS 1.3 и кривой P-256 тоже получал 409, а с X25519 соединение сбрасывалось. Это вспомогательный сигнал для анализа TLS/десинхронизации, а не эквивалент скачивания сохранения. После успешного цикла Steam и повторного включения движка такой unsigned-пробник снова дал reset. Агент не выполнил самостоятельную пару unsigned-проб с движком выключенным и включённым.

Публичный пробник без пути к пользовательским данным, использованный 2026-11-15 (IP исторический, перед повтором проверить актуальность):

```sh
cloud_test_url='https://steamcloudsweden.blob.core.windows.net/cloud/steam-cloud-connectivity-check/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.dat'
/usr/bin/curl --http1.1 --noproxy '*' --interface en0 --resolve steamcloudsweden.blob.core.windows.net:443:20.60.253.225 --connect-timeout 4 --max-time 8 -sS -o /dev/null -w 'http=%{http_code}\n' "$cloud_test_url"
/usr/bin/curl --http1.1 --noproxy '*' --interface en0 --resolve steamcloudsweden.blob.core.windows.net:443:20.60.253.225 --tls-max 1.2 --connect-timeout 4 --max-time 8 -sS -o /dev/null -w 'http=%{http_code}\n' "$cloud_test_url"
```

Исторический результат при работающем движке: первая команда `curl: (56) Recv failure: Connection reset by peer`, `http=000`; вторая `http=409`. 409 здесь означает ответ хранилища на неавторизованный запрос, а не успешное скачивание. Не использовать доступность корня хоста, HTTP 403/409 или изменение TLS как единственный критерий регрессии.

## Где искать в проекте

- `README.md`: текущая модель маршрутизации, совместимость с VPN, управление службой и проверочные команды.
- `lib/common/zapret.dart`, `lib/common/zapret_control.dart`, `lib/common/routing.dart`, `lib/common/site_rules.dart`: настройки, применение правил и контроллер.
- `zapret/control/`: подготовка runtime-конфигурации, общие профили и исключения, запуск и остановка движка.
- `zapret/payload/run.sh`, `cleanup.sh`, `strategies/general-alt4.conf.in`: PF-перехват, восстановление состояния и стратегия.
- `zapret/nfq/`: обработка пакетов и TLS в `utunws`.

Проверить, почему общий профиль `any` затрагивает соединения Steam и нецелевой HTTPS, и на каком слое должна быть устранена несовместимость. Сначала локализовать дефект; не фиксировать заранее решение в виде жёстко заданного исключения только для Balatro. Если проблема в политике охвата, использовать существующую модель правил и явно определить ожидаемую обработку обычного HTTPS.

Checkout на момент передачи: корень `custom_VPN`, ветка `main`, много незакоммиченных изменений, включая контроллер, маршрутизацию и тесты. Сохранить их; не сбрасывать, не перезаписывать и не коммитить посторонние изменения. Диагностирующий чат добавляет только этот issue.

## Проверка исправления

1. До исправления получить воспроизведение реального сбоя на подходящем слое; после исправления повторить тот же сценарий. Добавить тест, который ловит выявленную причину. Один лишь dry-run парсера или проверка текста конфига не подтверждает корректность TLS-трафика.
2. Запустить профильные проверки по затронутым слоям. В README указаны `flutter test test/routing_test.dart test/site_rule_dialog_test.dart test/zapret_control_test.dart test/processes_test.dart` и `go test -race ./...` из `zapret/control`.
3. При включённом Zapret подтвердить реальное скачивание свежих Cloud-файлов без `Timeout`. До операций с сейвами сделать свежую резервную копию. Загрузку изменения после штатного выхода и сохранение прогресса при повторном запуске проверить вместе с пользователем, без автоматического запуска игр с ценным прогрессом.
4. Проверить, что сохраняются нужные маршруты YouTube/Discord, правила сайтов и работа VPN, а остановка и повторный запуск Zapret корректно снимают и восстанавливают его перехват.

Нельзя считать исправлением отключение Cloud, `IgnoreCloud`, постоянное отключение Zapret, глобальное понижение TLS или отключение проверки сертификатов. Не выбирать перезапись при конфликте сохранений без решения пользователя. Не удалять userdata, compatdata, префиксы, Cloud-кеши и сейвы. Установку, изменения системной сети и публикацию выполнять только в согласованных границах.

Дополнительная диагностика и пути к резервным копиям: `../../../../games-tools/NotProton-highball/issues/steam-cloud-sync-timeouts.md` и `../../../../games-tools/NotProton-highball/issues/steam-cloud-diagnostic-handoff.md` относительно этого issue.
