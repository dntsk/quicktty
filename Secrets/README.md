# Sparkle signing-key backup

`sparkle-ed25519.key.enc` — encrypted backup private Sparkle Ed25519 key. Его можно хранить в Git, но только в этом зашифрованном виде.

- Keychain account: `ed25519`.
- Encryption: AES-256-CBC, PBKDF2 with SHA-256, 600000 iterations, random salt.
- Пароль не хранится в Git, `.env`, shell history, CI variables или документации. Сохраните его в password manager отдельно от этого репозитория.
- Никогда не заменяйте этот файл новым ключом: уже опубликованные QuickTTY builds доверяют только текущему public key.

## Restore on a new release Mac

1. Получите официальный Sparkle `generate_keys` той же версии, что vendored framework. Для текущего Sparkle 2.9.4 download `Sparkle-2.9.4.tar.xz` имеет SHA-256 `ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9`; извлеките только `./bin/generate_keys` во временный каталог.
2. Убедитесь, что в login Keychain нового Mac нет другого private key с account `ed25519`. Не удаляйте существующий key без отдельного решения.
3. Decrypt backup во временный файл. `openssl` запросит пароль интерактивно; не передавайте его аргументом команды:

   ```sh
   temp_key=$(mktemp /tmp/quicktty-sparkle-key.XXXXXX)
   trap 'rm -f "$temp_key"' EXIT HUP INT TERM
   openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
     -in Secrets/sparkle-ed25519.key.enc \
     -out "$temp_key"
   /path/to/generate_keys --account ed25519 -f "$temp_key"
   /path/to/generate_keys --account ed25519 -p
   ```

4. Последняя команда должна вывести public key `e7y/m6sTWYFRLzJiBlvus8EZs8oeZ6nyQzayNfJEdrU=`. Только после этого release pipeline может подписывать appcast.
