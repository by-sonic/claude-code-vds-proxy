<!-- ROSEVPN-BANNER-START -->
<p align="center">
  <a href="https://t.me/rosevpnru_bot">
    <img alt="RoseVPN - быстрый VPN" src="https://img.shields.io/badge/%F0%9F%8C%B9%20RoseVPN-%D0%9F%D0%BE%D0%B4%D0%BA%D0%BB%D1%8E%D1%87%D0%B8%D1%82%D1%8C%D1%81%D1%8F%20%D0%B2%20Telegram-E63946?style=for-the-badge&logo=telegram&logoColor=white&labelColor=1a1a1a" height="40"/>
  </a>
</p>
<p align="center">
  <sub><b>Быстрый VPN с обходом YouTube, Discord, Instagram</b> · Бесплатный пробный период · Подключение за 30 секунд через <a href="https://t.me/rosevpnru_bot">@rosevpnru_bot</a></sub>
</p>

---
<!-- ROSEVPN-BANNER-END -->

<div align="center">

# Claude Code VDS Proxy

### Проверяемая маршрутизация Claude Code через собственный VDS.

Squid CONNECT, постоянный SSH-туннель и fail-closed-настройки macOS.
Без TLS-подмены, публичного прокси-порта и хранения учётных данных.

**[Установка](#быстрый-старт)** · **[Проверка](#проверка)** · **[Ограничения](#ограничения)**

**[English](README.md)** · **Русский**

</div>

---

## Зачем это нужно

Claude Code официально поддерживает `HTTPS_PROXY`, `HTTP_PROXY` и `NO_PROXY`,
но наличие переменной окружения само по себе не доказывает реальный маршрут.
Этот набор создаёт приватный канал и проверяет его с обеих сторон:

- выходной IP должен совпасть с IP VDS;
- TLS Anthropic должен проверяться без собственного сертификата;
- прямой запрос к основным доменам должен завершаться ошибкой;
- в журнале Squid должны появиться ожидаемые HTTPS CONNECT;
- после обновления Claude Code можно повторить аудит бинарника и маршрута.

## Архитектура

```text
Claude Code на Mac
  -> HTTPS_PROXY 127.0.0.1:18080
  -> зашифрованный SSH local forward
  -> Squid 127.0.0.1:3128 на VDS
  -> TLS CONNECT
  -> api.anthropic.com
```

Squid слушает только loopback VDS. Снаружи доступен SSH, а не открытый прокси.
Содержимое HTTPS остаётся зашифрованным между Claude Code и сайтом назначения.

## Требования

- macOS 13 или новее;
- Claude Code либо разрешение установщику поставить официальную native-версию;
- Ubuntu/Debian VDS с `apt` и исходящим HTTPS;
- вход по существующему SSH-ключу как `root` или пользователь с passwordless sudo;
- Python 3 на Mac.

Сначала проверьте вход по ключу:

```bash
ssh -i ~/.ssh/id_ed25519 root@203.0.113.10
```

## Быстрый старт

```bash
git clone https://github.com/by-sonic/claude-code-vds-proxy.git
cd claude-code-vds-proxy

./install.sh \
  --vds 203.0.113.10 \
  --ssh-user root \
  --identity ~/.ssh/id_ed25519 \
  --expect-exit-ip 203.0.113.10 \
  --maintenance weekly
```

`203.0.113.10` является адресом из документации. Укажите адрес своего VDS.
После установки полностью перезапустите Cursor и терминалы.

## Проверка

```bash
claude-vds-proxy-verify
claude-vds-proxy-audit-installed-claude
```

Проверка подтверждает локальный listener, выходной IP VDS, публичную цепочку
TLS, доступность API с заведомо неправильным ключом, блокировку прямого пути,
переменные launchd и CONNECT-записи в журнале Squid. HTTP `401` в тесте с
неправильным ключом ожидаем: он доказывает достижение настоящего API без
расходования токенов.

## Обновления

```bash
claude-vds-proxy-maintain --check
claude-vds-proxy-maintain --update
```

Менеджер определяет native/npm/Homebrew-установку, сохраняет две резервные
копии бинарника, обновляет Claude Code через VDS и повторяет полный аудит.

## Удаление

```bash
./uninstall.sh
```

Удаляются созданные задания launchd, команды, переменные прокси и отмеченные
блоки из `/etc/hosts` и `~/.zprofile`. История аудита сохраняется. Squid на VDS
автоматически не удаляется; команда для его удаления выводится в конце.

## Ограничения

Проект управляет сетевым маршрутом. Он не обеспечивает анонимность, не
гарантирует защиту аккаунта от блокировки и не меняет доступность продукта.
Claude разрешено использовать только из
[поддерживаемых регионов](https://support.claude.com/en/articles/8461763-where-can-i-access-claude)
и в соответствии с условиями Anthropic.

- Это host-based failsafe, а не системный пакетный firewall.
- Программы с собственным DNS/DoH, буквальными IP или без поддержки proxy env
  могут обойти маршрут.
- Proxy env наследуют совместимые дочерние процессы, а не только Claude Code.
- MCP, shell-команды, Git/SSH, WebFetch и внешние инструменты выбирают свои
  адреса и не покрываются конечным списком доменов.
- Браузерный трафик не входит в область этого CLI-набора.

Официальная документация: [proxy configuration](https://code.claude.com/docs/en/corporate-proxy)
и [environment variables](https://code.claude.com/docs/en/env-vars).

## Лицензия

MIT, см. [LICENSE](LICENSE).
