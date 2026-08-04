# QuickTTY appcasts

`beta.xml` — единственный публичный beta feed QuickTTY. Beta channel является надмножеством stable: feed всегда указывает на самый новый публичный application build, независимо от того, stable это или beta. Приложение получает его по адресу:

`https://raw.githubusercontent.com/dntsk/quicktty/master/docs/appcasts/beta.xml`

Не редактируйте XML вручную. После публикации и анонимной проверки каждого более нового stable или beta application release выполните `make beta-feed`: команда проверит final DMG и generated appcast, затем атомарно скопирует exact appcast в этот файл. Просмотрите diff, создайте отдельный commit только для `docs/appcasts/beta.xml` и push после успешной публичной проверки. Следующая beta с большим build тем же способом снова заменит stable appcast, поэтому beta-пользователь остаётся подписанным на будущие prereleases.

Enclosure должен ссылаться на immutable DMG конкретного `v<version>` GitHub Release. Нельзя заменять, удалять или загружать assets в уже опубликованный release.
