# Release procedure

Этот документ обязателен для любого QuickTTY release и выполняется вместе с краткими agent-facing правилами `.agents/rules/releasing.md`. Перед началом выпуска оба документа нужно прочитать полностью. Если команда, script или привычка противоречат им, релиз останавливается до исправления pipeline. Нельзя обещать готовый release до прохождения публичной проверки, продвижения beta feed и применимых update smoke tests.

## Инварианты

- Публикуется только notarized arm64 DMG.
- Release tag указывает на exact commit, из которого собран DMG.
- `CFBundleVersion` монотонно растёт через общую последовательность stable и beta releases. Beta и stable одного marketing version различаются build number, и более новый release всегда имеет больший build.
- Каждый application GitHub Release содержит ровно два assets: `QuickTTY-<version>-arm64.dmg` и `appcast.xml`. Stable release становится `latest`; prerelease никогда не становится `latest`. Единственное исключение — описанный ниже immutable legacy bootstrap beta release с одним `appcast.xml` asset.
- `appcast.xml` создаётся из финального stapled DMG. Его `enclosure/@length` равен фактическому размеру опубликованного DMG; enclosure URL — абсолютный `https://github.com/dntsk/quicktty/releases/download/v<version>/…` того же release.
- `https://github.com/dntsk/quicktty/releases/latest/download/appcast.xml` должен быть доступен после публикации и вести к текущему stable release.
- Stable channel получает только stable releases через GitHub `latest` и никогда не получает prerelease.
- Beta channel является надмножеством stable: он получает самый новый публичный build независимо от того, stable это или beta. Он читает только `https://raw.githubusercontent.com/dntsk/quicktty/master/docs/appcasts/beta.xml`.
- После каждого публично проверенного application release — stable или beta — exact final appcast более нового build обязательно продвигается в tracked `docs/appcasts/beta.xml` командой `make beta-feed`. Файл никогда не редактируется вручную.
- Keychain profile для notarization: `QuickTTY`. Никогда не угадывать и не подменять его другим именем.
- После publication tag и assets immutable: не заменять, не удалять и не загружать assets вручную в опубликованный release.
- GitHub Release title и release notes пишутся только на английском.
- Pi guardrail `.pi/extensions/guardrails.json` блокирует `gh release upload` и `delete-asset`; agent не обходит этот hook.

## 1. Подготовка release commit

1. Получить явное разрешение на commit, push, signing, notarization, tag и публикацию.
2. Выбрать marketing version, build number и release label. Обновить одновременно XcodeGen metadata, release helpers, release verification, contract tests и README. Исторические release docs и handoffs не переписывать.
3. Выполнить contract checks для изменённых release scripts.
4. Создать один release commit и push в `origin/master`.
5. Убедиться, что дерево чистое и `HEAD` совпадает с `@{upstream}`.
6. Выполнить **один** полный gate для этого commit:

   ```sh
   .agents/scripts/pre-deploy-check.sh
   ```

   Не запускать отдельный `make check` до или после этого gate. Если gate не прошёл, не создавать tag; исправить причину новым commit и повторить только этот gate.

## 2. Build, signing и notarization

1. Убедиться, что `.build/Release` содержит только outputs, которыми владеет release pipeline. Stale output — дефект pipeline: исправлять pipeline, а не удалять или подменять файлы вручную во время release.
2. Использовать только variables process environment, без secrets в command line или repository:

   ```sh
   DEVELOPMENT_TEAM=... \
   CODE_SIGN_IDENTITY='Developer ID Application: ...' \
   NOTARY_PROFILE=QuickTTY \
   make signed-release
   ```

3. Требовать успешные strict `codesign`, hardened runtime, Apple `Accepted`, stapler validation и Gatekeeper assessment.
4. Зафиксировать final DMG path, size, SHA-256 и notarization evidence JSON. Если notarization не принята, не создавать tag или GitHub Release.

## 3. Final appcast

Release pipeline обязан создать `appcast.xml` **после** stapling из final DMG. До публикации проверить:

```sh
DMG=.build/Release/QuickTTY-<version>-arm64.dmg
APPCAST=.build/Release/appcast/appcast.xml
stat -f '%z' "$DMG"
shasum -a 256 "$DMG"
grep 'enclosure' "$APPCAST"
```

`enclosure/@length` обязан совпадать с `stat`. Enclosure URL обязан быть абсолютным direct GitHub Release URL и вести к точному имени DMG asset. Relative URLs запрещены: GitHub redirect appcast на другой host и Sparkle не может надёжно разрешить такой DMG URL. Если приложение содержит Sparkle public key, appcast обязан содержать действительную соответствующую `sparkle:edSignature`.

Нельзя создавать appcast до notarization, публиковать локальный pre-staple appcast или исправлять appcast после publication release.

## 4. Draft publication

