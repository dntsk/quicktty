# Правила выпуска QuickTTY

Этот файл — обязательная краткая памятка для coding agents. Полный пошаговый runbook находится в `docs/releasing.md`; перед любым release нужно полностью прочитать **оба** документа. При расхождении действует более строгое правило, а выпуск останавливается до исправления документации или pipeline.

## Модель каналов

- `stable` получает только публичные stable releases через GitHub `latest`.
- `beta` является надмножеством `stable`: пользователь получает самый новый публичный build, будь то beta или stable.
- `CFBundleVersion` монотонно растёт в одной общей последовательности stable и beta releases.
- После выхода stable build новее текущей beta пользователь beta-канала переходит на stable, но остаётся подписанным на beta-feed.
- Следующая beta с большим build снова приходит этому пользователю автоматически.
- Источник beta-канала — только tracked `docs/appcasts/beta.xml`.

## Обязательный порядок

1. Получить явное разрешение на commit, push, signing, notarization, tag и GitHub publication.
2. Проверить `git status`, upstream, текущие tags и разницу с последним release tag.
3. Если stable продвигает уже проверенную beta и product code после beta tag не менялся, не добавлять произвольное повторное code review. Выполнять только release contracts и обязательные gates.
4. Выбрать общий монотонный build number и синхронно обновить:
   - `project.yml`;
   - `scripts/release-helpers.sh`;
   - `scripts/build-release.sh`;
   - release/notarization contract tests;
   - `README.md`;
   - английские release notes.
5. Запустить focused release contracts. Полный gate выполняется ровно один раз после release commit и push:

   ```sh
   .agents/scripts/pre-deploy-check.sh
   ```

   Не запускать отдельный `make check` до или после него.
6. Выполнять signing/notarization только из clean tree при `HEAD == @{upstream}` и только через:

   ```sh
   DEVELOPMENT_TEAM=... \
   CODE_SIGN_IDENTITY='Developer ID Application: ...' \
   NOTARY_PROFILE=QuickTTY \
   make signed-release
   ```

7. Требовать Apple `Accepted`, stapler validation, strict codesign, hardened runtime и Gatekeeper acceptance.
8. Проверить final DMG size/SHA-256 и appcast. Appcast создаётся только после stapling и содержит exact absolute enclosure, exact length и Ed25519 signature.
9. Создать annotated tag на exact gated release commit и push tag.
10. Создать GitHub Release только как draft, сразу с двумя assets: final DMG и `appcast.xml`.
11. Скачать draft assets, сравнить DMG size/SHA-256 и appcast byte-for-byte. Только после этого публиковать stable как `latest` либо beta как prerelease.
12. Анонимно проверить public release, appcast и DMG без GitHub credentials.
13. После **каждого** stable или beta application release продвинуть exact final appcast более нового build:

    ```sh
    make beta-feed
    git diff --check
    git diff -- docs/appcasts/beta.xml
    ```

14. Создать отдельный post-release commit только для `docs/appcasts/beta.xml`, push и анонимно сравнить raw feed с local final appcast.
15. Выполнить update smoke matrix:
    - previous stable → new stable через stable channel;
    - previous beta → new stable через beta channel после stable release;
    - previous beta → new beta через beta channel после beta release;
    - stable channel не видит beta prerelease.
16. Записать evidence в `.agents/memory/tasks-completed.md` и новый русский handoff, затем создать отдельный evidence commit.

## Запреты

- Не объявлять release готовым до public verification, beta-feed promotion и применимых update smoke tests.
- Не публиковать application release без DMG и appcast.
- Не создавать appcast до notarization/stapling.
- Не редактировать `docs/appcasts/beta.xml` вручную.
- Не оставлять beta-feed на старом build после более нового stable release.
- Не использовать `gh release upload` или `gh release delete-asset`.
- Не изменять published tag, release или assets; исправление делается новым release.
- Не угадывать Keychain profile: используется `QuickTTY`.
- Не читать и не печатать secrets, `.env`, private Sparkle key или notarization credentials.
- Не смешивать generated beta-feed commit с документацией или evidence.
- Не запускать дополнительные полные проверки и повторные review, которых нет в `docs/releasing.md`.
