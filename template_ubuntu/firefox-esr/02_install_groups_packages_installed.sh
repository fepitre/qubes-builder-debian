#!/bin/bash -e
# vim: set ts=4 sw=4 sts=4 et :

# shellcheck source=template_ubuntu/vars.sh
source "${TEMPLATE_CONTENT_DIR}/vars.sh"
# shellcheck source=template_ubuntu/distribution.sh
source "${TEMPLATE_CONTENT_DIR}/distribution.sh"

#### '--------------------------------------------------------------------------
info 'Add Mozilla PPA repository'
#### '--------------------------------------------------------------------------
aptInstall gnupg
installMozillaRepo
