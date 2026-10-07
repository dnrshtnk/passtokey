# PassToKey 🔐

[![Ubuntu 24.04+](https://img.shields.io/badge/Ubuntu-24.04%2B-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Скрипт автоматизации для переключения SSH-аутентификации с пароля на ключ на Ubuntu. Он устанавливает публичный ключ, требует проверить отдельный вход по ключу до отключения пароля, учитывает эффективные SSH-порты UFW и восстанавливает изменённые конфигурационные файлы при ошибке.

---

## ⚡ Быстрый запуск / Quick Start

### Одной командой через curl:
```bash
curl -sSL https://raw.githubusercontent.com/dnrshtnk/passtokey/main/setup.sh | sudo bash
```

### Или через wget:
```bash
wget -qO- https://raw.githubusercontent.com/dnrshtnk/passtokey/main/setup.sh | sudo bash
```

### Или через клонирование репозитория:
```bash
git clone https://github.com/dnrshtnk/passtokey.git
cd passtokey
chmod +x setup.sh
sudo ./setup.sh
```

---

## ✨ Что делает скрипт?

1. **Проверка прав и пользователя**:
   - Требует прав `root` / `sudo`.
   - Автоматически определяет целевого пользователя (текущий пользователь `SUDO_USER` или первый пользователь с UID >= 1000) либо позволяет ввести вручную.

2. **Настройка SSH-ключей**:
   - **Вариант 1 (Рекомендуется)**: Вставка вашего существующего публичного ключа (с валидацией формата через `ssh-keygen -l`).
   - Генерируйте приватный ключ на клиентском компьютере и передавайте скрипту только публичный ключ.
   - Можно использовать уже имеющиеся ключи в `~/.ssh/authorized_keys`.
   - Перед отключением пароля скрипт останавливается и просит подтвердить успешный вход по ключу из отдельной сессии.

3. **Копирование ключа на другие серверы (Public Key Export)**:
   - Скрипт показывает установленную публичную строку, чтобы её можно было добавить на другие серверы.

4. **Корректные права доступа**:
   - `~/.ssh` — права `700`, владелец `user:group`.
   - `~/.ssh/authorized_keys` — права `600`, владелец `user:group`.

5. **Отключение входа по паролю и интерактивного входа**:
   - `PasswordAuthentication no`
   - `KbdInteractiveAuthentication no` (отключает клавиатурно-интерактивный вход / PAM prompts, актуально для современных версий Ubuntu).
   - `ChallengeResponseAuthentication no` (для совместимости со старыми версиями).
   - `PubkeyAuthentication yes`
   - `UsePAM yes` (PAM остается активным для сессий, переменных окружения и MOTD, но парольная аутентификация заблокирована).

6. **Проверка фаервола UFW (Active / Inactive)**:
   - Проверяет статус утилиты `ufw`:
     - Если UFW **Active**: проверяет эффективные порты из `sshd -T`; при необходимости предлагает разрешить каждый порт по TCP.
     - Если UFW **Inactive**: сообщает об этом и предлагает включить UFW после добавления правил для эффективных SSH-портов.

7. **Обработка переопределений Cloud-Init (`50-cloud-init.conf`)**:
   - В облачных образах (Hetzner, AWS, DigitalOcean, GCP, Selectel, Timeweb и др.) файл `/etc/ssh/sshd_config.d/50-cloud-init.conf` часто принудительно включает `PasswordAuthentication yes`.
   - Так как OpenSSH использует **первое** совпадение директивы при парсинге, скрипт:
     - Создает конфигурационный drop-in с приоритетным префиксом: `/etc/ssh/sshd_config.d/01-disable-password-auth.conf`.
     - Делает резервную копию `50-cloud-init.conf` (с таймстемпом) и отключает в нем `PasswordAuthentication` и `KbdInteractiveAuthentication`.
     - Создает `/etc/cloud/cloud.cfg.d/99-disable-passwords.cfg` со значением `ssh_pwauth: false`, предотвращая сброс настроек при перезагрузке инстанса или обновлении cloud-init.

8. **Полная поддержка Ubuntu 24.04+ (Socket Activation)**:
   - В Ubuntu 24.04 по умолчанию SSH управляется через `ssh.socket`, а не только `ssh.service`. Скрипт корректно определяет и перезагружает `ssh.socket` и `ssh.service`.

9. **Тестирование конфигурации и авто-откат**:
   - Перед перезапуском демона выполняется тест синтаксиса `sshd -t`.
   - При ошибке после начала изменений скрипт пытается восстановить исходные `authorized_keys` и конфигурационные файлы из резервных копий.

---

## 🛠 Аргументы командной строки (для автоматизации / CI)

Скрипт можно запускать без интерактива:

```bash
# Указать конкретного пользователя и вставить публичный ключ
sudo bash setup.sh --user ubuntu --key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... user@laptop"

# Неинтерактивный режим только для ключа, который уже проверили отдельным входом
sudo bash setup.sh --user ubuntu --key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... user@laptop" --key-verified --non-interactive
```

Для первого подключения используй интерактивный режим: он добавит ключ, дождётся проверки входа в новой сессии и только затем продолжит.

| Флаг | Описание |
|---|---|
| `-u, --user <USER>` | Имя пользователя (по умолчанию: `SUDO_USER` или UID >= 1000) |
| `-k, --key "<KEY>"` | Строка с публичным SSH-ключом OpenSSH |
| `--key-verified` | Подтверждение, что вход этим ключом уже проверен в отдельной сессии |
| `-y, --non-interactive` | Запуск без запросов; требует `--user`, `--key` и `--key-verified` |
| `-h, --help` | Справка по использованию |

---

## ⚠️ Критически важное правило безопасности

Перед отключением парольного входа скрипт попросит:

1. Открыть новое окно терминала на локальном компьютере.
2. Проверить вход только по ключу, отключив парольные методы клиента:
   ```bash
   ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -i <private-key> <user>@<server-ip>
   ```
3. Подтвердить успешный вход в запущенном скрипте.

После завершения работы скрипта:
1. **НЕ ЗАКРЫВАЙТЕ** текущую сессию терминала до дополнительной проверки.
2. Проверьте подключение по ключу:
   ```bash
   ssh -i ~/.ssh/id_ed25519 <user>@<server-ip>
   ```
3. Убедитесь, что:
   - Вход по ключу проходит успешно.
   - Сервер **не запрашивает пароль**.
4. Только после успешной проверки закрывайте исходную сессию.

---

## 📂 Структура создаваемых файлов

```
/etc/ssh/
├── sshd_config                           <- проверен Include и закомментированы конфликты
├── sshd_config.bak.YYYYMMDD_HHMMSS       <- резервная копия оригинального конфига
└── sshd_config.d/
    ├── 01-disable-password-auth.conf     <- drop-in конфиг с жестким отключением паролей
    ├── 50-cloud-init.conf                <- пропатчен (пароли отключены)
    └── 50-cloud-init.conf.bak.YYYYMMDD   <- резервная копия cloud-init

/etc/cloud/cloud.cfg.d/
└── 99-disable-passwords.cfg              <- ssh_pwauth: false (защита от сброса cloud-init)

/home/<user>/.ssh/
├── authorized_keys                       <- права 600
└── .ssh/                                 <- права 700
```

---

## 📄 Лицензия

Распространяется под лицензией [MIT](LICENSE).
