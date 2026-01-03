#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname $0)";pwd)

# Install loongnix-archive-keyring
cp -v $SCRIPT_DIR/../gpg/loongnix-archive-keyring.gpg /usr/share/keyrings/

debuerreotypeScriptsDir="$(which debuerreotype-init)"
debuerreotypeScriptsDir="$(readlink -vf "$debuerreotypeScriptsDir")"
debuerreotypeScriptsDir="$(dirname "$debuerreotypeScriptsDir")"

source "$debuerreotypeScriptsDir/.constants.sh" \
	-- \
	'<output-dir> <suite>' \
	'output stretch'

eval "$dgetopt"
while true; do
	flag="$1"; shift
	dgetopt-case "$flag"
	case "$flag" in
		--) break ;;
		*) eusage "unknown flag '$flag'" ;;
	esac
done

outputDir="${1:-}"; shift || eusage 'missing output-dir'
suite="${1:-}"; shift || eusage 'missing suite'

set -x

outputDir="$(readlink -ve "$outputDir")"

tmpDir="$(mktemp --directory --tmpdir "debuerreotype.$suite.XXXXXXXXXX")"
trap "$(printf 'rm -rf %q' "$tmpDir")" EXIT

export TZ='UTC' LC_ALL='C'

dpkgArch='loong64'

exportDir="$tmpDir/output"
archDir="$exportDir/$(date +"%Y%m%d")/$dpkgArch"
tmpOutputDir="$archDir/$suite"

mirror='http://pkg.loongnix.cn/loongnix/25'

initArgs=(
	--arch "$dpkgArch"
	--non-debian
)

export GNUPGHOME="$tmpDir/gnupg"
mkdir -p "$GNUPGHOME"
keyring='/usr/share/keyrings/loongnix-archive-keyring.gpg'
if [ ! -s "$keyring" ]; then
	# since we're using mirrors, we ought to be more explicit about download verification
	keyUrl='https://keys.openpgp.org/vks/v1/by-fingerprint/D1B8F4D3241F015CACF733D3A8C7C20CEDF1B817'
	keyring="$tmpDir/loongnix-archive-keyring.gpg"
	wget -O "$keyring.asc" "$keyUrl"
	gpg --batch --no-default-keyring --keyring "$keyring" --import "$keyring.asc"
	rm -f "$keyring.asc"
fi
initArgs+=( --keyring "$keyring" )

mkdir -p "$tmpOutputDir"

if [ -f "$keyring" ] && wget -O "$tmpOutputDir/InRelease" "$mirror/dists/$suite/InRelease"; then
	gpgv \
		--keyring "$keyring" \
		--output "$tmpOutputDir/Release" \
		"$tmpOutputDir/InRelease"
	[ -s "$tmpOutputDir/Release" ]
elif [ -f "$keyring" ] && wget -O "$tmpOutputDir/Release.gpg" "$mirror/dists/$suite/Release.gpg" && wget -O "$tmpOutputDir/Release" "$mirror/dists/$suite/Release"; then
	rm -f "$tmpOutputDir/InRelease" # remove wget leftovers
	gpgv \
		--keyring "$keyring" \
		"$tmpOutputDir/Release.gpg" \
		"$tmpOutputDir/Release"
	[ -s "$tmpOutputDir/Release" ]
else
	echo >&2 "error: failed to fetch either InRelease or Release.gpg+Release for '$suite' (from '$mirror')"
	exit 1
fi

# apply merged-/usr (for bookworm+)
# https://lists.debian.org/debian-ctte/2022/07/msg00034.html
# https://github.com/debuerreotype/docker-debian-artifacts/issues/131#issuecomment-1190233249
case "${codename:-$suite}" in
	# this has to be a full codename list because we don't have aptVersion available yet because there's no APT yet 🙈
	# polaris)
	# 	initArgs+=( --no-merged-usr )
	# 	;;

	*)
		if true; then # make indentation match "examples/debian.sh" for easier diffing (we don't have epoch here so we just enable unilaterally in bookworm+ for lingmo builds)
			initArgs+=( --merged-usr )
			debootstrap="$(command -v debootstrap)"
			if ! grep -q EXCLUDE_DEPENDENCY "$debootstrap" || ! grep -q EXCLUDE_DEPENDENCY "${DEBOOTSTRAP_DIR:-/usr/share/debootstrap}/functions"; then
				cat >&2 <<-'EOERR'
					error: debootstrap missing necessary patches; see:
					  - https://salsa.debian.org/installer-team/debootstrap/-/merge_requests/76
					  - https://salsa.debian.org/installer-team/debootstrap/-/merge_requests/81
				EOERR
				exit 1
			fi
		fi
		;;
esac

# Install lingmo bootstrap
apt update
apt install -y sudo debootstrap

cp -v  /usr/share/debootstrap/scripts/sid /usr/share/debootstrap/scripts/loongnix-stable

rootfsDir="$tmpDir/rootfs"
debuerreotype-init "${initArgs[@]}" "$rootfsDir" "$suite" "$mirror"

debuerreotype-minimizing-config "$rootfsDir"