1. Создать annotated tag на release commit и push его:

   ```sh
   git tag -a v<version> <release-commit> -m 'QuickTTY <version>'
   git push origin v<version>
   ```

2. Подготовить title и release notes только на английском, затем создать GitHub Release только как draft, сразу приложив оба final assets:

   ```sh
   gh release create v<version> \
     .build/Release/QuickTTY-<version>-arm64.dmg \
     .build/Release/appcast/appcast.xml \
     --draft --verify-tag --title 'QuickTTY <version>' --notes-file <release-notes-file>
   ```

3. Проверить draft через GitHub API/CLI: release остаётся draft, assets имеют точные имена, DMG size и SHA-256 совпадают с локальными, appcast содержит точный final enclosure.
4. Только после этой проверки опубликовать draft. Для stable release:

   ```sh
   gh release edit v<version> --draft=false --latest
   ```

   Для prerelease:

   ```sh
   gh release edit v<version> --draft=false --prerelease --latest=false
   ```

Если любая проверка draft не проходит, удалить draft и исправить pipeline. Не публиковать его и не менять assets существующего public release.

## 5. Публичная проверка

После publication проверить без GitHub credentials:

1. Для stable release `releases/latest/download/appcast.xml` отвечает и содержит текущий version, build number, final enclosure name и final length. Prerelease не меняет этот URL.
2. Absolute enclosure URL отвечает и ведёт к public DMG текущего release.
3. Анонимно скачать DMG, сверить его size и SHA-256 с local final artifact.
4. Для stable release проверить в приложении предыдущего stable release ручной `Check for Updates…`: найдено именно новое обновление, download и Sparkle validation не показывают error. Prerelease не предлагается stable-каналу.

До завершения всех применимых пунктов release считается незавершённым.

## 6. Продвижение beta channel

Beta channel — это поток «самый новый stable или beta build», а не prerelease-only поток. Поэтому этот раздел обязателен после **каждого** application release, включая stable.

1. Release должен быть опубликован и анонимно проверен по разделам 1–5. Его build обязан быть больше build, который сейчас указан в `docs/appcasts/beta.xml`.
2. Из clean tree запустите:

   ```sh
   make beta-feed
   git diff --check
   git diff -- docs/appcasts/beta.xml
   ```

   Команда принимает только `.build/Release/appcast/appcast.xml`, который проходит проверку против final DMG, и атомарно копирует exact bytes в tracked `docs/appcasts/beta.xml`. Она не выполняет GitHub, Git write, signing или notarization operations.
3. Создайте отдельный post-release commit **только** для `docs/appcasts/beta.xml` и push его в `master`. Не смешивайте этот generated feed с release evidence или документацией.
4. Проверьте raw URL без GitHub credentials: скачанный XML обязан byte-for-byte совпасть с local final appcast; его absolute enclosure обязан скачать final public DMG с теми же size и SHA-256.
5. Выполните channel smoke matrix:
   - после stable release предыдущий stable build через stable channel получает новый stable build;
   - после stable release предыдущий beta build, оставаясь на beta channel, тоже получает новый stable build;
   - после beta release предыдущий beta build получает новый beta build;
   - stable channel никогда не предлагает beta prerelease.
6. Следующий beta release с большим build снова продвигается тем же `make beta-feed`, поэтому пользователь, перешедший с beta на stable build, остаётся подписанным на будущие beta updates.

### Immutable legacy bootstrap

Старые beta builds до repository feed запрашивают `https://github.com/dntsk/quicktty/releases/download/beta/appcast.xml`. Один immutable legacy bootstrap release c annotated tag `beta` создаётся только для миграции этих клиентов: он является prerelease, не становится `latest` и содержит ровно один final `appcast.xml` asset, указывающий на DMG конкретного migration release. Его title и notes — только на английском.

Перед publication bootstrap release должен пройти draft verification: tag указывает на exact migration commit, XML byte-for-byte совпадает с final appcast migration release, enclosure использует его immutable `v<version>` direct DMG URL. После publication bootstrap tag и asset никогда не заменяются, не удаляются и не изменяются. Все builds после migration release получают новые beta updates только через raw repository feed; bootstrap больше не обновляется.

## 7. Evidence и запреты

После успешной публичной проверки, продвижения beta channel и всех применимых update smoke tests записать tag, release commit, beta-feed commit, notarization submission ID, artifact path, size, SHA-256, public URLs и gates в `.agents/memory/tasks-completed.md` и handoff. Не записывать Apple ID, passwords, tokens, private keys или другие secrets.

Запрещено:

- публиковать stable release без `appcast.xml`;
- оставлять `docs/appcasts/beta.xml` на старом build после публикации более нового stable или beta application release;
- менять опубликованный release вручную через `gh release upload`;
- менять или перемещать published tag;
- генерировать appcast из DMG до stapling;
- использовать guessed Keychain profile;
- объявлять release готовым до anonymous download и ручного update smoke test.
