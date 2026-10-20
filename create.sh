#!/bin/bash
set -euo pipefail

VERSION=${VERSION:-5.3}
TARGET=${TARGET:-11.0}
APP_ID=${APP_ID:?Developer ID Application identity}
INSTALLER_ID=${INSTALLER_ID:?Developer ID Installer identity}
NOTARY_PROFILE=${NOTARY_PROFILE:?notarytool keychain profile}

out=$PWD
work=$(mktemp -d)
cd "$work"

base=https://ftp.gnu.org/gnu/bash
curl -fsSL "$base/bash-$VERSION.tar.gz" | tar xz
patches=$(curl -fsSL "$base/bash-$VERSION-patches/" | grep -oE "bash${VERSION//./}-[0-9]{3}" | sort -u)
for p in $patches; do
  curl -fsSL "$base/bash-$VERSION-patches/$p" | patch -d "bash-$VERSION" -p0
done
full=$VERSION.$(wc -w <<<"$patches" | tr -d ' ')

for arch in arm64 x86_64; do
  mkdir "build-$arch"
  (
    cd "build-$arch"
    CFLAGS="-arch $arch -O2 -mmacosx-version-min=$TARGET" \
    LDFLAGS="-arch $arch -mmacosx-version-min=$TARGET" \
      "../bash-$VERSION/configure" --prefix=/usr/local --disable-nls --with-curses --without-installed-readline
    make -j"$(sysctl -n hw.ncpu)"
    make install DESTDIR="$work/root-$arch"
  )
done

cp -R root-arm64 payload
(
  cd root-arm64
  find . -type f -exec sh -c 'file -b "$1" | grep -q Mach-O' _ {} \; -print | while read -r f; do
    lipo -create "$f" "../root-x86_64/$f" -output "../payload/$f"
    codesign --force --options runtime --timestamp --sign "$APP_ID" "../payload/$f"
  done
)

mkdir scripts
cat > scripts/postinstall <<'EOF'
#!/bin/sh
grep -qx /usr/local/bin/bash /etc/shells || echo /usr/local/bin/bash >> /etc/shells
EOF
chmod +x scripts/postinstall

pkg="$out/bash-$full.pkg"
pkgbuild --root payload --install-location / --scripts scripts \
  --identifier org.gnu.bash --version "$full" --sign "$INSTALLER_ID" "$pkg"
xcrun notarytool submit "$pkg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$pkg"
