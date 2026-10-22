# CustomVPN

Клиент mihomo для macOS: FlClashX 0.4.2 (окно в menubar), собранный локально, со встроенным [zapret для macOS](https://github.com/Flowseal/zapret-mac-discord-youtube).

- **Вкладка Zapret**: запуск и остановка, доступность YouTube и Discord через zapret (напрямую, мимо VPN), стратегии, IPSet, списки. «Проверить все» прогоняет стратегии по YouTube и Discord мимо VPN и отмечает лучшую. «Обновить стратегии» берёт стратегии, fake-пакеты и списки из релизов Flowseal; скрипты и `utunws` остаются свои.
- **Маршрутизация по умолчанию**: YouTube и Discord идут через fallback-группы `Zapret YouTube` / `Zapret Discord` = `[DIRECT, VPN]`. Если zapret пробивает DPI, трафик идёт напрямую, иначе через VPN, например при выключенном zapret или если провайдер блокирует сервис по IP. После запуска или остановки zapret группы перепроверяются сразу. Включается и выключается виджетом «YouTube и Discord» на главной.
- **Главная**: виджеты «Zapret» (статус, переключатель, стратегия) и «YouTube и Discord» (маршрутизация).
- **Вкладка «Прокси»** объединяет прокси, профили и правила; «Правила» показывают активные правила ядра по порядку, с поиском.
- **Подписки в формате xray JSON** (например, шаблон Remnawave для xray) переводятся в конфиг mihomo: vless (reality, vision, xhttp), vmess, trojan, shadowsocks.
- **zapret совместим с VPN**: pf перехватывает только трафик физического интерфейса, поэтому туннель VPN не задевается, а DIRECT-соединения ядра (работает от root) обрабатываются.

Исходники zapret лежат в [`zapret/`](zapret) (`nfq` — движок, `payload` — скрипты службы и стратегии), данные пользователя общие с ZapretMac: `~/Library/Application Support/ZapretMac`.

## Сборка (Apple Silicon)

Нужны Xcode, Flutter 3.41.7 и Go 1.26: в `PATH` или в `SDK_DIR=<папка с flutter/ и go/>`.

```sh
./build-local.sh
# SDK_DIR=… ./build-local.sh — свои пути к Flutter/Go
# PROXY=http://127.0.0.1:<port> ./build-local.sh — загрузки через запущенный прокси
# → build/macos/Build/Products/Release/CustomVPN.app (ad-hoc подпись, arm64)
```

Приложение называется **CustomVPN** и имеет свой bundle id (`io.github.zelebo.customvpn`), свои настройки и порт `7895`, поэтому может работать одновременно с FlClash/FlClashX. TUN одновременно может держать только один из клиентов.

## Основано на

- [FlClashX](https://github.com/pluralplay/FlClashX), GPL-3.0, см. [LICENSE](LICENSE)
- [zapret](https://github.com/bol-van/zapret) и [zapret-mac-discord-youtube](https://github.com/Flowseal/zapret-mac-discord-youtube), MIT, см. [zapret/LICENSE](zapret/LICENSE)
