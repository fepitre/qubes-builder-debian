#!/bin/bash -e
# vim: set ts=4 sw=4 sts=4 et :

if [ "$VERBOSE" -ge 2 -o "$DEBUG" == "1" ]; then
    set -x
fi

# Source external scripts
source "${SCRIPTSDIR}/vars.sh"
source "${SCRIPTSDIR}/distribution.sh"

##### '-------------------------------------------------------------------------
debug ' Installing base system using debootstrap'
##### '-------------------------------------------------------------------------

# ==============================================================================
# Execute any template flavor or sub flavor 'pre' scripts
# ==============================================================================
buildStep "${0}" "pre"


bootstrap() {
    for mirror in ${DEBIAN_MIRRORS[@]}; do
        if [ ! -d "${INSTALLDIR}/${TMPDIR}" ]; then
            mkdir -m 1777 -p "${INSTALLDIR}/${TMPDIR}"
        fi
        rm -rf "${INSTALLDIR}/${TMPDIR}/dummy-repo"
        mkdir -p "${INSTALLDIR}/${TMPDIR}/dummy-repo/dists/${DIST}"
        mkdir -p "${INSTALLDIR}/${TMPDIR}/dummy-repo/dists/${DIST}/main/binary-amd64"
        echo ${mirror} > "${INSTALLDIR}/${TMPDIR}/.mirror"

        mirror_no_proto=${mirror#*://}
        # depending on debootstrap version, Release files can be stored under
        # different names; this function needs _some_ correctly signed file for
        # dummy repository
        release_location_candidates=( \
            "${INSTALLDIR}/var/lib/apt/lists/${mirror_no_proto//\//_}_dists_${DIST}_Release" \
            "${INSTALLDIR}/var/lib/apt/lists/debootstrap.invalid_dists_${DIST}_Release" \
        )

        # prepare in-toto
        mkdir -p "${INSTALLDIR}/var/lib/intoto/gnupg"
        chmod 700 "${INSTALLDIR}/var/lib/intoto/gnupg"
        GNUPGHOME="${INSTALLDIR}/var/lib/intoto/gnupg" gpg --import \
          "${SCRIPTSDIR}/../in-toto/keys/9FA64B92F95E706BF28E2CA6484010B5CDC576E2.asc" \
          "${SCRIPTSDIR}/../in-toto/keys/8DEB0BEF1D99FEB8B9A90FB192EF6D6141641E5C.asc"
        cp "${SCRIPTSDIR}/../in-toto/root.layout" "${INSTALLDIR}/var/lib/intoto/"

        apt_https_pkgs="apt-transport-https,ca-certificates"
        # Download packages first, and log hash of them _before_ installing
        # them. Needs to copy Release{,.gpg} to a dummy _local_ repo, because
        # debootstrap insists on downloading it each time but we want to be sure to use
        # packages downloaded earlier (and logged)
        COMPONENTS="" $DEBOOTSTRAP_PREFIX debootstrap \
            --arch=amd64 \
            --include="ncurses-term,locales,tasksel,$apt_https_pkgs,$eatmydata_maybe" \
            --components=main \
            --download-only \
            --keyring="${SCRIPTSDIR}/../keys/${DIST}-${DISTRIBUTION}-archive-keyring.gpg" \
            "${DIST}" "${INSTALLDIR}" "${mirror}" && \
        sha256sum "${INSTALLDIR}/var/cache/apt/archives"/*.deb && \
        "${SCRIPTSDIR}"/../in-toto/in-toto-verify.py \
            --gnupghome "${INSTALLDIR}/var/lib/intoto/gnupg" \
            --root-layout "${INSTALLDIR}/var/lib/intoto/root.layout" \
            --sign-key-root-layout 9fa64b92f95e706bf28e2ca6484010b5cdc576e2 \
            --rebuilder "https://rebuild.notset.fr/debian" \
            --packages "${INSTALLDIR}/var/cache/apt/archives"/*.deb && \
        for release_location in "${release_location_candidates[@]}"; do
            if [ -r "${release_location}" ]; then
                cp "${release_location}" \
                    "${INSTALLDIR}/${TMPDIR}/dummy-repo/dists/${DIST}/Release"
                inrelease_location="${release_location%Release}InRelease"
                if [ -r "$inrelease_location" ]; then
                    cp "${inrelease_location}" \
                        "${INSTALLDIR}/${TMPDIR}/dummy-repo/dists/${DIST}/InRelease"
                fi
                if [ -r "${release_location}.gpg" ]; then
                    cp "${release_location}.gpg" \
                        "${INSTALLDIR}/${TMPDIR}/dummy-repo/dists/${DIST}/Release.gpg"
                fi
                cp "${release_location%_Release}_main_binary-amd64_Packages" \
                    "${INSTALLDIR}/${TMPDIR}/dummy-repo/dists/${DIST}/main/binary-amd64/Packages"
                break
            fi
        done && \
        COMPONENTS="" $DEBOOTSTRAP_PREFIX debootstrap \
            --arch=amd64 \
            --include="ncurses-term,locales,tasksel,$apt_https_pkgs,$eatmydata_maybe" \
            --components=main \
            --keyring="${SCRIPTSDIR}/../keys/${DIST}-${DISTRIBUTION}-archive-keyring.gpg" \
            "${DIST}" "${INSTALLDIR}" "file://${INSTALLDIR}/${TMPDIR}/dummy-repo" && \
        echo "deb ${mirror} ${DIST} main" > ${INSTALLDIR}/etc/apt/sources.list && \
        return 0
    done
    return 1
}


if ! [ -f "${INSTALLDIR}/${TMPDIR}/.prepared_debootstrap" ]; then
    #### "------------------------------------------------------------------
    info " $(templateName): Installing base '${DISTRIBUTION}-${DIST}' system"
    #### "------------------------------------------------------------------
    retry=0
    while ! bootstrap
    do
        if [ $retry -le 3 ]; then
            echo "Error in debootstrap. Sleeping 60 sec before retrying..."
            retry=$((retry + 1))
            sleep 60
        else
            echo "Error in debootstrap. Aborting due to too much retries."
            exit 1
        fi
    done

    #### '----------------------------------------------------------------------
    info ' Download APT metadata'
    #### '----------------------------------------------------------------------
    chroot_cmd apt-get update || exit 1

    #### '----------------------------------------------------------------------
    info ' Configure keyboard'
    #### '----------------------------------------------------------------------
    configureKeyboard

    #### '----------------------------------------------------------------------
    info ' Update locales'
    #### '----------------------------------------------------------------------
    updateLocale

    #### '----------------------------------------------------------------------
    info 'Link mtab'
    #### '----------------------------------------------------------------------
    chroot_cmd rm -f /etc/mtab
    chroot_cmd ln -s /proc/self/mounts /etc/mtab

    # TMPDIR is set in vars.  /tmp should not be used since it will be cleared
    # if building template with LXC contaniners on a reboot
    mkdir -m 1777 -p "${INSTALLDIR}/${TMPDIR}"

    # Mark section as complete
    touch "${INSTALLDIR}/${TMPDIR}/.prepared_debootstrap"

    # If SNAPSHOT=1, Create a snapshot of the already debootstraped image
    createSnapshot "debootstrap"
fi

# ==============================================================================
# Execute any template flavor or sub flavor 'post' scripts
# ==============================================================================
buildStep "${0}" "post"
