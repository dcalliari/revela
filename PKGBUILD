# Maintainer: Revela contributors
pkgname=revela
pkgver=0.1.0
pkgrel=1
pkgdesc='Native Arch Linux release of the Revela tethered camera station'
arch=('x86_64')
url='https://github.com/dcalliari/revela'
license=('MIT')
depends=('bash' 'erlang' 'gphoto2' 'imagemagick' 'gvfs' 'openssl')
makedepends=('elixir' 'npm')
backup=('etc/revela/revela.env')
source=()
sha256sums=()

build() {
  export MIX_ENV=prod
  mix deps.get --only prod
  mix assets.deploy
  mix release
}

package() {
  install -d "$pkgdir/usr/lib/revela" "$pkgdir/etc/revela"
  cp -a _build/prod/rel/revela/. "$pkgdir/usr/lib/revela/"
  install -Dm755 priv/revela/bin/setup "$pkgdir/usr/bin/revela-setup"
  install -Dm644 packaging/revela.service "$pkgdir/usr/lib/systemd/system/revela.service"
  install -Dm644 README.arch.md "$pkgdir/usr/share/doc/revela/README.arch.md"
  install -d -m 0750 "$pkgdir/var/lib/revela/editorials" "$pkgdir/var/lib/revela/uploads"
}

post_install() {
  cat <<'MSG'
Revela instalado. O serviço está desabilitado por padrão.
Consulte /usr/share/doc/revela/README.arch.md e execute `revela-setup --dry-run`.
MSG
}
