#!/usr/bin/env sh
# Wrap the page in an APK.
#
#   make web
#   ANDROID_HOME=~/android-sdk tools/build-apk.sh
#   adb install -r android/build/the-game.apk
#
# The APK holds no game code: it holds web/build, and the WebView in
# android/src reads it out of the assets. So this script is a packager
# and nothing more, and it calls the Android build tools directly rather
# than through Gradle, because there is nothing here for a build system
# to work out.
#
# What it needs, and nothing else:
#
#   - a JDK, for javac
#   - the Android SDK: platforms/android-34 and build-tools/34.0.0
#
#   sdkmanager "platforms;android-34" "build-tools;34.0.0"
#
# **The key decides whether an APK will install.** Android takes an
# update only from the key that installed the app: where the key
# differs it refuses, and says no more than "App not installed". A key
# made per build is therefore a build nobody can update to.
#
# So the key is not made per build. `android/debug.keystore` is in the
# repository, alias `thegame`, password `android`, and every build that
# is not given another key signs with it -- this machine's, a
# contributor's, the runner's. They all install over each other.
#
# That keystore is a published private key and is treated as one. It is
# good enough to sideload and to play. It can never be good enough to
# publish, because anyone holding the repository can sign an APK with
# it; a released app needs a key that has never been anywhere, and the
# package name in AndroidManifest.xml is an example on purpose. Point
# the script at a key of your own with four variables:
#
#   ANDROID_KEYSTORE=my.jks ANDROID_KEYSTORE_PASS=... \
#   ANDROID_KEY_ALIAS=thegame ANDROID_KEY_PASS=... tools/build-apk.sh
#
# A keystore that is there is never overwritten. The script still makes
# one if it is pointed somewhere empty, and says so, because a key made
# on the spot is a key nothing else has.
set -eu

SDK="${ANDROID_HOME:-$HOME/android-sdk}"
API="${ANDROID_API:-34}"
TOOLS="${ANDROID_BUILD_TOOLS:-34.0.0}"

BT="$SDK/build-tools/$TOOLS"
JAR="$SDK/platforms/android-$API/android.jar"
OUT="android/build"

[ -d "$BT" ] || { echo "no build tools at $BT" >&2; exit 1; }
[ -f "$JAR" ] || { echo "no platform at $JAR" >&2; exit 1; }
[ -f web/build/index.html ] || { echo "web/build is empty: run \`make web\` first" >&2; exit 1; }

say() { printf '\n== %s\n' "$1"; }

rm -rf "$OUT"
mkdir -p "$OUT/assets" "$OUT/classes" "$OUT/res"

say "assets"
# The page, and only the page: the object file the linker left behind
# is not part of it.
for f in web/build/*; do
	case "$f" in *.o) continue ;; esac
	cp "$f" "$OUT/assets/"
done
ls "$OUT/assets"

say "resources"
"$BT/aapt2" compile --dir android/res -o "$OUT/res/res.zip"
"$BT/aapt2" link \
	-o "$OUT/base.apk" \
	-I "$JAR" \
	--manifest android/AndroidManifest.xml \
	-A "$OUT/assets" \
	--min-sdk-version 24 \
	--target-sdk-version "$API" \
	"$OUT/res/res.zip"

say "code"
javac -source 17 -target 17 -nowarn -classpath "$JAR" \
	-d "$OUT/classes" android/src/com/example/thegame/*.java
"$BT/d8" --lib "$JAR" --min-api 24 --output "$OUT" \
	$(find "$OUT/classes" -name '*.class')

# aapt adds the dex to the archive that aapt2 wrote. It takes the name
# it is given, so the dex must be added from the directory it sits in.
(cd "$OUT" && "$BT/aapt" add -f base.apk classes.dex >/dev/null)

say "sign"
# The repository's own key, and not under $OUT: this script wipes that
# directory on every run, and a keystore that is thrown away is a
# keystore that signs every build differently.
KEYSTORE="${ANDROID_KEYSTORE:-android/debug.keystore}"
ALIAS="${ANDROID_KEY_ALIAS:-thegame}"
STOREPASS="${ANDROID_KEYSTORE_PASS:-android}"
KEYPASS="${ANDROID_KEY_PASS:-$STOREPASS}"
MADE=""
if [ ! -f "$KEYSTORE" ]; then
	keytool -genkeypair -keystore "$KEYSTORE" -alias "$ALIAS" \
		-storepass "$STOREPASS" -keypass "$KEYPASS" \
		-keyalg RSA -keysize 2048 -validity 10000 \
		-dname "CN=The Game, OU=None, O=None, L=None, S=None, C=ZZ" >/dev/null
	MADE=yes
fi

"$BT/zipalign" -f 4 "$OUT/base.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign \
	--ks "$KEYSTORE" --ks-key-alias "$ALIAS" \
	--ks-pass "pass:$STOREPASS" --key-pass "pass:$KEYPASS" \
	--out "$OUT/the-game.apk" "$OUT/aligned.apk"

# Which key signed it, in a form a release note can carry: two APKs with
# different digests here will not install over one another.
CERT="$("$BT/apksigner" verify --print-certs "$OUT/the-game.apk" |
	sed -n 's/^Signer #1 certificate SHA-256 digest: //p')"
printf '%s\n' "$CERT" > "$OUT/cert.txt"
printf 'signed with %s\ncertificate SHA-256 %s\n' "$KEYSTORE" "$CERT"

if [ -n "$MADE" ]; then
	{
		printf '\n'
		printf 'There was no keystore at %s, so this build made one.\n' "$KEYSTORE"
		printf 'Nothing else has that key, so this APK will not install over any\n'
		printf 'other build, and Android will say only "App not installed". The\n'
		printf 'key the repository ships is android/debug.keystore; a key of your\n'
		printf 'own goes in ANDROID_KEYSTORE. See docs/web.md, "The release".\n'
	} >&2
fi

rm -f "$OUT/base.apk" "$OUT/aligned.apk" "$OUT/classes.dex"
rm -rf "$OUT/classes" "$OUT/res" "$OUT/assets"

say "done"
ls -l "$OUT/the-game.apk"
printf '\nInstall it: adb install -r %s/the-game.apk\n' "$OUT"
