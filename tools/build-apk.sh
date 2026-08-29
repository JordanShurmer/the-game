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
# The APK is signed with a debug key, which the script makes if it is
# not there. That key is good enough to sideload and to play. It is not
# good enough to publish: a release needs a key of your own, and the
# package name in AndroidManifest.xml is an example on purpose.
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
KEYSTORE="${ANDROID_KEYSTORE:-$OUT/debug.keystore}"
if [ ! -f "$KEYSTORE" ]; then
	keytool -genkeypair -keystore "$KEYSTORE" -alias thegame \
		-storepass android -keypass android \
		-keyalg RSA -keysize 2048 -validity 10000 \
		-dname "CN=The Game, OU=None, O=None, L=None, S=None, C=ZZ" >/dev/null
fi

"$BT/zipalign" -f 4 "$OUT/base.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign \
	--ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
	--out "$OUT/the-game.apk" "$OUT/aligned.apk"
"$BT/apksigner" verify --print-certs "$OUT/the-game.apk" | head -2

rm -f "$OUT/base.apk" "$OUT/aligned.apk" "$OUT/classes.dex"
rm -rf "$OUT/classes" "$OUT/res" "$OUT/assets"

say "done"
ls -l "$OUT/the-game.apk"
printf '\nInstall it: adb install -r %s/the-game.apk\n' "$OUT"