# Add loongnix security repo
echo "deb http://pkg.loongnix.cn/loongnix/25/ loongnix-security main contrib non-free" > "$rootfsDir/etc/apt/sources.list.d/loongnix-25-security.list"
cp -v $SCRIPT_DIR/../gpg/loongnix-archive-keyring.gpg "$rootfsDir/usr/share/keyrings/loongnix-archive-keyring.gpg"
cp -v $SCRIPT_DIR/../gpg/loongnix-archive-keyring.gpg.asc "$rootfsDir/etc/apt/trusted.gpg.d/loongnix-archive-keyring.gpg.asc"

# TODO do we need to update sources.list here? (security?)
debuerreotype-apt-get "$rootfsDir" update -qq

debuerreotype-recalculate-epoch "$rootfsDir"
epoch="$(< "$rootfsDir/debuerreotype-epoch")"
touch_epoch() {
	while [ "$#" -gt 0 ]; do
		local f="$1"; shift
		touch --no-dereference --date="@$epoch" "$f"
	done
}

aptVersion="$("$debuerreotypeScriptsDir/.apt-version.sh" "$rootfsDir")"
if dpkg --compare-versions "$aptVersion" '>=' '1.1~'; then
	debuerreotype-apt-get "$rootfsDir" full-upgrade -yqq
else
	debuerreotype-apt-get "$rootfsDir" dist-upgrade -yqq
fi

# copy the rootfs to create other variants
mkdir "$rootfsDir"-slim
tar -cC "$rootfsDir" . | tar -xC "$rootfsDir"-slim

# for historical reasons (related to their usefulness in debugging non-working container networking in container early days before "--network container:xxx"), Debian 10 and older non-slim images included both "ping" and "ip" above "minbase", but in 11+ (Bullseye), that will no longer be the case and we will instead be a faithful minbase again :D
# epoch2021="$(date --date '2021-01-01 00:00:00' +%s)"
# if [ "$epoch" -lt "$epoch2021" ] || { isDebianBusterOrOlder="$([ -f "$rootfsDir/etc/os-release" ] && source "$rootfsDir/etc/os-release" && [ -n "${VERSION_ID:-}" ] && [ "${VERSION_ID%%.*}" -le 10 ] && echo 1)" && [ -n "$isDebianBusterOrOlder" ]; }; then
# 	# prefer iproute2 if it exists
# 	iproute=iproute2
# 	if ! debuerreotype-apt-get "$rootfsDir" install -qq -s iproute2 &> /dev/null; then
# 		# poor wheezy
# 		iproute=iproute
# 	fi
# 	ping=iputils-ping
# 	noInstallRecommends='--no-install-recommends'
# 	debuerreotype-apt-get "$rootfsDir" install -y $noInstallRecommends $ping $iproute
# fi

debuerreotype-slimify "$rootfsDir"-slim

create_artifacts() {
	local targetBase="$1"; shift
	local rootfs="$1"; shift
	local suite="$1"; shift
	local variant="$1"; shift

	local tarArgs=()

	debuerreotype-tar "${tarArgs[@]}" "$rootfs" "$targetBase.tar.xz"
	du -hsx "$targetBase.tar.xz"

	sha256sum "$targetBase.tar.xz" | cut -d' ' -f1 > "$targetBase.tar.xz.sha256"
	touch_epoch "$targetBase.tar.xz.sha256"

	debuerreotype-chroot "$rootfs" dpkg-query -W > "$targetBase.manifest"
	echo "$suite" > "$targetBase.apt-dist"
	echo "$dpkgArch" > "$targetBase.dpkg-arch"
	echo "$epoch" > "$targetBase.debuerreotype-epoch"
	echo "$variant" > "$targetBase.debuerreotype-variant"
	debuerreotype-version > "$targetBase.debuerreotype-version"
	debootstrapVersion="$(debootstrap --version)"
	debootstrapVersion="${debootstrapVersion#debootstrap }" # "debootstrap X.Y.Z" -> "X.Y.Z"
	echo "$debootstrapVersion" > "$targetBase.debootstrap-version"
	touch_epoch "$targetBase".{manifest,apt-dist,dpkg-arch,debuerreotype-*,debootstrap-version}

	for f in debian_version os-release apt/sources.list; do
		targetFile="$targetBase.$(basename "$f" | sed -r "s/[^a-zA-Z0-9_-]+/-/g")"
		if [ -e "$rootfs/etc/$f" ]; then
			cp "$rootfs/etc/$f" "$targetFile"
			touch_epoch "$targetFile"
		fi
	done
}

for rootfs in "$rootfsDir"*/; do
	rootfs="${rootfs%/}" # "../rootfs", "../rootfs-slim", ...

	du -hsx "$rootfs"

	variant="$(basename "$rootfs")" # "rootfs", "rootfs-slim", ...
	variant="${variant#rootfs}" # "", "-slim", ...
	variant="${variant#-}" # "", "slim", ...

	variantDir="$tmpOutputDir/$variant"
	mkdir -pv "$variantDir"

	targetBase="$variantDir/rootfs"

	create_artifacts "$targetBase" "$rootfs" "$suite" "$variant"
done

user="$(stat --format '%u' "$outputDir")"
group="$(stat --format '%g' "$outputDir")"
tar --create --directory="$exportDir" --owner="$user" --group="$group" . | tar --extract --verbose --directory="$outputDir"
