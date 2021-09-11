#!/usr/bin/python3

import argparse
import os
import logging
import sys
import requests
import tempfile
import shutil
import securesystemslib.gpg.functions

import in_toto.exceptions
import in_toto.verifylib
import in_toto.models.link
import in_toto.models.metadata

from pathlib import Path

logger = logging.getLogger(__name__)
console_handler = logging.StreamHandler(sys.stderr)
logger.addHandler(console_handler)

#
# Inspired by https://github.com/in-toto/apt-transport-in-toto
#

# For more information please take a look at:
# https://github.com/fepitre/package-rebuilder#check-rebuild-proofs-before-installing-packages-apt-transport-in-toto


def in_toto_verify(config, filename):
    pkg_name = pkg_version_release = None
    if filename.endswith(".deb"):
        pkg_name_parts = os.path.basename(filename).split("_")
        if len(pkg_name_parts) == 3:
            pkg_name = pkg_name_parts[0]
            pkg_version_release = pkg_name_parts[1]
    if not (pkg_name and pkg_version_release):
        logger.error(f"Cannot parse '{filename}'")
        return False

    logger.info(f"Prepare in-toto verification for '{filename}'")

    # Create temp dir
    verification_dir = tempfile.mkdtemp()

    # Download link files to verification directory
    for rebuilder in config["Rebuilders"]:
        endpoint = f"{rebuilder.rstrip('/')}/sources/{pkg_name}/{pkg_version_release}/metadata"
        logger.info(f"Request in-toto metadata from {endpoint}")
        try:
            # Fetch metadata
            response = requests.get(endpoint)
            if not response.status_code == 200:
                raise Exception(f"server response: {response.status_code}")

            # Decode json
            link_json = response.json()

            # Load as in-toto metadata
            link_metablock = in_toto.models.metadata.Metablock(
                signatures=link_json["signatures"],
                signed=in_toto.models.link.Link.read(link_json["signed"]))

            # Construct link name as required by in-toto verification
            link_name = in_toto.models.link.FILENAME_FORMAT.format(
                keyid=link_metablock.signatures[0]["keyid"],
                step_name=link_metablock.signed.name)

            # Write link metadata to temporary verification directory
            link_metablock.dump(os.path.join(verification_dir, link_name))

        except Exception as e:
            logger.warning(f"Could not retrieve in-toto metadata from rebuilder"
                           f" '{rebuilder}', reason was: {e}")
            continue
        else:
            logger.info(f"Successfully downloaded in-toto metadata "
                        f"'{link_name}' from rebuilder '{rebuilder}'")

    # Copy final product downloaded by http to verification directory
    shutil.copy(filename, verification_dir)

    # Temporarily change to verification, changing back afterwards
    cached_cwd = os.getcwd()
    os.chdir(verification_dir)

    try:
        layout = in_toto.models.metadata.Metablock.load(config["Layout"])
        keyids = config["Keyids"]
        gpg_home = config["GPGHomedir"]

        logger.info(f"Load in-toto layout key(s) '{config['Keyids']}'")
        if gpg_home:
            logger.info(f"Use gpg keyring '{gpg_home}'")
            layout_keys = securesystemslib.gpg.functions.export_pubkeys(
                keyids, homedir=gpg_home)
        else:
            logger.info("Use default gpg keyring")
            layout_keys = securesystemslib.gpg.functions.export_pubkeys(keyids)

        logger.info(f"Run in-toto verification for '{filename}'")

        # Run verification
        in_toto.verifylib.in_toto_verify(layout, layout_keys)

    except Exception as e:
        logger.error(f"In-toto verification for '{filename}' failed!")
        logger.debug(f"Reason is: {str(e)}")
        return False

        # if isinstance(e, in_toto.exceptions.LinkNotFoundError) and \
        #         config.get("NoFail"):
        #     logger.warning("The 'NoFail' setting was configured, "
        #                    "installation continues.")
        # else:
        #     return False

    else:
        logger.info(f"In-toto verification for '{filename}' passed!")

    finally:
        os.chdir(cached_cwd)
        shutil.rmtree(verification_dir)
    return True


def get_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--gnupghome",
        help="in-toto GnuPG home folder",
    )
    parser.add_argument(
        "--root-layout",
        help="in-toto root.layout",
    )
    parser.add_argument(
        "--sign-key-root-layout",
        help="GPG key used for signing root.layout",
    )
    parser.add_argument(
        "--rebuilder",
        help="Rebuilder URL providing in-toto metadata."
             "(e.g. https://rebuild.notset.fr/debian)",
        action="append"
    )
    parser.add_argument(
        "--packages",
        help="Input DEB packages for in-toto verification",
        nargs="+",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Display logger info messages."
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Display logger debug messages."
    )
    return parser.parse_args()


def main():
    args = get_args()

    if args.debug:
        logger.setLevel(logging.DEBUG)
    elif args.verbose:
        logger.setLevel(logging.INFO)
    else:
        logger.setLevel(logging.ERROR)

    in_toto_rebuilders = args.rebuilder
    in_toto_gpg_home = args.gnupghome
    in_toto_root_layout = args.root_layout
    in_toto_sign_key_root_layout = args.sign_key_root_layout
    packages = [Path(p) for p in args.packages]

    config = {
        "Rebuilders": in_toto_rebuilders,
        "GPGHomedir": in_toto_gpg_home,
        "Layout": in_toto_root_layout,
        "Keyids": [
            in_toto_sign_key_root_layout
        ],
        "NoFail": False
    }

    failed_to_verify = []
    for package in packages:
        package_path = package.expanduser().absolute().as_posix()
        if not in_toto_verify(config, package_path):
            failed_to_verify.append(package_path)

    if failed_to_verify:
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
